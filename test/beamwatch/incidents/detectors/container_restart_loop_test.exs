defmodule BeamWatch.Incidents.Detectors.ContainerRestartLoopTest do
  use ExUnit.Case, async: true

  alias BeamWatch.Incidents.Detectors.ContainerRestartLoop
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
      ContainerRestartLoop.process(line, inc, state)
    end)
  end

  test "opens incident when 4 die events occur within 60 seconds" do
    lines = [
      pl("docker.log", 0, "container=plex event=die exit_code=137"),
      pl("docker.log", 8, "container=plex event=die exit_code=137"),
      pl("docker.log", 15, "container=plex event=die exit_code=137"),
      pl("docker.log", 21, "container=plex event=die exit_code=137")
    ]

    {incidents, _state} = run_lines(lines)

    assert %Incident{
             type: :container_restart_loop,
             resource: "plex",
             status: :active,
             severity: :critical
           } = incidents["container_restart_loop:plex"]
  end

  test "does not open incident for 3 die events in 60 seconds" do
    lines = [
      pl("docker.log", 0, "container=plex event=die exit_code=137"),
      pl("docker.log", 8, "container=plex event=die exit_code=137"),
      pl("docker.log", 15, "container=plex event=die exit_code=137")
    ]

    {incidents, _state} = run_lines(lines)

    refute Map.has_key?(incidents, "container_restart_loop:plex")
  end

  test "die events older than 60 seconds are excluded from the window" do
    lines = [
      pl("docker.log", 0, "container=plex event=die exit_code=137"),
      pl("docker.log", 61, "container=plex event=die exit_code=137"),
      pl("docker.log", 69, "container=plex event=die exit_code=137"),
      pl("docker.log", 77, "container=plex event=die exit_code=137")
    ]

    {incidents, _state} = run_lines(lines)

    refute Map.has_key?(incidents, "container_restart_loop:plex")
  end

  test "supporting healthcheck evidence appended to existing incident" do
    lines = [
      pl("docker.log", 0, "container=plex event=die exit_code=137"),
      pl("docker.log", 8, "container=plex event=die exit_code=137"),
      pl("docker.log", 15, "container=plex event=die exit_code=137"),
      pl("docker.log", 21, "container=plex event=die exit_code=137"),
      pl("app.log", 24, "service=plex healthcheck failed path=/identity request_id=plex-a")
    ]

    {incidents, _state} = run_lines(lines)

    incident = incidents["container_restart_loop:plex"]
    assert length(incident.evidence) == 5
  end

  test "home-assistant single die event does not create an incident" do
    lines = [
      pl("docker.log", 0, "container=home-assistant event=die exit_code=0")
    ]

    {incidents, _state} = run_lines(lines)

    refute Map.has_key?(incidents, "container_restart_loop:home-assistant")
  end

  test "first_seen is the timestamp of the first die event" do
    base = ~U[2026-06-05 15:00:00Z]

    lines = [
      pl("docker.log", 0, "container=plex event=die exit_code=137"),
      pl("docker.log", 8, "container=plex event=die exit_code=137"),
      pl("docker.log", 15, "container=plex event=die exit_code=137"),
      pl("docker.log", 21, "container=plex event=die exit_code=137")
    ]

    {incidents, _state} = run_lines(lines)

    incident = incidents["container_restart_loop:plex"]
    assert incident.first_seen == base
    assert incident.last_seen == DateTime.add(base, 21, :second)
  end

  test "lines from unrelated sources are ignored" do
    lines = [
      pl("syslog.log", 0, "container=plex event=die exit_code=137")
    ]

    {incidents, _state} = run_lines(lines)

    assert incidents == %{}
  end
end
