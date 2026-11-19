defmodule Greenhouse.MixProject do
  use Mix.Project

  def project do
    [
      app: :greenhouse,
      version: "1.0.1",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :inets, :crypto],
      mod: {Greenhouse.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.14"},
      {:emqtt, github: "emqx/emqtt", tag: "1.16.1"}
    ]
  end
end
