defmodule ReqServerSentEvents.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/sgerrand/ex_req_server_sent_events"

  def project do
    [
      app: :req_server_sent_events,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [
        tool: ExCoveralls
      ],

      # Hex
      description: "Req plugin for Server-Sent Events.",
      package: package(),

      # Docs
      name: "ReqServerSentEvents",
      docs: docs()
    ]
  end

  def application do
    []
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.html": :test,
        "coveralls.lcov": :test
      ]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:telemetry, "~> 1.0"},
      {:bypass, "~> 2.1", only: :test, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  defp docs do
    [
      main: "ReqServerSentEvents",
      extras: ["README.md", "CHANGELOG.md"],
      source_url: @source_url,
      source_ref: "v#{@version}"
    ]
  end

  defp package do
    [
      licenses: ["BSD-2-Clause"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "https://hexdocs.pm/req_server_sent_events/changelog.html"
      }
    ]
  end
end
