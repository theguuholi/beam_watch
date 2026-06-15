defmodule BeamWatch.Ingestion.LogParser do
  @moduledoc false

  alias BeamWatch.Ingestion.ParsedLine

  @timestamp_re ~r/\A(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z) (.*)\z/s

  @spec parse(String.t(), String.t()) :: {:ok, ParsedLine.t()} | {:malformed, String.t()}
  def parse(raw, source) do
    trimmed = String.trim_trailing(raw)

    case Regex.run(@timestamp_re, trimmed) do
      [_, ts_str, payload] ->
        case DateTime.from_iso8601(ts_str) do
          {:ok, at, _} ->
            {:ok, %ParsedLine{at: at, source: source, payload: payload, raw: raw}}

          _ ->
            {:malformed, raw}
        end

      _ ->
        {:malformed, raw}
    end
  end
end
