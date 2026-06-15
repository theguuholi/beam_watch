defmodule BeamWatch.Ingestion.WatcherStateTest do
  use ExUnit.Case, async: true

  alias BeamWatch.Ingestion.WatcherState

  # --- new/0 ---

  test "new/0 returns empty state" do
    s = WatcherState.new()
    assert s.files == %{}
  end

  # --- get/2 ---

  test "get/2 returns default zero-offset entry for unknown file" do
    s = WatcherState.new()
    assert WatcherState.get(s, "docker.log") == %{offset: 0, buffer: ""}
  end

  test "get/2 returns stored entry for known file" do
    s = WatcherState.new() |> WatcherState.put("docker.log", 1024, "partial")
    assert WatcherState.get(s, "docker.log") == %{offset: 1024, buffer: "partial"}
  end

  # --- put/4 ---

  test "put/4 stores offset and buffer for a file" do
    s = WatcherState.new() |> WatcherState.put("syslog.log", 512, "")
    assert s.files["syslog.log"] == %{offset: 512, buffer: ""}
  end

  test "put/4 overwrites existing entry" do
    s =
      WatcherState.new()
      |> WatcherState.put("syslog.log", 100, "buf")
      |> WatcherState.put("syslog.log", 200, "")

    assert s.files["syslog.log"].offset == 200
    assert s.files["syslog.log"].buffer == ""
  end

  # --- remove/2 ---

  test "remove/2 removes a tracked file" do
    s =
      WatcherState.new()
      |> WatcherState.put("docker.log", 100, "")
      |> WatcherState.remove("docker.log")

    assert s.files == %{}
  end

  test "remove/2 is a no-op for unknown file" do
    s = WatcherState.new() |> WatcherState.remove("unknown.log")
    assert s.files == %{}
  end

  # --- rotated?/2 ---

  test "rotated?/2 returns true when current size is less than tracked offset" do
    assert WatcherState.rotated?(50, 200) == true
  end

  test "rotated?/2 returns false when current size equals tracked offset" do
    assert WatcherState.rotated?(200, 200) == false
  end

  test "rotated?/2 returns false when current size is greater than tracked offset" do
    assert WatcherState.rotated?(500, 200) == false
  end

  # --- split_lines/1 ---

  test "split_lines/1 returns complete lines and the remainder after the last newline" do
    {lines, remainder} = WatcherState.split_lines("line1\nline2\npartial")
    assert lines == ["line1", "line2"]
    assert remainder == "partial"
  end

  test "split_lines/1 returns empty remainder when content ends with newline" do
    {lines, remainder} = WatcherState.split_lines("line1\nline2\n")
    assert lines == ["line1", "line2"]
    assert remainder == ""
  end

  test "split_lines/1 returns no lines and full content as remainder when no newline present" do
    {lines, remainder} = WatcherState.split_lines("no newline here")
    assert lines == []
    assert remainder == "no newline here"
  end

  test "split_lines/1 skips blank lines" do
    {lines, _remainder} = WatcherState.split_lines("line1\n\nline2\n")
    assert lines == ["line1", "line2"]
  end

  test "split_lines/1 handles empty string" do
    {lines, remainder} = WatcherState.split_lines("")
    assert lines == []
    assert remainder == ""
  end
end
