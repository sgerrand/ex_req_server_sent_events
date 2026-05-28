defmodule ReqServerSentEvents do
  @moduledoc """
  Req plugin for Server-Sent Events (SSE).

  Attach to any `%Req.Request{}` via `attach/1`. The plugin intercepts
  Req's three streaming hooks and transparently decodes raw SSE byte chunks
  into `%ReqServerSentEvents.Frame{}` structs.

  ## Usage

      # into: fun — frames delivered as {:sse_event, %Frame{}} arguments
      url
      |> Req.new(into: fn {:sse_event, frame}, {req, resp} ->
           IO.inspect(frame)
           {:cont, {req, resp}}
         end)
      |> ReqServerSentEvents.attach()
      |> Req.get!()

      # into: :self — frames sent as messages to the calling process
      task = Task.async(fn ->
        url
        |> Req.new(into: :self)
        |> ReqServerSentEvents.attach()
        |> Req.get!()
      end)
      resp = Task.await(task)
      sse_ref = ReqServerSentEvents.ref(resp)
      receive do
        {^sse_ref, {:sse_event, frame}} -> IO.inspect(frame)
        {^sse_ref, :sse_done}           -> :done
      end

      # into: collectable — frames collected into any Collectable
      {:ok, resp} =
        url
        |> Req.new(into: [])
        |> ReqServerSentEvents.attach()
        |> Req.get()
      frames = resp.body  # [%ReqServerSentEvents.Frame{}, ...]

  ## Telemetry

  The plugin emits the following `:telemetry` events:

    * `[:req_server_sent_events, :stream, :start]` — emitted on the first
      decoded chunk of an `into: fun` or `into: :self` request.
      Measurements: `%{system_time, monotonic_time}`. Metadata: `%{request: req}`.

    * `[:req_server_sent_events, :frame, :decoded]` — emitted once per
      decoded frame in any mode.
      Measurements: `%{bytes: byte_size(raw)}`. Metadata: `%{frame: frame}`.

    * `[:req_server_sent_events, :stream, :stop]` — emitted in a response
      step when an `into: fun` or `into: :self` stream ends. Only fires if
      `:start` fired (i.e. at least one chunk was processed).
      Measurements: `%{monotonic_time, duration}`. Metadata: `%{request: req, response: resp}`.

  `:start` and `:stop` are not emitted for `into: collectable` requests —
  the wrapper has no access to the response. For stream-level timing in that
  mode, use Req's own `[:req, :request, :start | :stop]` events.
  """

  @doc """
  Attach the SSE decoder to a `%Req.Request{}`.

  Rewrites `req.into` to decode raw SSE byte chunks into
  `%ReqServerSentEvents.Frame{}` structs before they reach the caller.
  When `into: :self` is used, also registers a response step that sends
  a `{ref, :sse_done}` sentinel once the stream closes.

  ## Options

    * `:max_frame_size` — maximum number of bytes allowed to accumulate in
      the pending-frame buffer between delimiters. If the buffer grows past
      this limit without seeing a `"\\n\\n"`, a
      `ReqServerSentEvents.FrameTooLargeError` is raised. Defaults to `nil`
      (unbounded).
  """
  @spec attach(Req.Request.t(), keyword()) :: Req.Request.t()
  def attach(req, opts \\ [])

  def attach(%Req.Request{} = req, opts) do
    req
    |> put_max_frame_size(Keyword.get(opts, :max_frame_size))
    |> sse_rewrite()
  end

  defp put_max_frame_size(req, nil), do: req

  defp put_max_frame_size(req, n) when is_integer(n) and n > 0 do
    Req.Request.put_private(req, :sse_max_frame_size, n)
  end

  @doc """
  Return the SSE ref for a `into: :self` request.

  Accepts either the final `%Req.Request{}` or `%Req.Response{}` — Req's
  high-level functions (`Req.get!/2` etc.) return only the response, while
  `Req.request/2` returns `{request, response}`.
  """
  @spec ref(Req.Request.t() | Req.Response.t()) :: reference() | nil
  def ref(%Req.Request{} = req), do: req.private[:sse_ref]
  def ref(%Req.Response{} = resp), do: resp.private[:sse_ref]

  defp sse_rewrite(%Req.Request{into: nil} = req), do: req

  defp sse_rewrite(%Req.Request{into: :self} = req),
    do: req |> wrap_self() |> add_telemetry_stop()

  defp sse_rewrite(%Req.Request{into: f} = req) when is_function(f, 2),
    do: req |> wrap_fun(f) |> add_telemetry_stop()

  defp sse_rewrite(%Req.Request{into: c} = req), do: wrap_collectable(req, c)

  defp add_telemetry_stop(req) do
    Req.Request.append_response_steps(req, sse_telemetry_stop: &emit_stop_if_started/1)
  end

  defp wrap_fun(%Req.Request{} = req, user_fun) do
    max_size = req.private[:sse_max_frame_size]

    wrapped = fn {:data, chunk}, {req, resp} ->
      resp = emit_start_if_needed(req, resp)

      {frames, leftover} =
        ReqServerSentEvents.Internal.decode_chunk(resp.private[:sse_buf] || "", chunk, max_size)

      resp = put_in(resp.private[:sse_buf], leftover)

      Enum.reduce_while(frames, {:cont, {req, resp}}, &reduce_frame(&1, &2, user_fun))
    end

    %{req | into: wrapped}
  end

  defp reduce_frame(frame, {:cont, {req, resp}}, user_fun) do
    case user_fun.({:sse_event, frame}, {req, resp}) do
      {:cont, acc} -> {:cont, {:cont, acc}}
      {:halt, acc} -> {:halt, {:halt, acc}}
    end
  end

  defp wrap_self(%Req.Request{} = req) do
    caller = self()
    sse_ref = make_ref()
    max_size = req.private[:sse_max_frame_size]

    wrapped = fn {:data, chunk}, {req, resp} ->
      resp = emit_start_if_needed(req, resp)

      {frames, leftover} =
        ReqServerSentEvents.Internal.decode_chunk(resp.private[:sse_buf] || "", chunk, max_size)

      resp = put_in(resp.private[:sse_buf], leftover)

      Enum.each(frames, &send(caller, {sse_ref, {:sse_event, &1}}))

      {:cont, {req, resp}}
    end

    send_done = fn {req, resp} ->
      send(caller, {sse_ref, :sse_done})
      {req, put_in(resp.private[:sse_ref], sse_ref)}
    end

    req = Req.Request.put_private(req, :sse_ref, sse_ref)
    req = %{req | into: wrapped}
    Req.Request.append_response_steps(req, sse_done: send_done)
  end

  defp wrap_collectable(%Req.Request{} = req, collectable) do
    wrapper = %ReqServerSentEvents.CollectableWrapper{
      inner: collectable,
      max_size: req.private[:sse_max_frame_size]
    }

    %{req | into: wrapper}
  end

  # ---------------------------------------------------------------------------
  # Telemetry
  # ---------------------------------------------------------------------------

  defp emit_start_if_needed(req, resp) do
    if resp.private[:sse_started_at] do
      resp
    else
      monotonic = System.monotonic_time()

      :telemetry.execute(
        [:req_server_sent_events, :stream, :start],
        %{system_time: System.system_time(), monotonic_time: monotonic},
        %{request: req}
      )

      put_in(resp.private[:sse_started_at], monotonic)
    end
  end

  defp emit_stop_if_started({req, resp}) do
    case resp.private[:sse_started_at] do
      nil ->
        {req, resp}

      started ->
        stop = System.monotonic_time()

        :telemetry.execute(
          [:req_server_sent_events, :stream, :stop],
          %{monotonic_time: stop, duration: stop - started},
          %{request: req, response: resp}
        )

        {req, resp}
    end
  end
end
