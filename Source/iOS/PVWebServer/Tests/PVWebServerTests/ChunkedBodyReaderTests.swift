import XCTest
@testable import PVWebServer

final class ChunkedBodyReaderTests: XCTestCase {
    private typealias Event = ROMUploadServer.ChunkedBodyReader.Event

    private func payloads(_ events: [Event]) -> Data {
        var out = Data()
        for e in events { if case .payload(let d) = e { out.append(d) } }
        return out
    }

    private func isComplete(_ events: [Event]) -> Bool {
        events.contains { if case .complete = $0 { return true } else { return false } }
    }

    func testSingleChunk() {
        let reader = ROMUploadServer.ChunkedBodyReader()
        let events = reader.feed(Data("5\r\nhello\r\n0\r\n\r\n".utf8))
        XCTAssertEqual(payloads(events), Data("hello".utf8))
        XCTAssertTrue(isComplete(events))
    }

    func testMultipleChunks() {
        let reader = ROMUploadServer.ChunkedBodyReader()
        let events = reader.feed(Data("3\r\nabc\r\n3\r\ndef\r\n0\r\n\r\n".utf8))
        XCTAssertEqual(payloads(events), Data("abcdef".utf8))
        XCTAssertTrue(isComplete(events))
    }

    func testChunkSplitAcrossFeeds() {
        let reader = ROMUploadServer.ChunkedBodyReader()
        var got = Data()
        got.append(payloads(reader.feed(Data("5\r\nhe".utf8))))
        got.append(payloads(reader.feed(Data("llo\r\n0\r\n\r\n".utf8))))
        XCTAssertEqual(got, Data("hello".utf8))
    }

    func testHexSizeAndTrailing() {
        let body = String(repeating: "z", count: 26)
        let reader = ROMUploadServer.ChunkedBodyReader()
        let events = reader.feed(Data("1a\r\n\(body)\r\n0\r\n\r\nNEXT".utf8))
        XCTAssertEqual(payloads(events), Data(body.utf8))
        var trailing = Data()
        for e in events { if case .complete(let t) = e { trailing = t } }
        XCTAssertEqual(trailing, Data("NEXT".utf8))
    }

    func testInvalidSizeEmitsInvalid() {
        let reader = ROMUploadServer.ChunkedBodyReader()
        let events = reader.feed(Data("XYZ\r\n".utf8))
        XCTAssertTrue(events.contains { if case .invalid = $0 { return true } else { return false } })
    }
}
