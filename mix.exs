defmodule App.MixProject do
  # NOTE: You do not need to change anything in this file.
  use Mix.Project

  def project do
    [
      app: :bittorrent,
      version: "1.0.0",
      escript: [main_module: Bittorrent.CLI],
      elixir: "~> 1.10",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.2"},
      {:req, "~> 0.5.6"},
      {:poolboy, "~> 1.5.1"}
    ]
  end
end
