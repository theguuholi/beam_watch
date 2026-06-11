defmodule BeamWatchWeb.DashboardLiveTest do
  use BeamWatchWeb.ConnCase

  import Phoenix.LiveViewTest

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
    assert File.read!(Path.join(target, "docker.log")) =~ "container=plex event=die"
    assert File.read!(Path.join(target, "smb.log")) =~ "Permission denied share=media"

    assert render_click(element(view, "button", "Clear log dir")) =~ "Cleared"
    assert File.ls!(target) == []
  end

  defp restore_env(key, nil), do: Application.delete_env(:beamwatch, key)
  defp restore_env(key, value), do: Application.put_env(:beamwatch, key, value)
end
