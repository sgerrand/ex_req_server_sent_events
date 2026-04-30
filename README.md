# ReqServerSentEvents

[Req](https://github.com/wojtekmach/req) plugin for [Server-Sent
Events](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events)
(SSE).

Decodes chunked SSE byte streams into `%ReqServerSentEvents.Frame{}` structs, transparently
wrapping all three of Req's streaming hooks: `into: fun`, `into: :self`, and
`into: collectable`.

## Installation

```elixir
def deps do
  [
    {:req, "~> 0.5"},
    {:req_server_sent_events, "~> 0.1.0"}
  ]
end
```

## Usage

Attach the plugin to any `%Req.Request{}` with `ReqServerSentEvents.attach/2`. It rewrites
the `into:` option in place so that each complete SSE frame is decoded to a
`%ReqServerSentEvents.Frame{}` before reaching your handler.

### `into: fun`

Your function receives `{:sse_event, %ReqServerSentEvents.Frame{}}` instead of
`{:data, binary}`. Return `{:cont, {req, resp}}` to continue or
`{:halt, {req, resp}}` to stop early.

```elixir
Req.new(url: "https://example.com/events")
|> ReqServerSentEvents.attach()
|> Req.get!(into: fn {:sse_event, frame}, {req, resp} ->
  IO.inspect(frame)
  {:cont, {req, resp}}
end)
```

### `into: :self`

Decoded frames are sent to the calling process as `{ref, {:sse_event, %Frame{}}}`.
A `{ref, :sse_done}` sentinel is sent when the stream ends. Retrieve the ref with
`ReqServerSentEvents.ref/1`.

```elixir
task = Task.async(fn ->
  Req.new(url: "https://example.com/events")
  |> ReqServerSentEvents.attach()
  |> Req.get!(into: :self)
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

### `into: collectable`

Decoded frames are collected into any `Collectable`. The request blocks until
the server closes the connection, making this best suited for finite streams.

```elixir
{:ok, resp} =
  Req.new(url: "https://example.com/events")
  |> ReqServerSentEvents.attach()
  |> Req.get(into: [])

frames = resp.body  # [%ReqServerSentEvents.Frame{}, ...]
```

## Frame fields

Each decoded event is a `%ReqServerSentEvents.Frame{}` struct:

| Field | Type | Description |
|---|---|---|
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
