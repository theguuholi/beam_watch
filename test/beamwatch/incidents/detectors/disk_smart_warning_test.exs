defmodule BeamWatch.Incidents.Detectors.DiskSmartWarningTest do
  use ExUnit.Case, async: true

  alias BeamWatch.Incidents.Detectors.DiskSmartWarning
  alias BeamWatch.Incidents.Incident
  alias BeamWatch.Ingestion.ParsedLine

  defp pl(source, offset_seconds, payload) do
    base = ~U[2026-06-05 15:00:00Z]
    at = DateTime.add(base, offset_seconds, :second)

    %ParsedLine{
      at: at,
      source: source,
      payload: payload,
      raw: "#{DateTime.to_iso8601(at)} #{payload}"
    }
  end

  defp run_lines(lines) do
    Enum.reduce(lines, {%{}, %{}}, fn line, {inc, state} ->
      DiskSmartWarning.process(line, inc, state)
    end)
  end

  test "opens incident on SMART warning" do
    line =
      pl(
        "syslog.log",
        0,
        "emhttpd: disk3 SMART warning: Reallocated_Sector_Ct raw=28 threshold=10"
      )

    {incidents, _state} = DiskSmartWarning.process(line, %{}, %{})

    assert %Incident{
             type: :disk_smart_warning,
             resource: "disk3",
             status: :active,
             severity: :warning
           } =
             incidents["disk_smart_warning:disk3:2026-06-05"]
  end

  test "groups repeated warnings for same disk on same day" do
    lines = [
      pl(
        "syslog.log",
        0,
        "emhttpd: disk3 SMART warning: Reallocated_Sector_Ct raw=28 threshold=10"
      ),
      pl(
        "syslog.log",
        18,
        "emhttpd: disk3 SMART warning: Current_Pending_Sector raw=2 threshold=0"
      )
    ]

    {incidents, _state} = run_lines(lines)

    assert map_size(incidents) == 1
    assert length(incidents["disk_smart_warning:disk3:2026-06-05"].evidence) == 2
  end

  test "auto-resolves on SMART check passed" do
    lines = [
      pl(
        "syslog.log",
        0,
        "emhttpd: disk3 SMART warning: Reallocated_Sector_Ct raw=28 threshold=10"
      ),
      pl("syslog.log", 1500, "emhttpd: disk3 SMART check passed")
    ]

    {incidents, _state} = run_lines(lines)

    assert incidents["disk_smart_warning:disk3:2026-06-05"].status == :resolved
  end

  test "SMART check passed does not crash when no open incident exists" do
    line = pl("syslog.log", 0, "emhttpd: disk1 SMART check passed")
    assert {%{}, %{}} = DiskSmartWarning.process(line, %{}, %{})
  end

  test "ignores lines from other sources" do
    line = pl("docker.log", 0, "emhttpd: disk3 SMART warning: Reallocated_Sector_Ct raw=28")
    {incidents, _state} = DiskSmartWarning.process(line, %{}, %{})

    assert incidents == %{}
  end

  test "benign SMART check passed for disk1 does not affect disk3 incident" do
    lines = [
      pl(
        "syslog.log",
        0,
        "emhttpd: disk3 SMART warning: Reallocated_Sector_Ct raw=28 threshold=10"
      ),
      pl("syslog.log", 10, "emhttpd: disk1 SMART check passed")
    ]

    {incidents, _state} = run_lines(lines)

    assert incidents["disk_smart_warning:disk3:2026-06-05"].status == :active
  end
end
