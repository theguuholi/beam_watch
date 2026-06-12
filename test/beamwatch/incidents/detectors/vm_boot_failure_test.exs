defmodule BeamWatch.Incidents.Detectors.VmBootFailureTest do
  use ExUnit.Case, async: true

  alias BeamWatch.Incidents.Detectors.VmBootFailure
  alias BeamWatch.Incidents.Incident
  alias BeamWatch.Ingestion.ParsedLine

  defp pl(source, offset_seconds, payload) do
    base = ~U[2026-06-05 15:00:00Z]
    at = DateTime.add(base, offset_seconds, :second)
    %ParsedLine{at: at, source: source, payload: payload, raw: "#{DateTime.to_iso8601(at)} #{payload}"}
  end

  defp run_lines(lines) do
    Enum.reduce(lines, {%{}, %{}}, fn line, {inc, state} ->
      VmBootFailure.process(line, inc, state)
    end)
  end

  test "opens incident on vm start status=failed" do
    line =
      pl(
        "libvirt.log",
        0,
        ~S(vm=windows11 action=start status=failed reason="cannot access storage image /mnt/user/domains/windows11/vdisk1.img")
      )

    {incidents, _state} = VmBootFailure.process(line, %{}, %{})

    assert %Incident{type: :vm_boot_failure, resource: "windows11", status: :active, severity: :critical} =
             incidents["vm_boot_failure:windows11"]
  end

  test "appends qemu supporting evidence to existing incident" do
    lines = [
      pl(
        "libvirt.log",
        0,
        ~S(vm=windows11 action=start status=failed reason="cannot access storage image")
      ),
      pl(
        "qemu.log",
        2,
        "qemu-system-x86_64: -drive file=/mnt/user/domains/windows11/vdisk1.img: Permission denied"
      )
    ]

    {incidents, _state} = run_lines(lines)

    incident = incidents["vm_boot_failure:windows11"]
    assert length(incident.evidence) == 2
  end

  test "appends syslog kernel bridge missing evidence" do
    lines = [
      pl(
        "libvirt.log",
        0,
        ~S(vm=windows11 action=start status=failed reason="cannot access storage image")
      ),
      pl("syslog.log", 2, "kernel: br0: port missing for vm=windows11")
    ]

    {incidents, _state} = run_lines(lines)

    assert length(incidents["vm_boot_failure:windows11"].evidence) == 2
  end

  test "auto-resolves on vm status=running" do
    lines = [
      pl(
        "libvirt.log",
        0,
        ~S(vm=windows11 action=start status=failed reason="cannot access storage image")
      ),
      pl("libvirt.log", 240, "vm=windows11 action=start status=running")
    ]

    {incidents, _state} = run_lines(lines)

    assert incidents["vm_boot_failure:windows11"].status == :resolved
  end

  test "status=running without prior failure is ignored" do
    line = pl("libvirt.log", 0, "vm=debian-dev action=start status=running")
    {incidents, _state} = VmBootFailure.process(line, %{}, %{})

    assert incidents == %{}
  end

  test "qemu evidence without prior failure is ignored" do
    line =
      pl("qemu.log", 0, "qemu-system-x86_64: terminating on signal 15 from pid 1882")

    {incidents, _state} = VmBootFailure.process(line, %{}, %{})

    assert incidents == %{}
  end

  test "ignores lines from unrelated sources" do
    line = pl("docker.log", 0, "vm=windows11 action=start status=failed")
    {incidents, _state} = VmBootFailure.process(line, %{}, %{})

    assert incidents == %{}
  end
end
