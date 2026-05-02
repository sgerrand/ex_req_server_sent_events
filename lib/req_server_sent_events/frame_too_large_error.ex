defmodule ReqServerSentEvents.FrameTooLargeError do
  @moduledoc """
  Raised when the SSE byte buffer grows past the configured `:max_frame_size`
  without encountering a frame delimiter (`"\\n\\n"`).
  """

  defexception [:size, :limit]

  @type t :: %__MODULE__{size: non_neg_integer(), limit: pos_integer()}

  @impl true
  def message(%__MODULE__{size: size, limit: limit}) do
    "SSE frame buffer #{size} bytes exceeds :max_frame_size of #{limit} bytes"
  end
end
