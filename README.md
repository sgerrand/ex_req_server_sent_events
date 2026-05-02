# ReqServerSentEvents

[Req](https://github.com/wojtekmach/req) plugin for [Server-Sent
Events](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events)
(SSE).

Decodes chunked SSE byte streams into `%ReqServerSentEvents.Frame{}` structs, transparently
wrapping all three of Req's streaming hooks: `into: fun`, `into: :self`, and
`into: collectable`.

[![Hex.pm](https://img.shields.io/hexpm/v/req_server_sent_events.svg)](https://hex.pm/packages/req_server_sent_events)
[![Documentation](https://img.shields.io/badge/hex-docs-purple)](https://hexdocs.pm/req_server_sent_events)
[![CI](https://github.com/sgerrand/ex_req_server_sent_events/actions/workflows/ci.yml/badge.svg)](https://github.com/sgerrand/ex_req_server_sent_events/actions/workflows/ci.yml)
[![Coverage](https://coveralls.io/repos/github/sgerrand/ex_req_server_sent_events/badge.svg?branch=main)](https://coveralls.io/github/sgerrand/ex_req_server_sent_events?branch=main)

## Installation

<!-- x-release-please-start-version -->
```elixir
def deps do
  [
    {:req, "~> 0.5"},
    {:req_server_sent_events, "~> 0.1.0"}
  ]
end
```
<!-- x-release-please-end -->

## Usage

Attach the plugin to any `%Req.Request{}` with `ReqServerSentEvents.attach/1`. It rewrites
the `into:` option in place so that each complete SSE frame is decoded to a
`%ReqServerSentEvents.Frame{}` before reaching your handler.

`into:` must be set on the request **before** calling `attach/1` — pass it to `Req.new/1`,
not to `Req.get/2`.

### `into: collectable`

Decoded frames are collected into any `Collectable`. The request blocks until
the server closes the connection, making this best suited for finite streams.

```elixir
{:ok, resp} =
  Req.new(url: "https://example.com/events", into: [])
  |> ReqServerSentEvents.attach()
  |> Req.get()

frames = resp.body  # [%ReqServerSentEvents.Frame{}, ...]
```

### `into: fun`

Your function receives `{:sse_event, %ReqServerSentEvents.Frame{}}` instead of
`{:data, binary}`. Return `{:cont, {req, resp}}` to continue or
`{:halt, {req, resp}}` to stop early.

```elixir
Req.new(
  url: "https://example.com/events",
  into: fn {:sse_event, frame}, {req, resp} ->
    IO.inspect(frame)
    {:cont, {req, resp}}
  end
)
|> ReqServerSentEvents.attach()
|> Req.get!()
```

### `into: :self`

Decoded frames are sent to the calling process as `{ref, {:sse_event, %Frame{}}}`.
A `{ref, :sse_done}` sentinel is sent when the stream ends. Retrieve the ref with
`ReqServerSentEvents.ref/1`.

```elixir
task = Task.async(fn ->
  Req.new(url: "https://example.com/events", into: :self)
  |> ReqServerSentEvents.attach()
  |> Req.get!()
end)

resp = Task.await(task)
ref = ReqServerSentEvents.ref(resp)

Stream.resource(
  fn -> ref end,
  fn ref ->
    receive do
      {^ref, {:sse_event, frame}} -> {[frame], ref}
      {^ref, :sse_done}           -> {:halt, ref}
    after
      30_000 -> {:halt, ref}
    end
  end,
  fn _ -> :ok end
)
|> Enum.each(&IO.inspect/1)
```

## Frame fields

Each decoded event is a `%ReqServerSentEvents.Frame{}` struct:

| Field | Type | Description |
| --- | --- | --- |
| `event` | `String.t() \| nil` | Event type (`event:` field) |
| `data` | `String.t() \| nil` | Payload; multiple `data:` lines joined with `"\n"` |
| `id` | `String.t() \| nil` | Event ID for `Last-Event-ID` reconnect header |
| `retry` | `non_neg_integer() \| nil` | Reconnection delay in milliseconds |
| `comments` | `[String.t()]` | Lines starting with `:` (keepalive, diagnostics) |

Frames with no `data:` field (e.g. comment-only keepalives) are passed through
to the handler — filter or discard them as needed.

## Development

**Requirements:** Elixir ~> 1.17, Erlang/OTP compatible with your Elixir version.

```sh
# Install dependencies
mix deps.get

# Run tests
mix test

# Run tests with coverage
mix test --cover

# Format code
mix format

# Check formatting without writing
mix format --check-formatted
```

Tests do not require a running server. The plugin's streaming logic is exercised
by calling the rewritten `into:` handlers directly with synthetic byte chunks.
The optional integration tests in `test/req_server_sent_events_integration_test.exs` use
[Bypass](https://github.com/PSPDFKit-Labs/bypass) to spin up a local HTTP server.
