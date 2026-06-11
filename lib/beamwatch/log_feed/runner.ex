defmodule BeamWatch.LogFeed.Runner do
  @moduledoc false

  def run(entries, target, speed, loop?, opts \\ [])

  def run(entries, target, speed, loop?, opts) when is_list(entries) do
    File.mkdir_p!(target)
    do_run(entries, target, speed, loop?, opts)
  end

  def run(producer, target, speed, loop?, opts) when is_function(producer, 0) do
    File.mkdir_p!(target)
    do_run(producer, target, speed, loop?, opts)
  end

  defp do_run(producer, target, speed, true, opts) when is_function(producer, 0) do
    Enum.each(producer.(), &write_entry(&1, target, speed, opts))
    do_run(producer, target, speed, true, opts)
  end

  defp do_run(producer, target, speed, false, opts) when is_function(producer, 0) do
    Enum.each(producer.(), &write_entry(&1, target, speed, opts))
  end

  defp do_run(entries, target, speed, true, opts) do
    Enum.each(entries, &write_entry(&1, target, speed, opts))
    do_run(entries, target, speed, true, opts)
  end

  defp do_run(entries, target, speed, false, opts) do
    Enum.each(entries, &write_entry(&1, target, speed, opts))
  end

  defp write_entry(entry, target, speed, opts) do
    delay =
      entry.delay_ms
      |> Kernel./(max(speed, 0.01))
      |> round()

    path = Path.join(target, entry.source)

    Process.sleep(delay)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, entry.line <> "\n", [:append])

    unless Keyword.get(opts, :quiet, false) do
      IO.puts("[#{entry.source}] #{entry.line}")
    end
  end
end
