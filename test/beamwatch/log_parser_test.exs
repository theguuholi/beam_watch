defmodule BeamWatch.LogParserTest do
  use ExUnit.Case, async: true

  alias BeamWatch.{LogEvent, LogParser}

  describe "parse_line/2" do
    test "parses ISO8601 timestamp prefix with key=value fields" do
      line = "2026-06-05T15:04:00Z container=plex event=die exit_code=137"

      assert {:ok, %LogEvent{} = event} = LogParser.parse_line(line, "docker.log")
      assert event.timestamp == ~U[2026-06-05 15:04:00Z]
      assert event.source == "docker.log"
      assert event.raw == line
      assert event.fields["container"] == "plex"
      assert event.fields["event"] == "die"
      assert event.fields["exit_code"] == "137"
    end

    test "parses quoted values with spaces" do
      line =
        ~s(2026-06-05T15:08:00Z vm=windows11 action=start status=failed reason="cannot access storage image /mnt/user/domains/windows11/vdisk1.img")

      assert {:ok, event} = LogParser.parse_line(line, "libvirt.log")
      assert event.fields["reason"] == "cannot access storage image /mnt/user/domains/windows11/vdisk1.img"
    end

    test "returns ingestion timestamp when line has no timestamp prefix" do
      line = "not-a-timestamp service=plex healthcheck"

      assert {:ok, event} = LogParser.parse_line(line, "app.log")
      assert event.timestamp != nil
      assert event.raw == line
    end

    test "returns :malformed for an empty or whitespace-only line" do
      assert {:error, :malformed} = LogParser.parse_line("", "app.log")
      assert {:error, :malformed} = LogParser.parse_line("   ", "app.log")
    end

    test "parses syslog-style lines without key=value" do
      line = "2026-06-05T15:00:02Z emhttpd: Array Started"

      assert {:ok, event} = LogParser.parse_line(line, "syslog.log")
      assert event.timestamp == ~U[2026-06-05 15:00:02Z]
      assert event.fields == %{}
    end

    test "handles smbd permission denied line with share field" do
      line =
        "2026-06-05T15:07:00Z smbd[8112]: Permission denied share=media user=guest path=/mnt/user/media/private"

      assert {:ok, event} = LogParser.parse_line(line, "smb.log")
      assert event.fields["share"] == "media"
      assert event.fields["user"] == "guest"
    end
  end
end
