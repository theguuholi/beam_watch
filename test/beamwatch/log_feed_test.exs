defmodule BeamWatch.LogFeedTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias BeamWatch.LogFeed.CLI
  alias BeamWatch.LogFeed.Entry
  alias BeamWatch.LogFeed.Profiles
  alias BeamWatch.LogFeed.Runner

  test "sample profile is a short deterministic smoke fixture" do
    entries = Profiles.get("sample")
    text = Enum.map_join(entries, "\n", & &1.line)

    assert entries == Profiles.get("sample")
    assert Enum.count(entries) < Enum.count(Profiles.get("validation"))
    assert text =~ "container=plex event=die"
    assert text =~ "disk3 SMART warning"
    assert text =~ "Permission denied share=media"
    assert text =~ "vm=windows11 action=start status=failed"
  end

  test "validation profile contains the four required incident families" do
    entries = Profiles.get("validation")
    text = Enum.map_join(entries, "\n", & &1.line)

    assert text =~ "container=plex event=die"
    assert text =~ "service=plex healthcheck failed"
    assert text =~ "upstream plex unavailable"
    assert text =~ "disk3 SMART warning"
    assert text =~ "disk3 SMART check passed"
    assert text =~ "Permission denied share=media"
    assert text =~ "nfsd: permission denied share=media"
    assert text =~ "vm=windows11 action=start status=failed"
    assert text =~ "qemu-system-x86_64: -drive file=/mnt/user/domains/windows11/vdisk1.img"
    assert text =~ "vm=windows11 action=start status=running"
  end

  test "validation profile is deterministic" do
    first = Profiles.get("validation")
    second = Profiles.get("validation")

    assert Enum.map(first, & &1.source) == Enum.map(second, & &1.source)
    assert Enum.map(first, & &1.line) == Enum.map(second, & &1.line)
    assert Enum.map(first, & &1.delay_ms) == Enum.map(second, & &1.delay_ms)
  end

  test "container restart loop has exactly four plex die events inside sixty seconds" do
    die_events =
      "validation"
      |> Profiles.get()
      |> Enum.filter(&String.contains?(&1.line, "container=plex event=die"))

    timestamps = Enum.map(die_events, &timestamp!/1) |> Enum.sort(DateTime)

    assert length(die_events) == 4
    assert DateTime.diff(List.last(timestamps), List.first(timestamps), :second) <= 60
  end

  test "validation includes false-positive guards that should not alert by themselves" do
    entries = Profiles.get("validation")
    lines = Enum.map(entries, & &1.line)

    assert Enum.count(lines, &String.contains?(&1, "container=home-assistant event=die")) == 1
    assert Enum.any?(lines, &String.contains?(&1, "disk1 SMART check passed"))
    refute Enum.any?(lines, &String.contains?(&1, "disk1 SMART warning"))
    assert Enum.any?(lines, &String.contains?(&1, "opened share=backups"))
    refute Enum.any?(lines, &String.contains?(&1, "Permission denied share=backups"))
    assert Enum.any?(lines, &String.contains?(&1, "vm=debian-dev action=start status=running"))
  end

  test "validation includes malformed input across multiple sources and one duplicate line" do
    entries = Profiles.get("validation")

    malformed =
      Enum.filter(entries, fn entry ->
        entry.line =~ "not-a-timestamp" or
          entry.line =~ "disk=" or
          entry.line =~ "file=" or
          entry.line == "2026-06-05T15:16"
      end)

    duplicate_line_count =
      entries
      |> Enum.map(& &1.line)
      |> Enum.frequencies()
      |> Map.values()
      |> Enum.max()

    assert malformed |> Enum.map(& &1.source) |> Enum.uniq() |> length() >= 3
    assert duplicate_line_count >= 2
  end

  test "only sample and validation profiles are public" do
    assert is_list(Profiles.get("sample"))
    assert is_list(Profiles.get("validation"))
    assert Profiles.get("live") == {:error, {:unknown_profile, "live"}}
    assert Profiles.get("interleaved") == {:error, {:unknown_profile, "interleaved"}}
  end

  test "cli rejects removed replay options and unknown profiles clearly" do
    assert CLI.run(["--profile", "live"]) == {:error, "Profile not found: live"}

    assert {:error, message} = CLI.run(["--profile", "validation", "--seed", "123"])
    assert message =~ "Invalid options"
    assert message =~ "--seed"

    assert {:error, message} =
             CLI.run(["--profile", "validation", "--base-at", "2026-06-05T15:00:00Z"])

    assert message =~ "Invalid options"
    assert message =~ "--base-at"
  end

  test "cli writes deterministic validation files under the target directory" do
    target =
      Path.join(System.tmp_dir!(), "beamwatch-log-feed-#{System.unique_integer([:positive])}")

    try do
      output =
        capture_io(fn ->
          assert CLI.run([
                   "--profile",
                   "validation",
                   "--target",
                   target,
                   "--speed",
                   "1000"
                 ]) == :ok
        end)

      assert output =~ "[docker.log]"
      assert File.read!(Path.join(target, "docker.log")) =~ "container=plex event=die"
      assert File.read!(Path.join(target, "syslog.log")) =~ "disk3 SMART warning"
      assert File.read!(Path.join(target, "smb.log")) =~ "Permission denied share=media"

      assert File.read!(Path.join(target, "libvirt.log")) =~
               "vm=windows11 action=start status=failed"
    after
      File.rm_rf(target)
    end
  end

  test "cli quiet mode writes files without printing every line" do
    target =
      Path.join(System.tmp_dir!(), "beamwatch-log-feed-#{System.unique_integer([:positive])}")

    try do
      output =
        capture_io(fn ->
          assert CLI.run([
                   "--profile",
                   "validation",
                   "--target",
                   target,
                   "--speed",
                   "1000",
                   "--quiet"
                 ]) == :ok
        end)

      assert output == ""
      assert File.read!(Path.join(target, "docker.log")) =~ "container=plex event=die"
    after
      File.rm_rf(target)
    end
  end

  test "runner creates nested log source directories" do
    target =
      Path.join(System.tmp_dir!(), "beamwatch-log-feed-#{System.unique_integer([:positive])}")

    try do
      entries = [
        %Entry{source: "samba/log.smbd", delay_ms: 0, line: "nested smbd log"},
        %Entry{source: "samba/log.rpcd_lsad", delay_ms: 0, line: "nested rpc log"}
      ]

      capture_io(fn -> assert Runner.run(entries, target, 100, false) == :ok end)

      assert File.exists?(Path.join(target, "samba/log.smbd"))
      assert File.exists?(Path.join(target, "samba/log.rpcd_lsad"))
    after
      File.rm_rf(target)
    end
  end

  test "docker log environment loads only the compact feeder modules" do
    run_script =
      File.read!(Path.expand("../../log_environment/run.sh", __DIR__))

    assert run_script =~ "log_feed/fixtures.ex"
    assert run_script =~ ~s(\\"--profile\\", \\"validation\\")
    refute run_script =~ "log_feed/generators"
    refute run_script =~ "live_scenarios"
    refute run_script =~ ~s(\\"--profile\\", \\"live\\")
  end

  defp timestamp!(entry) do
    entry.line
    |> String.split(" ", parts: 2)
    |> hd()
    |> DateTime.from_iso8601()
    |> case do
      {:ok, timestamp, _offset} -> timestamp
      {:error, reason} -> flunk("expected timestamp in #{inspect(entry.line)}, got #{reason}")
    end
  end
end
