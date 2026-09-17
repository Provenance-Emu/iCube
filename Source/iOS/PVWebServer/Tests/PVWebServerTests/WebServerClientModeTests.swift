import XCTest
@testable import PVWebServer

final class WebServerClientModeTests: XCTestCase {
    private func req(_ line: String, _ headers: [String: String] = [:]) -> HTTPRequest {
        var text = line + " HTTP/1.1"
        for (k, v) in headers { text += "\r\n\(k): \(v)" }
        return HTTPRequest.parse(text)!
    }

    private func resolve(_ r: HTTPRequest, stored: WebServerClientMode = .unknown) -> WebServerClientMode {
        WebServerClientMode.resolve(r, stored: stored)
    }

    func testUploadUIRoutesAreBrowserRegardlessOfUserAgent() {
        let dav = ["User-Agent": "WebDAVFS/3.0.0 (03008000) Darwin/24.0.0"]
        XCTAssertEqual(resolve(req("PUT /files/a.iso", dav)), .browser)
        XCTAssertEqual(resolve(req("POST /upload", dav)), .browser)
        XCTAssertEqual(resolve(req("POST /move", dav)), .browser)
        XCTAssertEqual(resolve(req("POST /mkdir", dav)), .browser)
        XCTAssertEqual(resolve(req("GET /files/a.iso", dav)), .browser)
        XCTAssertEqual(resolve(req("DELETE /files/a.iso", dav)), .browser)
        XCTAssertEqual(resolve(req("GET /api/health", dav)), .browser)
    }

    func testWebDAVOnlyMethodsAreWebDAV() {
        for m in ["PROPFIND", "PROPPATCH", "MKCOL", "MOVE", "COPY", "LOCK", "UNLOCK"] {
            XCTAssertEqual(resolve(req("\(m) /x", ["User-Agent": "Mozilla/5.0"])), .webDAV, m)
        }
        XCTAssertEqual(resolve(req("PUT /Games/a.iso")), .webDAV)
    }

    func testStoredModeIsSticky() {
        // A headerless GET on a connection already classified as WebDAV stays WebDAV.
        XCTAssertEqual(resolve(req("GET /Games/a.iso"), stored: .webDAV), .webDAV)
        XCTAssertEqual(resolve(req("GET /"), stored: .webDAV), .webDAV)
        // And a browser connection stays browser for a bare OPTIONS.
        XCTAssertEqual(resolve(req("OPTIONS /"), stored: .browser), .browser)
    }

    func testWebDAVSignalHeaders() {
        XCTAssertEqual(resolve(req("GET /", ["Depth": "1"])), .webDAV)
        XCTAssertEqual(resolve(req("OPTIONS /", ["Translate": "f", "User-Agent": "Mozilla/5.0"])), .webDAV)
        XCTAssertEqual(resolve(req("GET /", ["Destination": "/y"])), .webDAV)
        XCTAssertEqual(resolve(req("GET /", ["Lock-Token": "<x>"])), .webDAV)
        XCTAssertEqual(resolve(req("GET /", ["Overwrite": "T"])), .webDAV)
        XCTAssertEqual(resolve(req("GET /", ["If": "(<opaquelocktoken:abc>)"])), .webDAV)
    }

    func testUserAgentLists() {
        XCTAssertEqual(resolve(req("GET /", ["User-Agent": "rclone/v1.66"])), .webDAV)
        XCTAssertEqual(resolve(req("GET /", ["User-Agent": "Cyberduck/9.0"])), .webDAV)
        XCTAssertEqual(resolve(req("GET /", ["User-Agent": "Microsoft-WebDAV-MiniRedir/10.0"])), .webDAV)
        XCTAssertEqual(resolve(req("GET /", ["User-Agent": "Mozilla/5.0 (iPhone) AppleWebKit/605"])), .browser)
        XCTAssertEqual(resolve(req("GET /", ["User-Agent": "Opera/9.80"])), .browser)
    }

    func testMethodHeuristicForHeaderlessClients() {
        XCTAssertEqual(resolve(req("OPTIONS /")), .webDAV)
        XCTAssertEqual(resolve(req("GET /Games/a.iso")), .webDAV)
        XCTAssertEqual(resolve(req("HEAD /Games/a.iso")), .webDAV)
        XCTAssertEqual(resolve(req("DELETE /Games/a.iso")), .webDAV)
        XCTAssertEqual(resolve(req("GET /")), .browser)
        XCTAssertEqual(resolve(req("GET /?path=Wii")), .browser)
        XCTAssertEqual(resolve(req("POST /something")), .browser)
    }
}
