defmodule Greenhouse.Application do
  @moduledoc """
  OTP Application entrypoint and top-level supervision tree for Greenhouse.
  """

  use Application

  @impl Application
  @spec start(Application.start_type(), term()) :: Supervisor.on_start()
  def start(_type, _args) do
    children = [
      {Greenhouse.Storage, Application.get_env(:greenhouse, Greenhouse.Storage, [])},
      {Greenhouse.AccountStore, Application.get_env(:greenhouse, Greenhouse.AccountStore, [])},
      {Greenhouse.ConfigManager, Application.get_env(:greenhouse, Greenhouse.ConfigManager, [])},
      {Greenhouse.MQTT.Client, Application.get_env(:greenhouse, Greenhouse.MQTT.Client, [])},
      {Greenhouse.Web.Server, Application.get_env(:greenhouse, Greenhouse.Web.Server, [])}
    ]

    opts = [strategy: :one_for_one, name: Greenhouse.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
