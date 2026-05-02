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

  # ---------------------------------------------------------------------------
  # Request step — rewrite req.into before the HTTP adapter runs
  # ---------------------------------------------------------------------------

  defp sse_rewrite(%Req.Request{into: nil} = req), do: req
  defp sse_rewrite(%Req.Request{into: :self} = req), do: wrap_self(req)
  defp sse_rewrite(%Req.Request{into: f} = req) when is_function(f, 2), do: wrap_fun(req, f)
  defp sse_rewrite(%Req.Request{into: c} = req), do: wrap_collectable(req, c)

  # ---------------------------------------------------------------------------
  # Response step — send :sse_done sentinel for the :self path
  # ---------------------------------------------------------------------------

  defp send_sse_done({req, resp}) do
    caller = req.private[:sse_caller]
    sse_ref = req.private[:sse_ref]

    if caller && sse_ref do
      send(caller, {sse_ref, :sse_done})
      {req, put_in(resp.private[:sse_ref], sse_ref)}
    else
      {req, resp}
    end
  end

  # ---------------------------------------------------------------------------
  # into: fun — buffer lives in resp.private[:sse_buf]
  # ---------------------------------------------------------------------------

  defp wrap_fun(%Req.Request{} = req, user_fun) do
    max_size = req.private[:sse_max_frame_size]

    wrapped = fn {:data, chunk}, {req, resp} ->
      buf = (resp.private[:sse_buf] || "") <> chunk
      {frames, leftover} = ReqServerSentEvents.Frame.split(buf)
      check_frame_size!(leftover, max_size)
      resp = put_in(resp.private[:sse_buf], leftover)

      Enum.reduce_while(frames, {:cont, {req, resp}}, &reduce_frame(&1, &2, user_fun))
    end

    %{req | into: wrapped}
  end

  defp reduce_frame(raw, {:cont, {req, resp}}, user_fun) do
    frame = ReqServerSentEvents.Frame.parse(raw)

    case user_fun.({:sse_event, frame}, {req, resp}) do
      {:cont, acc} -> {:cont, {:cont, acc}}
      {:halt, acc} -> {:halt, {:halt, acc}}
    end
  end

  # ---------------------------------------------------------------------------
  # into: :self — rewrite to into: fun that sends messages; register sse_done
  # ---------------------------------------------------------------------------

  defp wrap_self(%Req.Request{} = req) do
    caller = self()
    sse_ref = make_ref()
    max_size = req.private[:sse_max_frame_size]

    wrapped = fn {:data, chunk}, {req, resp} ->
      buf = (resp.private[:sse_buf] || "") <> chunk
      {frames, leftover} = ReqServerSentEvents.Frame.split(buf)
      check_frame_size!(leftover, max_size)
      resp = put_in(resp.private[:sse_buf], leftover)

      Enum.each(frames, fn raw ->
        send(caller, {sse_ref, {:sse_event, ReqServerSentEvents.Frame.parse(raw)}})
      end)

      {:cont, {req, resp}}
    end

    req
    |> Req.Request.put_private(:sse_ref, sse_ref)
    |> Req.Request.put_private(:sse_caller, caller)
    |> then(&%{&1 | into: wrapped})
    |> Req.Request.append_response_steps(sse_done: &send_sse_done/1)
  end

  # ---------------------------------------------------------------------------
  # into: collectable — wrap in CollectableWrapper
  # ---------------------------------------------------------------------------

  defp wrap_collectable(%Req.Request{} = req, collectable) do
    wrapper = %ReqServerSentEvents.CollectableWrapper{
      inner: collectable,
      max_size: req.private[:sse_max_frame_size]
    }

    %{req | into: wrapper}
  end

  @doc false
  def check_frame_size!(_leftover, nil), do: :ok

  def check_frame_size!(leftover, max_size) when is_integer(max_size) do
    size = byte_size(leftover)

    if size > max_size do
      raise ReqServerSentEvents.FrameTooLargeError, size: size, limit: max_size
    end

    :ok
  end
end
