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

      # Hex
      description: "Req plugin for Server-Sent Events.",
      package: package(),

      # Docs
      name: "ReqServerSentEvents",
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:bypass, "~> 2.1", only: :test, runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
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
