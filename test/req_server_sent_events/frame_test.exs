defmodule ReqServerSentEvents.FrameTest do
  use ExUnit.Case, async: true

  alias ReqServerSentEvents.Frame

  describe "split/1" do
    test "empty buffer" do
      assert Frame.split("") == {[], ""}
    end

    test "no delimiter — everything is leftover" do
      assert Frame.split("data: partial") == {[], "data: partial"}
    end

    test "single complete frame" do
      assert Frame.split("data: hello\n\n") == {["data: hello"], ""}
    end

    test "single complete frame with leftover" do
      assert Frame.split("data: hello\n\ndata: part") == {["data: hello"], "data: part"}
    end

    test "multiple complete frames" do
      input = "data: one\n\ndata: two\n\ndata: three\n\n"
      assert Frame.split(input) == {["data: one", "data: two", "data: three"], ""}
    end

    test "multiple complete frames with leftover" do
      input = "data: one\n\ndata: two\n\nincomplete"
      assert Frame.split(input) == {["data: one", "data: two"], "incomplete"}
    end

    test "frame split across two chunks" do
      chunk1 = "data: hel"
      chunk2 = "lo\n\n"
      {frames1, leftover} = Frame.split(chunk1)
      assert frames1 == []
      {frames2, _} = Frame.split(leftover <> chunk2)
      assert frames2 == ["data: hello"]
    end

    test "consecutive delimiters produce no empty frames" do
      assert Frame.split("data: a\n\n\n\ndata: b\n\n") == {["data: a", "data: b"], ""}
    end

    test "CRLF frame delimiter" do
      assert Frame.split("data: hello\r\n\r\n") == {["data: hello"], ""}
    end

    test "CRLF frame delimiter with leftover" do
      assert Frame.split("data: hello\r\n\r\ndata: part") == {["data: hello"], "data: part"}
    end

    test "CRLF line endings within frame normalised before split" do
      input = "data: one\r\n\r\ndata: two\r\n\r\n"
      assert Frame.split(input) == {["data: one", "data: two"], ""}
    end

    test "CRLF split across chunks handled correctly" do
      chunk1 = "data: hel"
      chunk2 = "lo\r\n\r\n"
      {frames1, leftover} = Frame.split(chunk1)
      assert frames1 == []
      {frames2, _} = Frame.split(leftover <> chunk2)
      assert frames2 == ["data: hello"]
    end

    test "leading UTF-8 BOM stripped from buffer" do
      bom = <<0xEF, 0xBB, 0xBF>>
      assert Frame.split(bom <> "data: hello\n\n") == {["data: hello"], ""}
    end

    test "leading UTF-8 BOM only stripped from very start of buffer" do
      bom = <<0xEF, 0xBB, 0xBF>>
      input = "data: hello\n\n" <> bom <> "data: world\n\n"
      {frames, _} = Frame.split(input)
      assert ["data: hello", _bom_prefixed] = frames
    end
  end

  describe "parse/1" do
    test "data field" do
      assert Frame.parse("data: hello world") == %Frame{data: "hello world"}
    end

    test "event field" do
      assert Frame.parse("event: message") == %Frame{event: "message"}
    end

    test "id field" do
      assert Frame.parse("id: 42") == %Frame{id: "42"}
    end

    test "retry field with valid integer" do
      assert Frame.parse("retry: 3000") == %Frame{retry: 3000}
    end

    test "retry field with non-integer value is ignored" do
      assert Frame.parse("retry: 5000ms") == %Frame{}
      assert Frame.parse("retry: abc") == %Frame{}
      assert Frame.parse("retry: 1.5") == %Frame{}
    end

    test "retry field with negative value is ignored" do
      assert Frame.parse("retry: -1") == %Frame{}
      assert Frame.parse("retry: -1000") == %Frame{}
    end

    test "id field containing NUL byte is ignored" do
      assert Frame.parse("id: ok") == %Frame{id: "ok"}
      assert Frame.parse("id: bad" <> <<0>> <> "value") == %Frame{}
    end

    test "comment line" do
      assert Frame.parse(": keepalive") == %Frame{comments: ["keepalive"]}
    end

    test "comment line with leading space stripped" do
      assert Frame.parse(":  note") == %Frame{comments: [" note"]}
    end

    test "empty comment" do
      assert Frame.parse(":") == %Frame{comments: [""]}
    end

    test "multiple comment lines collected in order" do
      raw = ": first\n: second"
      assert Frame.parse(raw) == %Frame{comments: ["first", "second"]}
    end

    test "unknown fields are silently ignored" do
      assert Frame.parse("x-custom: value") == %Frame{}
    end

    test "value-less field syntax (no colon) treated as empty string value" do
      assert Frame.parse("data") == %Frame{data: ""}
    end

    test "multiple data lines concatenated with newline" do
      raw = "data: line one\ndata: line two\ndata: line three"

      assert Frame.parse(raw) == %Frame{data: "line one\nline two\nline three"}
    end

    test "all fields in one frame" do
      raw = "event: update\ndata: payload\nid: 99\nretry: 1000"

      assert Frame.parse(raw) == %Frame{
               event: "update",
               data: "payload",
               id: "99",
               retry: 1000
             }
    end

    test "all-nil frame for empty raw string" do
      assert Frame.parse("") == %Frame{}
    end

    test "frame with no data field returned as-is" do
      assert Frame.parse("event: ping\nid: 1") == %Frame{event: "ping", id: "1"}
    end

    test "exactly one leading space after colon is stripped from value" do
      assert Frame.parse("data: hello") == %Frame{data: "hello"}
      assert Frame.parse("data:hello") == %Frame{data: "hello"}
      assert Frame.parse("data:  hello") == %Frame{data: " hello"}
    end

    test "CRLF line endings in frame" do
      assert Frame.parse("event: ping\r\ndata: hello") == %Frame{event: "ping", data: "hello"}
    end

    test "CRLF frame with all fields" do
      raw = "event: update\r\ndata: payload\r\nid: 99\r\nretry: 1000"

      assert Frame.parse(raw) == %Frame{
               event: "update",
               data: "payload",
               id: "99",
               retry: 1000
             }
    end

    test "CRLF multiple comment lines preserved in order" do
      assert Frame.parse(": first\r\n: second") == %Frame{comments: ["first", "second"]}
    end

    test "bare CR line endings (SSE spec §9.2.4)" do
      assert Frame.parse("event: ping\rdata: hello") == %Frame{event: "ping", data: "hello"}
    end

    test "mixed line endings within a single frame" do
      raw = "event: update\r\ndata: payload\nid: 99\rretry: 1000"

      assert Frame.parse(raw) == %Frame{
               event: "update",
               data: "payload",
               id: "99",
               retry: 1000
             }
    end
  end
end
