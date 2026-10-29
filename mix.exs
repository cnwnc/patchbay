defmodule Patchbay.MixProject do
  use Mix.Project

  def project do
    [
      app: :patchbay,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: [
        main_module: Patchbay.CLI,
        name: "patchbay",
        emu_args: "-noinput -patchbay_escript true"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Patchbay.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:toml_elixir, "~> 3.3"},
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_html, "~> 4.2"},
      {:bandit, "~> 1.7"},
      {:jason, "~> 1.4"},
      {:lazy_html, "~> 0.1.13", only: :test}
    ]
  end
end
