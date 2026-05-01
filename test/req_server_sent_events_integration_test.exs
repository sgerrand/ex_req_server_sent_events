defmodule ReqServerSentEventsIntegrationTest do
  use ExUnit.Case, async: true

  alias ReqServerSentEvents.Frame

  setup do
    bypass = Bypass.open()
    %{bypass: bypass, url: "http://localhost:#{bypass.port}/events"}
  end

  defp stream_chunks(bypass, chunks) do
    Bypass.expect_once(bypass, "GET", "/events", fn conn ->
      conn =
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.put_resp_header("cache-control", "no-cache")

      conn = Plug.Conn.send_chunked(conn, 200)

      Enum.reduce(chunks, conn, fn chunk, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, chunk)
        conn
      end)
    end)
  end

  defp collecting_fun do
    fn {:sse_event, frame}, {req, resp} ->
      frames = resp.private[:frames] || []
      resp = put_in(resp.private[:frames], frames ++ [frame])
      {:cont, {req, resp}}
    end
  end

  # ---------------------------------------------------------------------------
  # into: fun
  # ---------------------------------------------------------------------------

  describe "into: fun over HTTP" do
    test "receives decoded frames from two chunks", %{bypass: bypass, url: url} do
      stream_chunks(bypass, ["data: hello\n\n", "event: ping\ndata: world\n\n"])

      {:ok, resp} =
        Req.new(url: url, into: collecting_fun())
        |> ReqServerSentEvents.attach()
        |> Req.get()

      assert resp.private[:frames] == [
               %Frame{data: "hello"},
               %Frame{event: "ping", data: "world"}
             ]
    end

    test "frame split across HTTP chunks assembled correctly", %{bypass: bypass, url: url} do
      stream_chunks(bypass, ["data: hel", "lo\n\n"])

      {:ok, resp} =
        Req.new(url: url, into: collecting_fun())
        |> ReqServerSentEvents.attach()
        |> Req.get()

      assert resp.private[:frames] == [%Frame{data: "hello"}]
    end

    test "CRLF line endings decoded correctly", %{bypass: bypass, url: url} do
      stream_chunks(bypass, ["event: update\r\ndata: payload\r\n\r\n"])

      {:ok, resp} =
        Req.new(url: url, into: collecting_fun())
        |> ReqServerSentEvents.attach()
        |> Req.get()

      assert resp.private[:frames] == [%Frame{event: "update", data: "payload"}]
    end

    test "returning :halt stops processing remaining frames", %{bypass: bypass, url: url} do
      stream_chunks(bypass, ["data: one\n\ndata: two\n\ndata: three\n\n"])

      halt_after_first = fn {:sse_event, frame}, {req, resp} ->
        frames = resp.private[:frames] || []
        resp = put_in(resp.private[:frames], frames ++ [frame])
        {:halt, {req, resp}}
      end

      {:ok, resp} =
        Req.new(url: url, into: halt_after_first)
        |> ReqServerSentEvents.attach()
        |> Req.get()

      assert resp.private[:frames] == [%Frame{data: "one"}]
    end
  end

  # ---------------------------------------------------------------------------
  # into: :self
  # ---------------------------------------------------------------------------

  describe "into: :self over HTTP" do
    test "frames arrive as messages and :sse_done is sent after stream closes",
         %{bypass: bypass, url: url} do
      stream_chunks(bypass, ["data: hello\n\n", "data: world\n\n"])

      req =
        Req.new(url: url, into: :self)
        |> ReqServerSentEvents.attach()

      sse_ref = ReqServerSentEvents.ref(req)
      assert {:ok, _resp} = Req.get(req)

      assert_received {^sse_ref, {:sse_event, %Frame{data: "hello"}}}
      assert_received {^sse_ref, {:sse_event, %Frame{data: "world"}}}
      assert_received {^sse_ref, :sse_done}
    end

    test "ref/1 on the response returns the same ref as on the request",
         %{bypass: bypass, url: url} do
      stream_chunks(bypass, ["data: x\n\n"])

      req =
        Req.new(url: url, into: :self)
        |> ReqServerSentEvents.attach()

      sse_ref = ReqServerSentEvents.ref(req)
      assert {:ok, resp} = Req.get(req)
      assert ReqServerSentEvents.ref(resp) == sse_ref
    end
  end

  # ---------------------------------------------------------------------------
  # into: collectable
  # ---------------------------------------------------------------------------

  describe "into: collectable over HTTP" do
    test "frames collected into a list in order", %{bypass: bypass, url: url} do
      stream_chunks(bypass, ["data: one\n\n", "data: two\n\n"])

      {:ok, resp} =
        Req.new(url: url, into: [])
        |> ReqServerSentEvents.attach()
        |> Req.get()

      assert resp.body == [%Frame{data: "one"}, %Frame{data: "two"}]
    end

    test "partial frame at end of stream discarded", %{bypass: bypass, url: url} do
      stream_chunks(bypass, ["data: complete\n\n", "data: incomplete"])

      {:ok, resp} =
        Req.new(url: url, into: [])
        |> ReqServerSentEvents.attach()
        |> Req.get()

      assert resp.body == [%Frame{data: "complete"}]
    end

    test "empty stream produces empty collection", %{bypass: bypass, url: url} do
      stream_chunks(bypass, [])

      {:ok, resp} =
        Req.new(url: url, into: [])
        |> ReqServerSentEvents.attach()
        |> Req.get()

      assert resp.body == []
    end
  end
end
