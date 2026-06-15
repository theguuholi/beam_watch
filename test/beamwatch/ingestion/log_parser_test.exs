defmodule BeamWatch.Ingestion.LogParserTest do
  use ExUnit.Case, async: true

  alias BeamWatch.Ingestion.LogParser
  alias BeamWatch.Ingestion.ParsedLine

  test "parses a line with an ISO8601 timestamp prefix" do
    raw = "2026-06-05T15:01:40Z container=plex event=die exit_code=137"

    assert {:ok, %ParsedLine{source: "docker.log", payload: payload, raw: ^raw, at: at}} =
             LogParser.parse(raw, "docker.log")

    assert payload == "container=plex event=die exit_code=137"
    assert at.year == 2026 and at.month == 6 and at.day == 5
    assert at.hour == 15 and at.minute == 1 and at.second == 40
  end

  test "returns malformed when no timestamp prefix" do
    raw = "not-a-timestamp service=plex healthcheck"
    assert {:malformed, ^raw} = LogParser.parse(raw, "app.log")
  end

  test "returns malformed for truncated timestamp" do
    raw = "2026-06-05T15:16"
    assert {:malformed, ^raw} = LogParser.parse(raw, "smb.log")
  end

  test "returns malformed for empty line" do
    assert {:malformed, ""} = LogParser.parse("", "docker.log")
  end

  test "handles timestamp with sub-second precision" do
    raw = "2026-06-05T15:01:40.123Z payload text"
    assert {:ok, %ParsedLine{payload: "payload text"}} = LogParser.parse(raw, "app.log")
  end
end
