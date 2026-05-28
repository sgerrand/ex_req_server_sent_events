defmodule SplitBench do
  # Regression guard for ReqServerSentEvents.Frame.split/1.
  #
  # OLD is the pre-spec-compliance implementation (single `\n\n` delimiter,
  # whole-buffer CRLF normalisation). PROD is the current implementation.
  # PROD should be within ~5% of OLD on CRLF input and at least as fast as
  # OLD everywhere else. If PROD regresses substantially, the fast-path
  # probe in split/1 has likely been removed or broken.

  def old_split(buffer) do
    buffer =
      buffer
      |> String.trim_leading(<<0xEF, 0xBB, 0xBF>>)
      |> String.replace("\r\n", "\n")

    parts = :binary.split(buffer, "\n\n", [:global])
    {complete, [leftover]} = Enum.split(parts, -1)
    {Enum.reject(complete, &(&1 == "")), leftover}
  end

  def stream_through(split_fn, chunks) do
    Enum.reduce(chunks, "", fn chunk, leftover ->
      {_frames, new_leftover} = split_fn.(leftover <> chunk)
      new_leftover
    end)
  end

  def chunk_binary(bin, size), do: chunk_binary(bin, size, [])
  defp chunk_binary("", _size, acc), do: Enum.reverse(acc)
  defp chunk_binary(bin, size, acc) when byte_size(bin) <= size, do: Enum.reverse([bin | acc])

  defp chunk_binary(bin, size, acc) do
    <<chunk::binary-size(size), rest::binary>> = bin
    chunk_binary(rest, size, [chunk | acc])
  end

  def measure(label, fun) do
    fun.()
    times = for _ <- 1..5, do: elem(:timer.tc(fun), 0)
    median = times |> Enum.sort() |> Enum.at(2)

    IO.puts(
      "  #{label}: #{format_us(median)}  (runs: #{Enum.map_join(times, ", ", &format_us/1)})"
    )

    median
  end

  defp format_us(us) when us >= 1_000_000, do: "#{Float.round(us / 1_000_000, 3)} s"
  defp format_us(us) when us >= 1_000, do: "#{Float.round(us / 1_000, 2)} ms"
  defp format_us(us), do: "#{us} μs"

  def run_scenario(label, frame_bytes, chunk_size, ending) do
    payload = String.duplicate("a", frame_bytes - byte_size("data: ") - byte_size(ending))
    full = "data: " <> payload <> ending
    chunks = chunk_binary(full, chunk_size)

    IO.puts("\n#{label}")

    IO.puts(
      "  frame=#{format_bytes(byte_size(full))}  chunks=#{length(chunks)}@#{chunk_size}B  ending=#{inspect(ending)}"
    )

    old = measure("OLD  ", fn -> stream_through(&old_split/1, chunks) end)
    prod = measure("PROD ", fn -> stream_through(&ReqServerSentEvents.Frame.split/1, chunks) end)
    IO.puts("  prod vs old: #{Float.round(old / prod, 2)}x")
  end

  defp format_bytes(b) when b >= 1_000_000, do: "#{Float.round(b / 1_000_000, 1)} MB"
  defp format_bytes(b) when b >= 1_000, do: "#{Float.round(b / 1_000, 1)} KB"
  defp format_bytes(b), do: "#{b} B"

  def main do
    IO.puts("Frame.split/1 regression bench — OLD vs PROD\n")

    run_scenario("1 MB frame / 8 KB chunks / LF", 1_000_000, 8_192, "\n\n")
    run_scenario("5 MB frame / 8 KB chunks / LF", 5_000_000, 8_192, "\n\n")
    run_scenario("10 MB frame / 8 KB chunks / LF", 10_000_000, 8_192, "\n\n")
    run_scenario("5 MB frame / 8 KB chunks / CRLF", 5_000_000, 8_192, "\r\n\r\n")
    run_scenario("1 MB frame / 1 KB chunks / LF", 1_000_000, 1_024, "\n\n")

    IO.puts("\nMany small frames (typical SSE workload)")
    one_frame = "event: ping\ndata: hello\n\n"
    big = String.duplicate(one_frame, 10_000)
    chunks = chunk_binary(big, 8_192)

    IO.puts(
      "  total=#{format_bytes(byte_size(big))}  frames=10000  chunks=#{length(chunks)}@8192B"
    )

    measure("OLD  ", fn -> stream_through(&old_split/1, chunks) end)
    measure("PROD ", fn -> stream_through(&ReqServerSentEvents.Frame.split/1, chunks) end)
  end
end

SplitBench.main()
