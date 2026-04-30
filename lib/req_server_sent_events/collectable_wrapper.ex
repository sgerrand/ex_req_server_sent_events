defmodule ReqServerSentEvents.CollectableWrapper do
  @moduledoc """
  Wraps any `Collectable` so that raw SSE byte chunks are decoded into
  `%ReqServerSentEvents.Frame{}` structs before being collected.

  The byte buffer is carried in the accumulator alongside the inner
  collectable's own accumulator, so no process state is required.
  Partial frames at end-of-stream are discarded — a frame is only
  emitted once terminated by `"\\n\\n"`.
  """

  defstruct [:inner]

  defimpl Collectable do
    def into(%ReqServerSentEvents.CollectableWrapper{inner: inner}) do
      {inner_acc, inner_collector} = Collectable.into(inner)

      collector = fn
        {buf, iacc}, {:cont, chunk} ->
          {frames, leftover} = ReqServerSentEvents.Frame.split(buf <> chunk)

          new_iacc =
            Enum.reduce(frames, iacc, fn raw, acc ->
              inner_collector.(acc, {:cont, ReqServerSentEvents.Frame.parse(raw)})
            end)

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
