defmodule BeamWatch.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BeamWatchWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:beamwatch, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: BeamWatch.PubSub},
      # Start a worker by calling: BeamWatch.Worker.start_link(arg)
      # {BeamWatch.Worker, arg},
      # Start to serve requests, typically the last entry
      BeamWatchWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: BeamWatch.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BeamWatchWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
