defmodule ReqServerSentEvents.Internal do
  @moduledoc false

  alias ReqServerSentEvents.{Frame, FrameTooLargeError}

  @spec decode_chunk(binary(), binary(), pos_integer() | nil) :: {[Frame.t()], binary()}
  def decode_chunk(buf, chunk, max_size) do
    {raw_frames, leftover} = Frame.split(buf <> chunk)
    check_frame_size!(leftover, max_size)

    frames =
      Enum.map(raw_frames, fn raw ->
        frame = Frame.parse(raw)
        emit_decoded(raw, frame)
        frame
      end)

    {frames, leftover}
  end

  defp emit_decoded(raw, frame) do
    :telemetry.execute(
      [:req_server_sent_events, :frame, :decoded],
      %{bytes: byte_size(raw)},
      %{frame: frame}
    )
  end

  defp check_frame_size!(_leftover, nil), do: :ok

  defp check_frame_size!(leftover, max_size) when is_integer(max_size) do
    size = byte_size(leftover)

    if size > max_size do
      raise FrameTooLargeError, size: size, limit: max_size
    end

    :ok
  end
end
