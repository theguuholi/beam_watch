defmodule BeamWatch.Ingestion.LogWatcher do
  @moduledoc false

  use GenServer

  alias BeamWatch.Incidents.IncidentStore
  alias BeamWatch.Ingestion.LogParser
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
    {:ok, %{log_dir: log_dir, store: store, poll_ms: poll_ms, files: %{}}}
  end

  @impl true
  def handle_info(:poll, state) do
    new_files = poll_directory(state.log_dir, state.files, state.store)
    schedule_poll(state.poll_ms)
    {:noreply, %{state | files: new_files}}
  end

  defp schedule_poll(ms), do: Process.send_after(self(), :poll, ms)

  defp poll_directory(log_dir, files, store) do
    case File.ls(log_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&(Path.extname(&1) == ".log"))
        |> Enum.reduce(files, &poll_file(&1, log_dir, &2, store))

      {:error, _} ->
        files
    end
  end

  defp poll_file(filename, log_dir, files, store) do
    path = Path.join(log_dir, filename)
    %{offset: offset, buffer: buffer} = Map.get(files, filename, %{offset: 0, buffer: ""})

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} ->
        handle_file_readable(filename, path, size, offset, buffer, files, store)

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

        Map.delete(files, filename)
    end
  end

  defp handle_file_readable(filename, path, size, offset, buffer, files, store) do
    {offset, buffer, rotated?} =
      if size < offset, do: {0, "", true}, else: {offset, buffer, false}

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

    Map.put(files, filename, %{offset: new_offset, buffer: new_buffer})
  end

  defp process_new_bytes(path, offset, buffer, filename, store) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        {:ok, _} = :file.position(file, offset)
        new_bytes = IO.binread(file, :eof)
        File.close(file)

        new_bytes = if is_binary(new_bytes), do: new_bytes, else: ""
        all_content = buffer <> new_bytes
        {complete, remainder} = split_lines(all_content)

        {failures, last_log_at} =
          Enum.reduce(complete, {0, nil}, &parse_and_ingest(&1, &2, filename, store))

        consumed = byte_size(all_content) - byte_size(remainder)
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

  defp split_lines(content) do
    parts = String.split(content, "\n")
    {last, rest} = List.pop_at(parts, -1)
    complete = Enum.reject(rest, &(String.trim(&1) == ""))
    {complete, last || ""}
  end
end
