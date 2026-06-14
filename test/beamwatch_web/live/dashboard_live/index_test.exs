defmodule BeamWatchWeb.DashboardLive.IndexTest do
  use BeamWatchWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BeamWatch.Incidents.Incident
  alias BeamWatch.Incidents.IncidentStore
  alias BeamWatch.Incidents.StoreState
  alias BeamWatch.SourceHealth
  alias BeamWatchWeb.DashboardLive.Components

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
  # incident_card/1 — evidence section
  # ---------------------------------------------------------------------------

  describe "incident_card/1 evidence section" do
    test "shows evidence toggle button when incident has evidence", %{conn: conn} do
      seed_incident(incident_with_evidence())
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "button[phx-click='toggle-evidence']", "Show 1 evidence line(s)")
    end

    test "shows 'Hide evidence' after toggling open", %{conn: conn} do
      incident = incident_with_evidence()
      seed_incident(incident)
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "toggle-evidence", %{"id" => incident.id})

      assert has_element?(view, "button[phx-click='toggle-evidence']", "Hide evidence")
    end

    test "renders evidence entries when expanded", %{conn: conn} do
      incident = incident_with_evidence()
      seed_incident(incident)
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "toggle-evidence", %{"id" => incident.id})

      assert has_element?(view, "span", "[docker.log]")
      assert has_element?(view, "span", "container plex exited with code 1")
    end
  end

  # ---------------------------------------------------------------------------
  # Source health panel
  # ---------------------------------------------------------------------------

  describe "source health panel" do
    test "shows 'ok' badge for a healthy source", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      health = %SourceHealth{file: "docker.log", exists?: true}

      push_store_state(view, %StoreState{source_health: %{"docker.log" => health}})

      assert has_element?(view, "span", "ok")
    end

    test "shows 'missing' badge when the file does not exist", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      health = %SourceHealth{file: "docker.log", exists?: false}

      push_store_state(view, %StoreState{source_health: %{"docker.log" => health}})

      assert has_element?(view, "span", "missing")
    end

    test "shows 'rotated' badge when the file was rotated", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      health = %SourceHealth{file: "docker.log", exists?: true, rotated?: true}

      push_store_state(view, %StoreState{source_health: %{"docker.log" => health}})

      assert has_element?(view, "span", "rotated")
    end

    test "shows 'warnings' badge when parse_failures > 0", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      health = %SourceHealth{file: "docker.log", exists?: true, parse_failures: 3}

      push_store_state(view, %StoreState{source_health: %{"docker.log" => health}})

      assert has_element?(view, "span", "warnings")
    end

    test "formats size in MB when >= 1 MB", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      health = %SourceHealth{file: "docker.log", exists?: true, size_bytes: 2_097_152}

      push_store_state(view, %StoreState{source_health: %{"docker.log" => health}})

      assert has_element?(view, "td", "2.0 MB")
    end

    test "formats size in KB when >= 1 KB but < 1 MB", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      health = %SourceHealth{file: "docker.log", exists?: true, size_bytes: 2048}

      push_store_state(view, %StoreState{source_health: %{"docker.log" => health}})

      assert has_element?(view, "td", "2.0 KB")
    end

    test "formats size in bytes when < 1 KB", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      health = %SourceHealth{file: "docker.log", exists?: true, size_bytes: 512}

      push_store_state(view, %StoreState{source_health: %{"docker.log" => health}})

      assert has_element?(view, "td", "512 B")
    end
  end

  # ---------------------------------------------------------------------------
  # Components.format_type/1
  # ---------------------------------------------------------------------------

  describe "Components.format_type/1" do
    test "returns human-readable labels for known incident types" do
      assert Components.format_type(:container_restart_loop) == "Container Restart Loop"
      assert Components.format_type(:disk_smart_warning) == "Disk SMART Warning"
      assert Components.format_type(:share_permission_failure) == "Share Permission Failure"
      assert Components.format_type(:vm_boot_failure) == "VM Boot Failure"
    end

    test "capitalises and splits underscores for unknown types" do
      assert Components.format_type(:custom_alert) == "Custom alert"
    end
  end

  # ---------------------------------------------------------------------------
  # Components.format_dt/1
  # ---------------------------------------------------------------------------

  describe "Components.format_dt/1" do
    test "returns an em dash for nil" do
      assert Components.format_dt(nil) == "—"
    end

    test "formats a DateTime as MM-DD HH:MM:SS" do
      assert Components.format_dt(~U[2026-06-14 10:30:45Z]) == "06-14 10:30:45"
    end
  end

  # ---------------------------------------------------------------------------
  # Components.severity_border/1
  # ---------------------------------------------------------------------------

  describe "Components.severity_border/1" do
    test "returns red border for :critical" do
      assert Components.severity_border(:critical) == "border-red-300"
    end

    test "returns amber border for :warning" do
      assert Components.severity_border(:warning) == "border-amber-300"
    end

    test "falls back to zinc border for other severities" do
      assert Components.severity_border(:info) == "border-zinc-200"
    end
  end

  # ---------------------------------------------------------------------------
  # Components.severity_dot/1
  # ---------------------------------------------------------------------------

  describe "Components.severity_dot/1" do
    test "returns red dot for :critical" do
      assert Components.severity_dot(:critical) == "bg-red-500"
    end

    test "returns amber dot for :warning" do
      assert Components.severity_dot(:warning) == "bg-amber-400"
    end

    test "falls back to zinc dot for other severities" do
      assert Components.severity_dot(:info) == "bg-zinc-400"
    end
  end

  # ---------------------------------------------------------------------------
  # Components.status_badge_class/1
  # ---------------------------------------------------------------------------

  describe "Components.status_badge_class/1" do
    test "returns red for :active" do
      assert Components.status_badge_class(:active) == "bg-red-100 text-red-700"
    end

    test "returns amber for :acknowledged" do
      assert Components.status_badge_class(:acknowledged) == "bg-amber-100 text-amber-700"
    end

    test "returns zinc for :silenced" do
      assert Components.status_badge_class(:silenced) == "bg-zinc-100 text-zinc-600"
    end

    test "returns green for :resolved" do
      assert Components.status_badge_class(:resolved) == "bg-green-100 text-green-700"
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

  defp incident_with_evidence do
    %{active_incident() | evidence: [%{source: "docker.log", line: "container plex exited with code 1", at: ~U[2026-06-05 15:01:50Z]}]}
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
