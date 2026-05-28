defmodule ReqServerSentEventsTest.RaisingCollectable do
  @moduledoc false
  defstruct []
end

defimpl Collectable, for: ReqServerSentEventsTest.RaisingCollectable do
  def into(_) do
    collector = fn
      _, {:cont, _frame} -> raise RuntimeError, "boom"
      _, :done -> :done
      _, :halt -> :ok
    end

    {nil, collector}
  end
end

defmodule ReqServerSentEventsTest do
  use ExUnit.Case, async: true

  alias ReqServerSentEvents.Frame
  alias ReqServerSentEvents.FrameTooLargeError
  alias ReqServerSentEventsTest.RaisingCollectable

  # Helper: build a Req.Request with the given into: value, attach the plugin,
  # and return the rewritten into: function (or collectable) for direct testing.
  defp build_req(into: value) do
    Req.new(into: value) |> ReqServerSentEvents.attach()
  end

  defp build_req(into: value, opts: opts) do
    Req.new(into: value) |> ReqServerSentEvents.attach(opts)
  end

  # ---------------------------------------------------------------------------
  # into: nil — plugin is a no-op
  # ---------------------------------------------------------------------------

  describe "attach/1 with no into:" do
    test "returns request unchanged" do
      req = Req.new() |> ReqServerSentEvents.attach()
      assert req.into == nil
    end
  end

  # ---------------------------------------------------------------------------
  # into: fun
  # ---------------------------------------------------------------------------

  describe "into: fun" do
    setup do
      req =
        build_req(
          into: fn {:sse_event, frame}, {req, resp} ->
            frames = resp.private[:collected] || []
            resp = put_in(resp.private[:collected], frames ++ [frame])
            {:cont, {req, resp}}
          end
        )

      %{wrapped: req.into}
    end

    test "rewrites into: to a function", %{wrapped: wrapped} do
      assert is_function(wrapped, 2)
    end

    test "single chunk with one complete frame emits one event", %{wrapped: wrapped} do
      {req, resp} = Req.Request.new() |> then(&{&1, %Req.Response{status: 200, body: ""}})
      chunk = "data: hello\n\n"
      assert {:cont, {_req, resp}} = wrapped.({:data, chunk}, {req, resp})
      assert [%Frame{data: "hello"}] = resp.private[:collected]
    end

    test "single chunk with two complete frames emits two events", %{wrapped: wrapped} do
      {req, resp} = {Req.Request.new(), %Req.Response{status: 200, body: ""}}
      chunk = "data: one\n\ndata: two\n\n"
      assert {:cont, {_req, resp}} = wrapped.({:data, chunk}, {req, resp})
      assert [%Frame{data: "one"}, %Frame{data: "two"}] = resp.private[:collected]
    end

    test "frame split across two chunks emitted only on second chunk", %{wrapped: wrapped} do
      {req, resp} = {Req.Request.new(), %Req.Response{status: 200, body: ""}}

      assert {:cont, {req, resp}} = wrapped.({:data, "data: hel"}, {req, resp})
      assert resp.private[:collected] == nil

      assert {:cont, {_req, resp}} = wrapped.({:data, "lo\n\n"}, {req, resp})
      assert [%Frame{data: "hello"}] = resp.private[:collected]
    end

    test "user function returning :halt stops processing remaining frames" do
      halt_after_first = fn {:sse_event, frame}, {req, resp} ->
        frames = resp.private[:collected] || []
        resp = put_in(resp.private[:collected], frames ++ [frame])
        {:halt, {req, resp}}
      end

      req = build_req(into: halt_after_first)
      {req_new, resp_new} = {Req.Request.new(), %Req.Response{status: 200, body: ""}}

      chunk = "data: one\n\ndata: two\n\n"
      result = req.into.({:data, chunk}, {req_new, resp_new})
      assert {:halt, {_req, resp}} = result
      assert [%Frame{data: "one"}] = resp.private[:collected]
    end

    test "buffer is maintained across calls via resp.private", %{wrapped: wrapped} do
      {req, resp} = {Req.Request.new(), %Req.Response{status: 200, body: ""}}

      {:cont, {req, resp}} = wrapped.({:data, "event: ping\n"}, {req, resp})
      {:cont, {_req, resp}} = wrapped.({:data, "data: {}\n\n"}, {req, resp})

      assert [%Frame{event: "ping", data: "{}"}] = resp.private[:collected]
    end
  end

  # ---------------------------------------------------------------------------
  # into: :self
  # ---------------------------------------------------------------------------

  describe "into: :self" do
    test "rewrites :self to a function" do
      req = build_req(into: :self)
      assert is_function(req.into, 2)
    end

    test "stores sse_ref in req.private" do
      req = build_req(into: :self)
      assert is_reference(req.private[:sse_ref])
    end

    test "ref/1 returns sse_ref from the request" do
      req = build_req(into: :self)
      assert ReqServerSentEvents.ref(req) == req.private[:sse_ref]
    end

    test "ref/1 returns sse_ref from a response after the sse_done step runs" do
      req = build_req(into: :self)
      sse_ref = req.private[:sse_ref]

      step_fn = Keyword.fetch!(req.response_steps, :sse_done)
      resp = %Req.Response{status: 200, body: ""}
      {_req, resp} = step_fn.({req, resp})

      assert ReqServerSentEvents.ref(resp) == sse_ref
    end

    test "ref/1 returns sse_ref from a response even with no body chunks" do
      req = build_req(into: :self)
      sse_ref = req.private[:sse_ref]

      step_fn = Keyword.fetch!(req.response_steps, :sse_done)
      resp = %Req.Response{status: 204, body: ""}
      {_req, resp} = step_fn.({req, resp})

      assert ReqServerSentEvents.ref(resp) == sse_ref
    end

    test "decoded frames arrive as {:sse_event, %Frame{}} messages" do
      req = build_req(into: :self)
      sse_ref = req.private[:sse_ref]

      {req_new, resp} = {Req.Request.new(), %Req.Response{status: 200, body: ""}}
      req.into.({:data, "event: msg\ndata: hello\n\n"}, {req_new, resp})

      assert_received {^sse_ref, {:sse_event, %Frame{event: "msg", data: "hello"}}}
    end

    test "multiple frames in one chunk each sent as a separate message" do
      req = build_req(into: :self)
      sse_ref = req.private[:sse_ref]

      {req_new, resp} = {Req.Request.new(), %Req.Response{status: 200, body: ""}}
      req.into.({:data, "data: one\n\ndata: two\n\n"}, {req_new, resp})

      assert_received {^sse_ref, {:sse_event, %Frame{data: "one"}}}
      assert_received {^sse_ref, {:sse_event, %Frame{data: "two"}}}
    end

    test "partial chunk produces no messages" do
      req = build_req(into: :self)
      sse_ref = req.private[:sse_ref]

      {req_new, resp} = {Req.Request.new(), %Req.Response{status: 200, body: ""}}
      req.into.({:data, "data: incomplete"}, {req_new, resp})

      refute_received {^sse_ref, _}
    end

    test ":sse_done sentinel sent via response step" do
      req = build_req(into: :self)
      sse_ref = req.private[:sse_ref]

      # Simulate the response step firing (Req calls it with {req, resp})
      step_fn = Keyword.fetch!(req.response_steps, :sse_done)
      resp = %Req.Response{status: 200, body: ""}
      step_fn.({req, resp})

      assert_received {^sse_ref, :sse_done}
    end
  end

  # ---------------------------------------------------------------------------
  # into: collectable
  # ---------------------------------------------------------------------------

  describe "into: collectable" do
    test "rewrites into: to a CollectableWrapper" do
      req = build_req(into: [])
      assert %ReqServerSentEvents.CollectableWrapper{inner: []} = req.into
    end

    test "list collectable accumulates decoded frames" do
      req = build_req(into: [])
      chunks = ["data: one\n\ndata: two\n\n"]
      result = Enum.into(chunks, req.into)
      assert [%Frame{data: "one"}, %Frame{data: "two"}] = result
    end

    test "frame split across chunks collected correctly" do
      req = build_req(into: [])
      chunks = ["data: hel", "lo\n\n"]
      result = Enum.into(chunks, req.into)
      assert [%Frame{data: "hello"}] = result
    end

    test "partial frame at end of stream is discarded" do
      req = build_req(into: [])
      chunks = ["data: complete\n\n", "data: incomplete"]
      result = Enum.into(chunks, req.into)
      assert [%Frame{data: "complete"}] = result
    end

    test "empty stream produces empty collection" do
      req = build_req(into: [])
      result = Enum.into([], req.into)
      assert result == []
    end

    test "MapSet collectable deduplicates identical frames" do
      req = build_req(into: MapSet.new())
      chunks = ["data: hello\n\ndata: hello\n\ndata: world\n\n"]
      result = Enum.into(chunks, req.into)
      assert MapSet.size(result) == 2
    end

    test ":halt delegates to the inner collectable's halt handler" do
      req = build_req(into: [])
      {acc, collector} = Collectable.into(req.into)
      acc = collector.(acc, {:cont, "data: hello\n\n"})
      assert collector.(acc, :halt) == :ok
    end

    test "exception from inner collectable propagates" do
      req = build_req(into: %RaisingCollectable{})

      assert_raise RuntimeError, "boom", fn ->
        Enum.into(["data: hello\n\n"], req.into)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # :max_frame_size option
  # ---------------------------------------------------------------------------

  describe "attach/2 with :max_frame_size" do
    test "into: fun raises FrameTooLargeError when leftover exceeds limit" do
      req =
        build_req(
          into: fn {:sse_event, _}, acc -> {:cont, acc} end,
          opts: [max_frame_size: 16]
        )

      {req_new, resp} = {Req.Request.new(), %Req.Response{status: 200, body: ""}}
      huge = String.duplicate("a", 32)

      assert_raise FrameTooLargeError, ~r/exceeds :max_frame_size of 16/, fn ->
        req.into.({:data, huge}, {req_new, resp})
      end
    end

    test "into: fun does not raise when complete frames within limit" do
      req =
        build_req(
          into: fn {:sse_event, frame}, {req, resp} ->
            frames = resp.private[:collected] || []
            resp = put_in(resp.private[:collected], frames ++ [frame])
            {:cont, {req, resp}}
          end,
          opts: [max_frame_size: 64]
        )

      {req_new, resp} = {Req.Request.new(), %Req.Response{status: 200, body: ""}}
      assert {:cont, {_, resp}} = req.into.({:data, "data: small\n\n"}, {req_new, resp})
      assert [%Frame{data: "small"}] = resp.private[:collected]
    end

    test "into: :self raises FrameTooLargeError when leftover exceeds limit" do
      req = build_req(into: :self, opts: [max_frame_size: 8])

      {req_new, resp} = {Req.Request.new(), %Req.Response{status: 200, body: ""}}
      huge = String.duplicate("x", 64)

      assert_raise FrameTooLargeError, fn ->
        req.into.({:data, huge}, {req_new, resp})
      end
    end

    test "into: collectable raises FrameTooLargeError when buffer exceeds limit" do
      req = build_req(into: [], opts: [max_frame_size: 8])

      assert_raise FrameTooLargeError, fn ->
        Enum.into([String.duplicate("y", 64)], req.into)
      end
    end

    test "FrameTooLargeError carries size and limit fields" do
      err = %FrameTooLargeError{size: 100, limit: 50}
      assert Exception.message(err) =~ "100 bytes"
      assert Exception.message(err) =~ "50 bytes"
    end
  end

  # ---------------------------------------------------------------------------
  # Telemetry
  # ---------------------------------------------------------------------------

  describe "telemetry" do
    setup do
      handler_id = "test-#{:erlang.unique_integer([:positive])}"

      events = [
        [:req_server_sent_events, :stream, :start],
        [:req_server_sent_events, :frame, :decoded],
        [:req_server_sent_events, :stream, :stop]
      ]

      parent = self()

      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_telemetry/4,
        parent
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    def handle_telemetry(name, measurements, metadata, parent) do
      send(parent, {:telemetry, name, measurements, metadata})
    end

    test "into: fun emits :start, :decoded, :stop" do
      req =
        build_req(into: fn {:sse_event, _}, acc -> {:cont, acc} end)

      {req_new, resp} = {Req.Request.new(), %Req.Response{status: 200, body: ""}}
      {:cont, {_, resp}} = req.into.({:data, "data: hello\n\n"}, {req_new, resp})

      step_fn = Keyword.fetch!(req.response_steps, :sse_telemetry_stop)
      step_fn.({req_new, resp})

      assert_received {:telemetry, [:req_server_sent_events, :stream, :start], _, _}
      assert_received {:telemetry, [:req_server_sent_events, :frame, :decoded], m, md}
      assert m.bytes == byte_size("data: hello")
      assert md.frame == %Frame{data: "hello"}
      assert_received {:telemetry, [:req_server_sent_events, :stream, :stop], stop_m, _}
      assert is_integer(stop_m.duration)
    end

    test "into: :self emits :decoded with the parsed frame" do
      req = build_req(into: :self)

      {req_new, resp} = {Req.Request.new(), %Req.Response{status: 200, body: ""}}
      req.into.({:data, "event: ping\ndata: hi\n\n"}, {req_new, resp})

      assert_received {:telemetry, [:req_server_sent_events, :stream, :start], _, _}
      assert_received {:telemetry, [:req_server_sent_events, :frame, :decoded], _, md}
      assert md.frame == %Frame{event: "ping", data: "hi"}
    end

    test "into: collectable emits :decoded but not :start/:stop" do
      req = build_req(into: [])
      Enum.into(["data: one\n\ndata: two\n\n"], req.into)

      assert_received {:telemetry, [:req_server_sent_events, :frame, :decoded], _,
                       %{frame: %Frame{data: "one"}}}

      assert_received {:telemetry, [:req_server_sent_events, :frame, :decoded], _,
                       %{frame: %Frame{data: "two"}}}

      refute_received {:telemetry, [:req_server_sent_events, :stream, :start], _, _}
      refute_received {:telemetry, [:req_server_sent_events, :stream, :stop], _, _}
    end

    test ":start emitted only on first chunk, not subsequent ones" do
      req = build_req(into: fn {:sse_event, _}, acc -> {:cont, acc} end)

      {req_new, resp} = {Req.Request.new(), %Req.Response{status: 200, body: ""}}
      {:cont, {_, resp}} = req.into.({:data, "data: a\n\n"}, {req_new, resp})
      {:cont, {_, _resp}} = req.into.({:data, "data: b\n\n"}, {req_new, resp})

      assert_received {:telemetry, [:req_server_sent_events, :stream, :start], _, _}
      refute_received {:telemetry, [:req_server_sent_events, :stream, :start], _, _}
    end

    test ":stop is a no-op when no chunks arrived" do
      req = build_req(into: fn {:sse_event, _}, acc -> {:cont, acc} end)

      step_fn = Keyword.fetch!(req.response_steps, :sse_telemetry_stop)
      resp = %Req.Response{status: 200, body: ""}
      step_fn.({req, resp})

      refute_received {:telemetry, [:req_server_sent_events, :stream, :stop], _, _}
    end
  end
end
