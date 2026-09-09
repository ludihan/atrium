defmodule Atrium.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AtriumWeb.Telemetry,
      Atrium.Repo,
      {DNSCluster, query: Application.get_env(:atrium, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Atrium.PubSub},
      # Start a worker by calling: Atrium.Worker.start_link(arg)
      # {Atrium.Worker, arg},
      # Start to serve requests, typically the last entry
      AtriumWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Atrium.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AtriumWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
