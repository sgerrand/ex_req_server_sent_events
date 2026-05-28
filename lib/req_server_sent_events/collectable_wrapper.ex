defmodule ReqServerSentEvents.CollectableWrapper do
  @moduledoc """
  Wraps any `Collectable` so that raw SSE byte chunks are decoded into
  `%ReqServerSentEvents.Frame{}` structs before being collected.

  The byte buffer is carried in the accumulator alongside the inner
  collectable's own accumulator, so no process state is required.
  Partial frames at end-of-stream are discarded — a frame is only
  emitted once terminated by `"\\n\\n"`.
  """

  defstruct [:inner, :max_size]

  defimpl Collectable do
    def into(%ReqServerSentEvents.CollectableWrapper{inner: inner, max_size: max_size}) do
      {inner_acc, inner_collector} = Collectable.into(inner)

      collector = fn
        {buf, iacc}, {:cont, chunk} ->
          {frames, leftover} = ReqServerSentEvents.Internal.decode_chunk(buf, chunk, max_size)
          new_iacc = Enum.reduce(frames, iacc, &inner_collector.(&2, {:cont, &1}))
          {leftover, new_iacc}

        {_buf, iacc}, :done ->
          inner_collector.(iacc, :done)

        {_buf, iacc}, :halt ->
          inner_collector.(iacc, :halt)
      end

      {{"", inner_acc}, collector}
    end
  end
end
