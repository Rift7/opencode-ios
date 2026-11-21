import Foundation
import OpenCodeServer
import Testing

@Suite("SSE parser")
struct SSEParserTests {
  @Test("a frame split at every byte still dispatches once")
  func fragmentedFrame() throws {
    let bytes = Data("data: {\"type\":\"server.connected\"}\n\n".utf8)
    var parser = SSEParser()
    var frames: [SSEFrame] = []
    for byte in bytes {
      frames += try parser.feed(Data([byte]))
    }
    #expect(frames == [SSEFrame(data: #"{"type":"server.connected"}"#)])
  }

  @Test("several frames in one chunk are all dispatched")
  func multipleFrames() throws {
    var parser = SSEParser()
    let frames = try parser.feed(
      Data("data: one\n\ndata: two\n\n: heartbeat\n\ndata: three\n\n".utf8)
    )
    #expect(frames.map(\.data) == ["one", "two", "three"])
    #expect(parser.lineCount == 8)
  }

  @Test("CRLF and a bare CR both end a line")
  func lineEndings() throws {
    var parser = SSEParser()
    #expect(try parser.feed(Data("data: one\r\n\r\n".utf8)) == [SSEFrame(data: "one")])
    #expect(try parser.feed(Data("data: two\r\r".utf8)) == [SSEFrame(data: "two")])
    // A CRLF split across chunks is one line ending, not an empty line.
    #expect(try parser.feed(Data("data: three\r".utf8)).isEmpty)
    #expect(try parser.feed(Data("\n\r\n".utf8)) == [SSEFrame(data: "three")])
  }

  @Test("multi-line data joins with a newline and event/id are kept")
  func multiLineData() throws {
    var parser = SSEParser()
    let frames = try parser.feed(Data("event: session.renamed\nid: 7\ndata: {\"a\":\ndata: 1}\n\n".utf8))
    #expect(frames == [SSEFrame(event: "session.renamed", id: "7", data: "{\"a\":\n1}")])
  }

  @Test("an unknown field is ignored and a value may omit its colon")
  func unknownFields() throws {
    var parser = SSEParser()
    let frames = try parser.feed(Data("retry: 500\nfoo\ndata:value\n\n".utf8))
    #expect(frames == [SSEFrame(data: "value")])
  }

  @Test("a blank line without data dispatches nothing")
  func blankLines() throws {
    var parser = SSEParser()
    #expect(try parser.feed(Data("\n\n\ndata: only\n\n".utf8)) == [SSEFrame(data: "only")])
  }

  @Test("an unterminated final frame is flushed at end of input")
  func finishFlushes() throws {
    var parser = SSEParser()
    #expect(try parser.feed(Data("data: last".utf8)).isEmpty)
    #expect(try parser.finish() == [SSEFrame(data: "last")])
  }

  @Test("a frame past the size bound fails the connection")
  func oversizedFrame() {
    var parser = SSEParser(maximumFrameBytes: 8)
    #expect(throws: SSEError.frameTooLarge) {
      _ = try parser.feed(Data("data: 0123456789\n\n".utf8))
    }
  }

  @Test("invalid UTF-8 is replaced, never a crash")
  func invalidUTF8() throws {
    var parser = SSEParser()
    let frames = try parser.feed(Data([0x64, 0x61, 0x74, 0x61, 0x3A, 0x20, 0xFF, 0x0A, 0x0A]))
    #expect(frames.count == 1)
    #expect(frames[0].data.contains("\u{FFFD}"))
  }

  @Test("a heartbeat comment does not dispatch")
  func heartbeat() throws {
    var parser = SSEParser()
    #expect(try parser.feed(Data(": heartbeat\n\n".utf8)).isEmpty)
  }
}
