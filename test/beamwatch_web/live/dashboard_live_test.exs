defmodule BeamWatchWeb.DashboardLiveTest do
  use BeamWatchWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BeamWatch.Incidents.Incident

  setup do
    target =
      Path.join(System.tmp_dir!(), "beamwatch-dev-controls-#{System.unique_integer([:positive])}")

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

  test "dev controls append validation logs and clear the log directory", %{
    conn: conn,
    target: target
  } do
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "Dev log controls"
    assert render_click(element(view, "button", "Add validation logs")) =~ "Added"
    assert target |> Path.join("docker.log") |> File.read!() =~ "container=plex event=die"
    assert target |> Path.join("smb.log") |> File.read!() =~ "Permission denied share=media"

    assert render_click(element(view, "button", "Clear log dir")) =~ "Cleared"
    assert File.ls!(target) == []
  end

  test "renders empty state with no incidents", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "No active incidents"
    assert html =~ "Incident Triage"
  end

  test "renders active incident pushed via PubSub", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    incident = %Incident{
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

    Phoenix.PubSub.broadcast(BeamWatch.PubSub, "beamwatch:dashboard", {
      :dashboard_updated,
      %{
        incidents: %{incident.id => incident},
        source_health: %{},
        recent_activity: [],
        silenced_types: MapSet.new()
      }
    })

    html = render(view)
    assert html =~ "plex"
    assert html =~ "Container Restart Loop"
    assert html =~ "active"
  end

  test "acknowledge button fires event without crash", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    incident = %Incident{
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

    Phoenix.PubSub.broadcast(BeamWatch.PubSub, "beamwatch:dashboard", {
      :dashboard_updated,
      %{
        incidents: %{incident.id => incident},
        source_health: %{},
        recent_activity: [],
        silenced_types: MapSet.new()
      }
    })

    html = render(view)
    assert html =~ "Ack"
    # Clicking does not crash
    render_click(view, "acknowledge", %{"id" => "container_restart_loop:plex"})
    assert render(view)
  end

  test "source health table renders when health data is present", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    Phoenix.PubSub.broadcast(BeamWatch.PubSub, "beamwatch:dashboard", {
      :dashboard_updated,
      %{
        incidents: %{},
        source_health: %{
          "docker.log" => %BeamWatch.SourceHealth{
            file: "docker.log",
            exists?: true,
            size_bytes: 1024,
            last_read_at: ~U[2026-06-05 15:01:40Z],
            last_log_at: ~U[2026-06-05 15:01:40Z],
            byte_offset: 1024,
            parse_failures: 0,
            rotated?: false
          }
        },
        recent_activity: [],
        silenced_types: MapSet.new()
      }
    })

    html = render(view)
    assert html =~ "docker.log"
    assert html =~ "ok"
  end

  defp restore_env(key, nil), do: Application.delete_env(:beamwatch, key)
  defp restore_env(key, value), do: Application.put_env(:beamwatch, key, value)
end
