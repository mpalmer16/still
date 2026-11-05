defmodule Still.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Still.Repo,
      Still.Writing.IndexCache,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:still, :ecto_repos), skip: skip_migrations?()},
      {Phoenix.PubSub, name: Still.PubSub},
      StillWeb.Endpoint
    ]

    children =
      if Application.get_env(:still, :automatic_backup, false),
        do: children ++ [Still.AutomaticBackup],
        else: children

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Still.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    StillWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
