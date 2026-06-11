defmodule BeamWatch.LogFeed.Interleaver do
  @moduledoc false

  def interleave(streams) do
    streams
    |> Enum.map(fn {_name, entries} -> entries end)
    |> Enum.reject(&(&1 == []))
    |> round_robin([])
    |> Enum.reverse()
  end

  defp round_robin([], acc), do: acc

  defp round_robin(streams, acc) do
    {entries, remaining} =
      Enum.reduce(streams, {[], []}, fn
        [entry | rest], {entries, remaining} ->
          remaining = if rest == [], do: remaining, else: [rest | remaining]
          {[entry | entries], remaining}
      end)

    round_robin(Enum.reverse(remaining), entries ++ acc)
  end
end
