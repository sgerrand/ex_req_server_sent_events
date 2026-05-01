defmodule ReqServerSentEvents.Frame do
  @moduledoc """
  Pure SSE frame parser. No IO, no processes, no external dependencies.

  An SSE frame is a sequence of `field: value` lines terminated by a blank line (`\\n\\n`).
  Recognised fields: `event`, `data`, `id`, `retry`. Lines starting with `:` are comments.
  Multiple `data:` lines within one frame are concatenated with `"\\n"`.
  """

  defstruct event: nil, data: nil, id: nil, retry: nil, comments: []

  @type t :: %__MODULE__{
          event: String.t() | nil,
          data: String.t() | nil,
          id: String.t() | nil,
          retry: non_neg_integer() | nil,
          comments: [String.t()]
        }

  @doc """
  Split a byte buffer on the SSE frame delimiter (`"\\n\\n"`).

  Returns `{complete_frames, leftover}` where `complete_frames` is a list of raw
  frame strings (without the trailing `"\\n\\n"`) and `leftover` is the remaining
  bytes that have not yet formed a complete frame.

  ## Examples

      iex> ReqServerSentEvents.Frame.split("data: hello\\n\\n")
      {["data: hello"], ""}

      iex> ReqServerSentEvents.Frame.split("data: partial")
      {[], "data: partial"}
  """
  @spec split(binary()) :: {[binary()], binary()}
  def split(buffer) when is_binary(buffer) do
    buffer = String.replace(buffer, "\r\n", "\n")
    parts = :binary.split(buffer, "\n\n", [:global])
    {complete, [leftover]} = Enum.split(parts, -1)
    {Enum.reject(complete, &(&1 == "")), leftover}
  end

  @doc """
  Parse one complete raw frame string (without the trailing `"\\n\\n"`) into a `%Frame{}`.

  Frames with no `data:` field are returned as-is — the caller decides whether to
  dispatch or discard them. Unknown field names are silently ignored per the SSE spec.

  ## Examples

      iex> ReqServerSentEvents.Frame.parse("event: ping\\ndata: {}")
      %ReqServerSentEvents.Frame{event: "ping", data: "{}"}

      iex> ReqServerSentEvents.Frame.parse(": keepalive")
      %ReqServerSentEvents.Frame{comments: ["keepalive"]}
  """
  @spec parse(binary()) :: t()
  def parse(raw) when is_binary(raw) do
    # The \r\n normalisation is intentional: split/1 already normalises when
    # frames arrive through the plugin, but parse/1 is public and may be called
    # directly with CRLF content.
    frame =
      raw
      |> String.replace("\r\n", "\n")
      |> String.split("\n", trim: true)
      |> Enum.reduce(%__MODULE__{}, &parse_line/2)

    %{frame | comments: Enum.reverse(frame.comments)}
  end

  # Comment line — everything after the leading ":"
  defp parse_line(":" <> rest, frame) do
    comment = String.replace_prefix(rest, " ", "")
    %{frame | comments: [comment | frame.comments]}
  end

  defp parse_line(line, frame) do
    {field, value} =
      case :binary.split(line, ":") do
        [k, v] -> {k, String.replace_prefix(v, " ", "")}
        [k] -> {k, ""}
      end

    apply_field(frame, field, value)
  end

  defp apply_field(frame, "event", value), do: %{frame | event: value}
  defp apply_field(frame, "id", value), do: %{frame | id: value}

  defp apply_field(frame, "data", value) do
    case frame.data do
      nil -> %{frame | data: value}
      existing -> %{frame | data: existing <> "\n" <> value}
    end
  end

  defp apply_field(frame, "retry", value) do
    case Integer.parse(value) do
      {ms, ""} -> %{frame | retry: ms}
      _ -> frame
    end
  end

  # Unknown fields silently ignored per spec
  defp apply_field(frame, _field, _value), do: frame
end
