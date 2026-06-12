defmodule BeamWatch.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BeamWatchWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:beamwatch, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: BeamWatch.PubSub},
      BeamWatch.Incidents.IncidentStore,
      {BeamWatch.Ingestion.LogWatcher, log_watcher_opts()},
      BeamWatchWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: BeamWatch.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    BeamWatchWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp log_watcher_opts do
    log_dir =
      :beamwatch
      |> Application.get_env(:log_feed_target, "priv/logs")
      |> Path.expand()

    [log_dir: log_dir]
  end
end
