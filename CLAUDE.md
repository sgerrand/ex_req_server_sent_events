# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
mix deps.get          # install dependencies
mix compile --warnings-as-errors
mix test              # full suite
mix test --exclude integration          # unit tests only (faster local loop)
mix test test/req_server_sent_events/frame_test.exs          # frame parser unit tests only
mix test test/req_server_sent_events_test.exs                # plugin unit tests only
mix test test/req_server_sent_events_integration_test.exs    # Bypass integration tests only
mix test --cover
mix format --check-formatted
```

To run a single test by name:

```sh
mix test test/req_server_sent_events_test.exs --only "frame split across two chunks"
```

## Architecture

The plugin is three layers:

**`ReqServerSentEvents.Frame`** (`lib/req_server_sent_events/frame.ex`) — pure, stateless SSE parser. No IO, no deps. `split/1` splits a byte buffer on `"\n\n"` returning `{[complete_frames], leftover}`; `parse/1` turns one raw frame string into a `%Frame{}` struct. Both functions normalise `\r\n` line endings before processing. This is the only place SSE wire-format knowledge lives.

**`ReqServerSentEvents.CollectableWrapper`** (`lib/req_server_sent_events/collectable_wrapper.ex`) — a struct that wraps any user-supplied `Collectable`. Implements the `Collectable` protocol; the accumulator tuple `{buffer, inner_acc}` carries both the SSE byte buffer and the inner collectable's state across chunks. Delegates decoded `%Frame{}` structs to the inner collectable. Leftover bytes at `:done`/`:halt` are discarded.

**`ReqServerSentEvents`** (`lib/req_server_sent_events.ex`) — the plugin entry point. `attach/1` immediately rewrites `req.into` (a top-level field on `%Req.Request{}`, not `req.options`) by calling `sse_rewrite/1` directly. The three branches:

- `into: fun` — wraps the user function; SSE byte buffer lives in `resp.private[:sse_buf]` (flows inside Req's existing `{req, resp}` accumulator). Calls user function as `fun.({:sse_event, %Frame{}}, {req, resp})`. Uses `Enum.reduce_while` so `{:halt, ...}` propagates immediately.
- `into: :self` — rewrites to `into: fun` that sends `{sse_ref, {:sse_event, frame}}` messages; also appends a `sse_done` response step that sends `{sse_ref, :sse_done}` after the stream closes. `caller` and `sse_ref` are captured eagerly at `attach/1` time.
- `into: collectable` — replaces the user's collectable with a `%CollectableWrapper{inner: collectable}`.

`ref/1` accepts either `%Req.Request{}` or `%Req.Response{}` and reads `private[:sse_ref]`.

## Tests

`test/req_server_sent_events_test.exs` — unit tests for the plugin. Drive the plugin without HTTP by calling the rewritten `req.into` function directly with synthetic `{:data, chunk}` binaries, or feeding chunks into the `CollectableWrapper` via `Enum.into/2`. No live server is needed.

`test/req_server_sent_events/frame_test.exs` — unit tests for the pure `Frame` parser in isolation.

`test/req_server_sent_events_integration_test.exs` — integration tests tagged `@moduletag :integration`. Use [Bypass](https://github.com/PSPDFKit-Labs/bypass) to spin up a local HTTP server and exercise the full Req pipeline. Run with `mix test --exclude integration` to skip them for a faster feedback loop.
