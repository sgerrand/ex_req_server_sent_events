defmodule ReqServerSentEventsTest do
  use ExUnit.Case, async: true

  alias ReqServerSentEvents.Frame

  # Helper: build a Req.Request with the given into: value, attach the plugin,
  # and return the rewritten into: function (or collectable) for direct testing.
  defp build_req(into: value) do
    Req.new(into: value) |> ReqServerSentEvents.attach()
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
  end
end
