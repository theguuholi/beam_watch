defmodule BeamWatch.Incidents.IncidentStoreTest do
  use ExUnit.Case, async: false

  alias BeamWatch.Incidents.IncidentStore
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

  defp four_plex_dies do
    [
      pl("docker.log", 0, "container=plex event=die exit_code=137"),
      pl("docker.log", 8, "container=plex event=die exit_code=137"),
      pl("docker.log", 15, "container=plex event=die exit_code=137"),
      pl("docker.log", 21, "container=plex event=die exit_code=137")
    ]
  end

  setup do
    {:ok, pid} = IncidentStore.start_link(name: nil, pubsub: BeamWatch.PubSub)
    {:ok, pid: pid}
  end

  test "ingest line creates incident when threshold is met", %{pid: store} do
    Enum.each(four_plex_dies(), &IncidentStore.ingest_line(store, &1))
    # give cast time to process
    _ = IncidentStore.get_state(store)
    state = IncidentStore.get_state(store)

    assert Map.has_key?(state.incidents, "container_restart_loop:plex")
  end

  test "acknowledge changes status to :acknowledged", %{pid: store} do
    Enum.each(four_plex_dies(), &IncidentStore.ingest_line(store, &1))
    _ = IncidentStore.get_state(store)
    :ok = IncidentStore.acknowledge(store, "container_restart_loop:plex")
    state = IncidentStore.get_state(store)

    assert state.incidents["container_restart_loop:plex"].status == :acknowledged
  end

  test "silence with :incident scope changes status to :silenced", %{pid: store} do
    Enum.each(four_plex_dies(), &IncidentStore.ingest_line(store, &1))
    _ = IncidentStore.get_state(store)
    :ok = IncidentStore.silence(store, "container_restart_loop:plex", :incident)
    state = IncidentStore.get_state(store)

    assert state.incidents["container_restart_loop:plex"].status == :silenced
    assert state.incidents["container_restart_loop:plex"].silence_scope == :incident
  end

  test "silence with :type scope silences all incidents of that type", %{pid: store} do
    Enum.each(four_plex_dies(), &IncidentStore.ingest_line(store, &1))
    _ = IncidentStore.get_state(store)
    :ok = IncidentStore.silence(store, "container_restart_loop:plex", :type)
    state = IncidentStore.get_state(store)

    assert state.incidents["container_restart_loop:plex"].status == :silenced
    assert MapSet.member?(state.silenced_types, :container_restart_loop)
  end

  test "new incidents of silenced type are created with :silenced status", %{pid: store} do
    :ok = IncidentStore.silence(store, "container_restart_loop:nonexistent", :type)
    Enum.each(four_plex_dies(), &IncidentStore.ingest_line(store, &1))
    _ = IncidentStore.get_state(store)
    state = IncidentStore.get_state(store)

    assert state.incidents["container_restart_loop:plex"].status == :silenced
  end

  test "resolve changes status to :resolved", %{pid: store} do
    Enum.each(four_plex_dies(), &IncidentStore.ingest_line(store, &1))
    _ = IncidentStore.get_state(store)
    :ok = IncidentStore.resolve(store, "container_restart_loop:plex")
    state = IncidentStore.get_state(store)

    assert state.incidents["container_restart_loop:plex"].status == :resolved
  end

  test "clear_silence restores :active status", %{pid: store} do
    Enum.each(four_plex_dies(), &IncidentStore.ingest_line(store, &1))
    _ = IncidentStore.get_state(store)
    :ok = IncidentStore.silence(store, "container_restart_loop:plex", :incident)
    :ok = IncidentStore.clear_silence(store, "container_restart_loop:plex")
    state = IncidentStore.get_state(store)

    assert state.incidents["container_restart_loop:plex"].status == :active
    assert state.incidents["container_restart_loop:plex"].silence_scope == nil
  end

  test "malformed lines are tracked in source health parse_failures", %{pid: store} do
    IncidentStore.ingest_malformed(store, "docker.log")
    IncidentStore.ingest_malformed(store, "docker.log")
    state = IncidentStore.get_state(store)

    assert state.source_health["docker.log"].parse_failures == 2
  end

  test "recent activity keeps the last 50 lines newest first", %{pid: store} do
    Enum.each(1..55, fn i ->
      IncidentStore.ingest_line(store, pl("syslog.log", i, "emhttpd: Array event=#{i}"))
    end)

    state = IncidentStore.get_state(store)
    assert length(state.recent_activity) == 50
    [newest | _] = state.recent_activity
    assert newest.line =~ "event=55"
  end
end
