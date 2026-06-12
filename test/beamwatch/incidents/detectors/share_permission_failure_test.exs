defmodule BeamWatch.Incidents.Detectors.SharePermissionFailureTest do
  use ExUnit.Case, async: true

  alias BeamWatch.Incidents.Detectors.SharePermissionFailure
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
      SharePermissionFailure.process(line, inc, state)
    end)
  end

  test "opens incident on SMB permission denied" do
    line =
      pl(
        "smb.log",
        0,
        "smbd[8112]: Permission denied share=media user=guest path=/mnt/user/media/private"
      )

    {incidents, _state} = SharePermissionFailure.process(line, %{}, %{})

    assert %Incident{
             type: :share_permission_failure,
             resource: "media",
             status: :active,
             severity: :warning
           } = incidents["share_permission_failure:media"]
  end

  test "opens incident on NFS permission denied" do
    line = pl("nfs.log", 0, "nfsd: permission denied share=media client=192.168.1.12")
    {incidents, _state} = SharePermissionFailure.process(line, %{}, %{})

    assert Map.has_key?(incidents, "share_permission_failure:media")
  end

  test "updates existing incident within 10-minute window" do
    lines = [
      pl(
        "smb.log",
        0,
        "smbd[8112]: Permission denied share=media user=guest path=/mnt/user/media/private"
      ),
      pl("nfs.log", 300, "nfsd: permission denied share=media client=192.168.1.12")
    ]

    {incidents, _state} = run_lines(lines)

    assert map_size(incidents) == 1
    assert length(incidents["share_permission_failure:media"].evidence) == 2
  end

  test "resets incident after 10-minute window expires" do
    lines = [
      pl(
        "smb.log",
        0,
        "smbd[8112]: Permission denied share=media user=guest path=/mnt/user/media/private"
      ),
      pl(
        "smb.log",
        601,
        "smbd[8112]: Permission denied share=media user=guest path=/mnt/user/media/private"
      )
    ]

    {incidents, _state} = run_lines(lines)

    incident = incidents["share_permission_failure:media"]
    assert incident.status == :active
    assert length(incident.evidence) == 1
  end

  test "ignores successful share operations" do
    line = pl("smb.log", 0, "smbd[8220]: user=alex opened share=backups path=/mnt/user/backups")
    {incidents, _state} = SharePermissionFailure.process(line, %{}, %{})

    assert incidents == %{}
  end

  test "ignores lines from other sources" do
    line = pl("docker.log", 0, "Permission denied share=media")
    {incidents, _state} = SharePermissionFailure.process(line, %{}, %{})

    assert incidents == %{}
  end
end
