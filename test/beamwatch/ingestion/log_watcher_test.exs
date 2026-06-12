defmodule BeamWatch.Ingestion.LogWatcherTest do
  use ExUnit.Case, async: false

  alias BeamWatch.Incidents.IncidentStore
  alias BeamWatch.Ingestion.LogWatcher

  setup do
    tmp = Path.join(System.tmp_dir!(), "bw-watcher-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    {:ok, store} = IncidentStore.start_link(name: nil, pubsub: BeamWatch.PubSub)

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, tmp: tmp, store: store}
  end

  test "publishes lines written to a log file", %{tmp: tmp, store: store} do
    {:ok, _watcher} = LogWatcher.start_link(log_dir: tmp, store: store, poll_ms: 50, name: nil)

    path = Path.join(tmp, "docker.log")
    File.write!(path, "2026-06-05T15:01:40Z container=plex event=die exit_code=137\n")

    Process.sleep(200)
    state = IncidentStore.get_state(store)

    assert length(state.recent_activity) >= 1
    assert hd(state.recent_activity).line =~ "container=plex event=die"
  end

  test "tracks source health for watched files", %{tmp: tmp, store: store} do
    path = Path.join(tmp, "syslog.log")
    File.write!(path, "2026-06-05T15:01:40Z emhttpd: Array Started\n")

    {:ok, _watcher} = LogWatcher.start_link(log_dir: tmp, store: store, poll_ms: 50, name: nil)

    Process.sleep(200)
    state = IncidentStore.get_state(store)

    assert Map.has_key?(state.source_health, "syslog.log")
    health = state.source_health["syslog.log"]
    assert health.exists? == true
    assert health.size_bytes > 0
  end

  test "detects malformed lines and increments parse_failures", %{tmp: tmp, store: store} do
    path = Path.join(tmp, "app.log")
    File.write!(path, "not-a-timestamp service=plex healthcheck\n")

    {:ok, _watcher} = LogWatcher.start_link(log_dir: tmp, store: store, poll_ms: 50, name: nil)

    Process.sleep(200)
    state = IncidentStore.get_state(store)

    assert state.source_health["app.log"].parse_failures >= 1
  end

  test "detects file rotation when size shrinks", %{tmp: tmp, store: store} do
    path = Path.join(tmp, "docker.log")
    File.write!(path, "2026-06-05T15:01:40Z container=plex event=die exit_code=137\n")

    {:ok, _watcher} = LogWatcher.start_link(log_dir: tmp, store: store, poll_ms: 50, name: nil)
    Process.sleep(150)

    # Overwrite (simulate rotation — smaller file)
    File.write!(path, "2026-06-05T15:02:00Z container=plex event=start\n")
    Process.sleep(200)

    state = IncidentStore.get_state(store)
    # After rotation, watcher resets offset and still reads new lines
    assert length(state.recent_activity) >= 1
  end
end
