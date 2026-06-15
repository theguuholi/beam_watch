defmodule BeamWatch.Incidents.StoreStateTest do
  use ExUnit.Case, async: true

  alias BeamWatch.Incidents.Incident
  alias BeamWatch.Incidents.StoreState
  alias BeamWatch.Ingestion.ParsedLine
  alias BeamWatch.SourceHealth

  defp state, do: StoreState.new()

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

  defp plex_incident do
    %Incident{
      id: "container_restart_loop:plex",
      type: :container_restart_loop,
      resource: "plex",
      severity: :critical,
      status: :active,
      first_seen: ~U[2026-06-05 15:00:00Z],
      last_seen: ~U[2026-06-05 15:00:21Z],
      evidence: [],
      silence_scope: nil
    }
  end

  defp sonarr_incident do
    %Incident{
      id: "container_restart_loop:sonarr",
      type: :container_restart_loop,
      resource: "sonarr",
      severity: :critical,
      status: :active,
      first_seen: ~U[2026-06-05 15:01:00Z],
      last_seen: ~U[2026-06-05 15:01:21Z],
      evidence: [],
      silence_scope: nil
    }
  end

  defp state_with(incidents) do
    %{StoreState.new() | incidents: incidents}
  end

  # --- new/0 ---

  test "new/0 returns empty state with detector slots initialized" do
    s = state()
    assert s.incidents == %{}
    assert s.source_health == %{}
    assert s.recent_activity == []
    assert MapSet.size(s.silenced_types) == 0
    assert map_size(s.detector_states) == 4
  end

  # --- ingest_line/2 ---

  test "ingest_line/2 appends to recent_activity, newest first" do
    s =
      state()
      |> StoreState.ingest_line(pl("docker.log", 0, "container=plex event=start"))
      |> StoreState.ingest_line(pl("docker.log", 1, "container=plex event=die exit_code=1"))

    assert length(s.recent_activity) == 2
    assert hd(s.recent_activity).line =~ "event=die"
  end

  test "ingest_line/2 caps recent_activity at 50 entries" do
    s =
      Enum.reduce(1..55, state(), fn i, acc ->
        StoreState.ingest_line(acc, pl("syslog.log", i, "emhttpd: event=#{i}"))
      end)

    assert length(s.recent_activity) == 50
    assert hd(s.recent_activity).line =~ "event=55"
  end

  test "ingest_line/2 opens incident when detector threshold is met" do
    die_lines = [
      pl("docker.log", 0, "container=plex event=die exit_code=137"),
      pl("docker.log", 8, "container=plex event=die exit_code=137"),
      pl("docker.log", 15, "container=plex event=die exit_code=137"),
      pl("docker.log", 21, "container=plex event=die exit_code=137")
    ]

    s = Enum.reduce(die_lines, state(), &StoreState.ingest_line(&2, &1))
    assert Map.has_key?(s.incidents, "container_restart_loop:plex")
  end

  # --- ingest_malformed/2 ---

  test "ingest_malformed/2 increments parse_failures for source" do
    s =
      state()
      |> StoreState.ingest_malformed("docker.log")
      |> StoreState.ingest_malformed("docker.log")

    assert s.source_health["docker.log"].parse_failures == 2
  end

  # --- update_source_health/2 ---

  test "update_source_health/2 preserves existing parse_failures" do
    health = %SourceHealth{file: "syslog.log", exists?: true, size_bytes: 1024, parse_failures: 0}

    s =
      state()
      |> StoreState.ingest_malformed("syslog.log")
      |> StoreState.update_source_health(health)

    assert s.source_health["syslog.log"].parse_failures == 1
    assert s.source_health["syslog.log"].size_bytes == 1024
  end

  # --- acknowledge/2 ---

  test "acknowledge/2 sets status to :acknowledged" do
    s = state_with(%{plex_incident().id => plex_incident()})
    s = StoreState.acknowledge(s, "container_restart_loop:plex")
    assert s.incidents["container_restart_loop:plex"].status == :acknowledged
  end

  test "acknowledge/2 is a no-op for unknown id" do
    s = StoreState.acknowledge(state(), "unknown:id")
    assert s.incidents == %{}
  end

  # --- silence_incident/2 ---

  test "silence_incident/2 silences a specific incident with :incident scope" do
    s = state_with(%{plex_incident().id => plex_incident()})
    s = StoreState.silence_incident(s, "container_restart_loop:plex")
    inc = s.incidents["container_restart_loop:plex"]
    assert inc.status == :silenced
    assert inc.silence_scope == :incident
  end

  # --- silence_type/2 ---

  test "silence_type/2 silences all active incidents of that type" do
    incidents = %{
      plex_incident().id => plex_incident(),
      sonarr_incident().id => sonarr_incident()
    }

    s = incidents |> state_with() |> StoreState.silence_type("container_restart_loop:plex")

    assert s.incidents["container_restart_loop:plex"].status == :silenced
    assert s.incidents["container_restart_loop:sonarr"].status == :silenced
    assert MapSet.member?(s.silenced_types, :container_restart_loop)
  end

  test "silence_type/2 adds type to silenced_types even when incident id is unknown" do
    s = StoreState.silence_type(state(), "container_restart_loop:nonexistent")
    assert MapSet.member?(s.silenced_types, :container_restart_loop)
  end

  # --- resolve/2 ---

  test "resolve/2 sets status to :resolved" do
    s = state_with(%{plex_incident().id => plex_incident()})
    s = StoreState.resolve(s, "container_restart_loop:plex")
    assert s.incidents["container_restart_loop:plex"].status == :resolved
  end

  # --- clear_silence/2 ---

  test "clear_silence/2 on :incident scope restores :active and nil scope" do
    s =
      %{plex_incident().id => plex_incident()}
      |> state_with()
      |> StoreState.silence_incident("container_restart_loop:plex")
      |> StoreState.clear_silence("container_restart_loop:plex")

    inc = s.incidents["container_restart_loop:plex"]
    assert inc.status == :active
    assert inc.silence_scope == nil
  end

  test "clear_silence/2 on :type scope re-activates all incidents of that type" do
    incidents = %{
      plex_incident().id => plex_incident(),
      sonarr_incident().id => sonarr_incident()
    }

    s =
      incidents
      |> state_with()
      |> StoreState.silence_type("container_restart_loop:plex")
      |> StoreState.clear_silence("container_restart_loop:plex")

    assert s.incidents["container_restart_loop:plex"].status == :active
    assert s.incidents["container_restart_loop:sonarr"].status == :active
    refute MapSet.member?(s.silenced_types, :container_restart_loop)
  end

  # --- clear_type_silence/2 ---

  test "clear_type_silence/2 re-activates all incidents of that type" do
    incidents = %{
      plex_incident().id => plex_incident(),
      sonarr_incident().id => sonarr_incident()
    }

    s =
      incidents
      |> state_with()
      |> StoreState.silence_type("container_restart_loop:plex")
      |> StoreState.clear_type_silence(:container_restart_loop)

    assert s.incidents["container_restart_loop:plex"].status == :active
    assert s.incidents["container_restart_loop:sonarr"].status == :active
    refute MapSet.member?(s.silenced_types, :container_restart_loop)
  end

  # --- reset/1 ---

  test "reset/1 clears incidents, activity, silenced types and health" do
    s =
      %{plex_incident().id => plex_incident()}
      |> state_with()
      |> StoreState.silence_type("container_restart_loop:plex")
      |> StoreState.ingest_malformed("docker.log")
      |> StoreState.reset()

    assert s.incidents == %{}
    assert s.source_health == %{}
    assert s.recent_activity == []
    assert MapSet.size(s.silenced_types) == 0
    assert map_size(s.detector_states) == 4
  end
end
