defmodule BeamWatch.Ingestion.LogWatcher do
  @moduledoc false

  use GenServer

  alias BeamWatch.Incidents.IncidentStore
  alias BeamWatch.Ingestion.LogParser
  alias BeamWatch.Ingestion.WatcherState
  alias BeamWatch.SourceHealth

  @default_poll_ms 500

  def start_link(opts \\ []) do
    log_dir = Keyword.fetch!(opts, :log_dir)
    store = Keyword.get(opts, :store, IncidentStore)
    poll_ms = Keyword.get(opts, :poll_ms, @default_poll_ms)
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []

    GenServer.start_link(
      __MODULE__,
      %{log_dir: log_dir, store: store, poll_ms: poll_ms},
      gen_opts
    )
  end

  @impl true
  def init(%{log_dir: log_dir, store: store, poll_ms: poll_ms}) do
    schedule_poll(poll_ms)
    {:ok, %{log_dir: log_dir, store: store, poll_ms: poll_ms, watcher: WatcherState.new()}}
  end

  @impl true
  def handle_info(:poll, state) do
    state = normalize_state(state)
    new_watcher = poll_directory(state.log_dir, state.watcher, state.store)
    schedule_poll(state.poll_ms)
    {:noreply, %{state | watcher: new_watcher}}
  end

  defp schedule_poll(ms), do: Process.send_after(self(), :poll, ms)

  defp normalize_state(%{watcher: %WatcherState{}} = state), do: state

  defp normalize_state(%{files: files} = old) do
    watcher =
      Enum.reduce(files, WatcherState.new(), fn {filename, %{offset: offset, buffer: buffer}},
                                                acc ->
        WatcherState.put(acc, filename, offset, buffer)
      end)

    %{log_dir: old.log_dir, store: old.store, poll_ms: old.poll_ms, watcher: watcher}
  end

  # --- File polling ---

  defp poll_directory(log_dir, watcher, store) do
    case File.ls(log_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&(Path.extname(&1) == ".log"))
        |> Enum.reduce(watcher, &poll_file(&1, log_dir, &2, store))

      {:error, _} ->
        watcher
    end
  end

  defp poll_file(filename, log_dir, watcher, store) do
    path = Path.join(log_dir, filename)
    %{offset: offset, buffer: buffer} = WatcherState.get(watcher, filename)

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} ->
        handle_file_readable(filename, path, size, offset, buffer, watcher, store)

      {:error, _} ->
        IncidentStore.update_source_health(store, %SourceHealth{
          file: filename,
          exists?: false,
          size_bytes: 0,
          last_read_at: DateTime.utc_now(),
          last_log_at: nil,
          byte_offset: 0,
          parse_failures: 0,
          rotated?: false
        })

        WatcherState.remove(watcher, filename)
    end
  end

  defp handle_file_readable(filename, path, size, offset, buffer, watcher, store) do
    rotated? = WatcherState.rotated?(size, offset)
    {offset, buffer} = if rotated?, do: {0, ""}, else: {offset, buffer}

    {new_offset, new_buffer, failures, last_log_at} =
      if size > offset do
        process_new_bytes(path, offset, buffer, filename, store)
      else
        {offset, buffer, 0, nil}
      end

    IncidentStore.update_source_health(store, %SourceHealth{
      file: filename,
      exists?: true,
      size_bytes: size,
      last_read_at: DateTime.utc_now(),
      last_log_at: last_log_at,
      byte_offset: new_offset,
      parse_failures: 0,
      rotated?: rotated?
    })

    if failures > 0 do
      Enum.each(1..failures, fn _ -> IncidentStore.ingest_malformed(store, filename) end)
    end

    WatcherState.put(watcher, filename, new_offset, new_buffer)
  end

  defp process_new_bytes(path, offset, buffer, filename, store) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        {:ok, _} = :file.position(file, offset)
        new_bytes = IO.binread(file, :eof)
        File.close(file)

        new_bytes = if is_binary(new_bytes), do: new_bytes, else: ""
        {complete, remainder} = WatcherState.split_lines(buffer <> new_bytes)

        {failures, last_log_at} =
          Enum.reduce(complete, {0, nil}, &parse_and_ingest(&1, &2, filename, store))

        consumed = byte_size(buffer <> new_bytes) - byte_size(remainder)
        {offset + consumed, remainder, failures, last_log_at}

      {:error, _} ->
        {offset, buffer, 0, nil}
    end
  end

  defp parse_and_ingest(raw, {failures, last_log_at}, filename, store) do
    case LogParser.parse(raw, filename) do
      {:ok, pl} ->
        IncidentStore.ingest_line(store, pl)
        {failures, pl.at}

      {:malformed, _} ->
        {failures + 1, last_log_at}
    end
  end
end
