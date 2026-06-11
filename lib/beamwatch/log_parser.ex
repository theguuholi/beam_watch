defmodule BeamWatch.LogParser do
  @moduledoc false

  alias BeamWatch.LogEvent

  @kv_re ~r/(\w+)=(?:"([^"]*)"|([\S]*))/

  @spec parse_line(String.t(), String.t()) :: {:ok, LogEvent.t()} | {:error, :malformed}
  def parse_line(line, source) when is_binary(line) and is_binary(source) do
    trimmed = String.trim(line)

    if byte_size(trimmed) == 0 do
      {:error, :malformed}
    else
      {timestamp, payload} = extract_timestamp(trimmed)
      fields = extract_fields(payload)

      {:ok,
       %LogEvent{
         timestamp: timestamp || DateTime.utc_now(),
         source: source,
         raw: trimmed,
         fields: fields
       }}
    end
  end

  defp extract_timestamp(line) do
    case String.split(line, " ", parts: 2) do
      [candidate, rest] ->
        case DateTime.from_iso8601(candidate) do
          {:ok, dt, _} -> {dt, rest}
          _ -> {nil, line}
        end

      _ ->
        {nil, line}
    end
  end

  defp extract_fields(payload) do
    @kv_re
    |> Regex.scan(payload)
    |> Enum.reduce(%{}, fn match, acc ->
      case match do
        # Quoted value: [full_match, key, quoted_value]
        [_, key, quoted] when quoted != "" -> Map.put(acc, key, quoted)
        # Unquoted value: [full_match, key, "", value]
        [_, key, "", value] -> Map.put(acc, key, value)
        # Catch-all for other patterns
        _ -> acc
      end
    end)
  end
end
