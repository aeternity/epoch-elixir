defmodule Aeutil.Mixfile do
  use Mix.Project

  def project do
    [
      app: :aeutil,
      version: "0.1.0",
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:gproc, "~> 0.6.1"},
      {:erl_base58, "~> 0.0.1"},
      {:ex_rlp, "0.3.0"},
      # needs override as uwiger/sext edown dependency is not correctly downloading
      {:edown, "~> 0.8", override: true},
      {:enacl, github: "aeternity/enacl", ref: "2f50ba6"},
      {:merkle_patricia_tree, github: "aeternity/elixir-merkle-patricia-tree", tag: "v0.1.0"}
    ]
  end
end
