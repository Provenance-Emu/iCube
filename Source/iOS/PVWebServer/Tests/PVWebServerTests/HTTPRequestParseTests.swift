import XCTest
@testable import PVWebServer

final class HTTPRequestParseTests: XCTestCase {
    func testParsesRequestLine() {
        let req = HTTPRequest.parse("GET /files/Super%20Mario.rvz?foo=bar HTTP/1.1\r\nHost: x")
        XCTAssertEqual(req?.method, "GET")
        XCTAssertEqual(req?.path, "/files/Super%20Mario.rvz")
        XCTAssertEqual(req?.queryString, "foo=bar")
        XCTAssertEqual(req?.httpVersion, "HTTP/1.1")
    }

    func testMethodUppercasedAndHeadersLowercased() {
        let req = HTTPRequest.parse("propfind / HTTP/1.1\r\nDepth: 1\r\nContent-Length: 42")
        XCTAssertEqual(req?.method, "PROPFIND")
        XCTAssertEqual(req?.headers["depth"], "1")
        XCTAssertEqual(req?.contentLength, 42)
    }

    func testMissingVersionDefaultsTo11() {
        let req = HTTPRequest.parse("OPTIONS *")
        XCTAssertEqual(req?.method, "OPTIONS")
        XCTAssertEqual(req?.httpVersion, "HTTP/1.1")
    }

    func testMalformedRequestLineReturnsNil() {
        XCTAssertNil(HTTPRequest.parse("GET"))
        XCTAssertNil(HTTPRequest.parse(""))
    }

    func testChunkedAndExpectContinue() {
        let req = HTTPRequest.parse("PUT /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\nExpect: 100-continue")
        XCTAssertTrue(req?.isChunked == true)
        XCTAssertTrue(req?.expectsContinue == true)
    }

    func testWantsKeepAlive() {
        XCTAssertTrue(HTTPRequest.parse("GET / HTTP/1.1\r\nHost: x")?.wantsKeepAlive == true)
        XCTAssertFalse(HTTPRequest.parse("GET / HTTP/1.1\r\nConnection: close")?.wantsKeepAlive == true)
        XCTAssertFalse(HTTPRequest.parse("GET / HTTP/1.0\r\nHost: x")?.wantsKeepAlive == true)
        XCTAssertTrue(HTTPRequest.parse("GET / HTTP/1.0\r\nConnection: keep-alive")?.wantsKeepAlive == true)
    }

    func testMultipartBoundary() {
        let req = HTTPRequest.parse("POST /upload HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=\"AaB03x\"")
        XCTAssertEqual(req?.multipartBoundary, "AaB03x")
        XCTAssertNil(HTTPRequest.parse("POST /x HTTP/1.1\r\nContent-Type: application/json")?.multipartBoundary)
    }

    /// A negative `Content-Length` used to reach `Data.dropFirst(negative)`, which traps.
    /// Any LAN client could crash the app with one request line.
    func testNegativeContentLengthClampsToZero() {
        let req = HTTPRequest.parse("POST /upload HTTP/1.1\r\nContent-Length: -99999")
        XCTAssertEqual(req?.contentLength, 0)
    }

    func testGarbageContentLengthIsZero() {
        XCTAssertEqual(HTTPRequest.parse("POST /x HTTP/1.1\r\nContent-Length: banana")?.contentLength, 0)
    }

    func testQueryParametersPercentDecoded() {
        let req = HTTPRequest.parse("GET /?path=Wii%2FGames&flag HTTP/1.1")
        XCTAssertEqual(req?.queryParameters["path"], "Wii/Games")
        XCTAssertEqual(req?.queryParameters["flag"], "")
    }
}
