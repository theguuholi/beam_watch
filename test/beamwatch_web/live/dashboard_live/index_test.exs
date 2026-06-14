defmodule BeamWatchWeb.DashboardLive.IndexTest do
  use BeamWatchWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BeamWatch.Incidents.Incident
  alias BeamWatch.Incidents.IncidentStore
  alias BeamWatch.Incidents.StoreState

  setup do
    IncidentStore.reset()

    target =
      Path.join(System.tmp_dir!(), "beamwatch-test-#{System.unique_integer([:positive])}")

    previous_target = Application.get_env(:beamwatch, :log_feed_target)
    previous_controls = Application.get_env(:beamwatch, :dev_log_controls)

    Application.put_env(:beamwatch, :log_feed_target, target)
    Application.put_env(:beamwatch, :dev_log_controls, true)

    on_exit(fn ->
      restore_env(:log_feed_target, previous_target)
      restore_env(:dev_log_controls, previous_controls)
      File.rm_rf(target)
    end)

    {:ok, target: target}
  end

  # ---------------------------------------------------------------------------
  # mount/3
  # ---------------------------------------------------------------------------

  describe "mount/3" do
    test "assigns an empty store state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert socket_assigns(view).store_state == StoreState.new()
    end

    test "assigns an empty expanded_ids set", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert socket_assigns(view).expanded_ids == MapSet.new()
    end

    test "reflects dev_log_controls_enabled? from config", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert socket_assigns(view).dev_log_controls_enabled? == true
    end
  end

  # ---------------------------------------------------------------------------
  # handle_info/2 - :dashboard_updated
  # ---------------------------------------------------------------------------

  describe "handle_info/2 - :dashboard_updated" do
    test "replaces store_state in socket assigns", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      store_state = %StoreState{silenced_types: MapSet.new([:disk_smart_warning])}
      push_store_state(view, store_state)
      assert socket_assigns(view).store_state.silenced_types == MapSet.new([:disk_smart_warning])
    end

    test "propagates incidents to socket assigns", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      incident = active_incident()
      push_store_state(view, %StoreState{incidents: %{incident.id => incident}})
      assert socket_assigns(view).store_state.incidents[incident.id] == incident
    end

    test "propagates source_health to socket assigns", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      health = %BeamWatch.SourceHealth{file: "docker.log", exists?: true}
      push_store_state(view, %StoreState{source_health: %{"docker.log" => health}})
      assert socket_assigns(view).store_state.source_health["docker.log"] == health
    end
  end

  # ---------------------------------------------------------------------------
  # handle_event/3 - toggle-evidence
  # ---------------------------------------------------------------------------

  describe "handle_event/3 - toggle-evidence" do
    test "adds the incident id to expanded_ids", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "toggle-evidence", %{"id" => "container_restart_loop:plex"})
      assert MapSet.member?(socket_assigns(view).expanded_ids, "container_restart_loop:plex")
    end

    test "removes the id on a second click", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "toggle-evidence", %{"id" => "container_restart_loop:plex"})
      render_click(view, "toggle-evidence", %{"id" => "container_restart_loop:plex"})
      refute MapSet.member?(socket_assigns(view).expanded_ids, "container_restart_loop:plex")
    end

    test "toggling one id does not expand others", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "toggle-evidence", %{"id" => "container_restart_loop:plex"})
      refute MapSet.member?(socket_assigns(view).expanded_ids, "container_restart_loop:other")
    end
  end

  # ---------------------------------------------------------------------------
  # handle_event/3 - acknowledge
  # ---------------------------------------------------------------------------

  describe "handle_event/3 - acknowledge" do
    test "sets incident status to :acknowledged in the store", %{conn: conn} do
      incident = active_incident()
      seed_incident(incident)
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "acknowledge", %{"id" => incident.id})
      assert IncidentStore.get_state().incidents[incident.id].status == :acknowledged
    end
  end

  # ---------------------------------------------------------------------------
  # handle_event/3 - silence-incident
  # ---------------------------------------------------------------------------

  describe "handle_event/3 - silence-incident" do
    test "sets incident status to :silenced with :incident scope", %{conn: conn} do
      incident = active_incident()
      seed_incident(incident)
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "silence-incident", %{"id" => incident.id})
      silenced = IncidentStore.get_state().incidents[incident.id]
      assert silenced.status == :silenced
      assert silenced.silence_scope == :incident
    end
  end

  # ---------------------------------------------------------------------------
  # handle_event/3 - silence-type
  # ---------------------------------------------------------------------------

  describe "handle_event/3 - silence-type" do
    test "silences all active incidents of the same type", %{conn: conn} do
      first = active_incident()
      second = %{first | id: "container_restart_loop:other", resource: "other"}
      seed_incident(first)
      seed_incident(second)
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "silence-type", %{"id" => first.id})
      state = IncidentStore.get_state()
      assert state.incidents[first.id].status == :silenced
      assert state.incidents[second.id].status == :silenced
    end

    test "adds the type to silenced_types in the store", %{conn: conn} do
      seed_incident(active_incident())
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "silence-type", %{"id" => "container_restart_loop:plex"})
      assert MapSet.member?(IncidentStore.get_state().silenced_types, :container_restart_loop)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_event/3 - resolve
  # ---------------------------------------------------------------------------

  describe "handle_event/3 - resolve" do
    test "sets incident status to :resolved in the store", %{conn: conn} do
      incident = active_incident()
      seed_incident(incident)
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "resolve", %{"id" => incident.id})
      assert IncidentStore.get_state().incidents[incident.id].status == :resolved
    end
  end

  # ---------------------------------------------------------------------------
  # handle_event/3 - clear-silence
  # ---------------------------------------------------------------------------

  describe "handle_event/3 - clear-silence" do
    test "re-activates an incident-scoped silenced incident", %{conn: conn} do
      incident = %{active_incident() | status: :silenced, silence_scope: :incident}
      seed_incident(incident)
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "clear-silence", %{"id" => incident.id})
      cleared = IncidentStore.get_state().incidents[incident.id]
      assert cleared.status == :active
      assert cleared.silence_scope == nil
    end

    test "re-activates all incidents and removes the type when scope is :type", %{conn: conn} do
      incident = %{active_incident() | status: :silenced, silence_scope: :type}
      seed_incident(incident)
      seed_silenced_type(:container_restart_loop)
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "clear-silence", %{"id" => incident.id})
      state = IncidentStore.get_state()
      assert state.incidents[incident.id].status == :active
      refute MapSet.member?(state.silenced_types, :container_restart_loop)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_event/3 - clear-type-silence
  # ---------------------------------------------------------------------------

  describe "handle_event/3 - clear-type-silence" do
    test "removes the type from silenced_types", %{conn: conn} do
      seed_silenced_type(:container_restart_loop)
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "clear-type-silence", %{"type" => "container_restart_loop"})
      refute MapSet.member?(IncidentStore.get_state().silenced_types, :container_restart_loop)
    end

    test "re-activates type-silenced incidents", %{conn: conn} do
      incident = %{active_incident() | status: :silenced, silence_scope: :type}
      seed_incident(incident)
      seed_silenced_type(:container_restart_loop)
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "clear-type-silence", %{"type" => "container_restart_loop"})
      assert IncidentStore.get_state().incidents[incident.id].status == :active
    end
  end

  # ---------------------------------------------------------------------------
  # handle_event/3 - dev-add-validation-logs
  # ---------------------------------------------------------------------------

  describe "handle_event/3 - dev-add-validation-logs" do
    test "writes docker.log with container die events to the target dir", %{
      conn: conn,
      target: target
    } do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "dev-add-validation-logs", %{})
      assert target |> Path.join("docker.log") |> File.read!() =~ "container=plex event=die"
    end

    test "writes smb.log with permission denied events to the target dir", %{
      conn: conn,
      target: target
    } do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "dev-add-validation-logs", %{})
      assert target |> Path.join("smb.log") |> File.read!() =~ "Permission denied share=media"
    end
  end

  # ---------------------------------------------------------------------------
  # handle_event/3 - dev-clear-log-dir
  # ---------------------------------------------------------------------------

  describe "handle_event/3 - dev-clear-log-dir" do
    test "empties the target log directory", %{conn: conn, target: target} do
      File.mkdir_p!(target)
      File.write!(Path.join(target, "app.log"), "data\n")
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "dev-clear-log-dir", %{})
      assert File.ls!(target) == []
    end

    test "resets the incident store to an empty state", %{conn: conn} do
      seed_incident(active_incident())
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "dev-clear-log-dir", %{})
      assert IncidentStore.get_state().incidents == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp active_incident do
    %Incident{
      id: "container_restart_loop:plex",
      type: :container_restart_loop,
      resource: "plex",
      severity: :critical,
      status: :active,
      first_seen: ~U[2026-06-05 15:01:40Z],
      last_seen: ~U[2026-06-05 15:01:55Z],
      evidence: [],
      silence_scope: nil
    }
  end

  defp seed_incident(incident) do
    :sys.replace_state(IncidentStore, fn %{data: data} = state ->
      %{state | data: %{data | incidents: Map.put(data.incidents, incident.id, incident)}}
    end)
  end

  defp seed_silenced_type(type) do
    :sys.replace_state(IncidentStore, fn %{data: data} = state ->
      %{state | data: %{data | silenced_types: MapSet.put(data.silenced_types, type)}}
    end)
  end

  defp push_store_state(view, store_state) do
    Phoenix.PubSub.broadcast(
      BeamWatch.PubSub,
      "beamwatch:dashboard",
      {:dashboard_updated, store_state}
    )

    render(view)
    :ok
  end

  defp socket_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp restore_env(key, nil), do: Application.delete_env(:beamwatch, key)
  defp restore_env(key, value), do: Application.put_env(:beamwatch, key, value)
end
