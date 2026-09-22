// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import PVWebServer

final class WebRouteTableTests: XCTestCase {

    private func okHandler(_ marker: String) -> WebRouteHandler {
        { _ in WebRouteResponse(status: 200, contentType: "text/plain", body: .data(Data(marker.utf8))) }
    }

    private func marker(of response: WebRouteResponse) -> String? {
        guard case .data(let data) = response.body else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Matching

    func testExactMatchDispatchesToTheRegisteredHandler() async {
        var table = WebRouteTable()
        table.register(method: "GET", path: "/api/continuity/manifest", handler: okHandler("manifest"))

        let handler = table.handler(forMethod: "GET", path: "/api/continuity/manifest")
        XCTAssertNotNil(handler)
        let response = await handler!(WebRouteRequest(method: "GET", path: "/api/continuity/manifest"))
        XCTAssertEqual(marker(of: response), "manifest")
    }

    func testMethodIsMatchedCaseInsensitively() {
        var table = WebRouteTable()
        table.register(method: "post", path: "/api/x", handler: okHandler("x"))
        XCTAssertNotNil(table.handler(forMethod: "POST", path: "/api/x"))
        XCTAssertNotNil(table.handler(forMethod: "PoSt", path: "/api/x"))
    }

    func testWrongMethodDoesNotMatch() {
        var table = WebRouteTable()
        table.register(method: "GET", path: "/api/x", handler: okHandler("x"))
        XCTAssertNil(table.handler(forMethod: "POST", path: "/api/x"))
    }

    func testPathIsCaseSensitive() {
        var table = WebRouteTable()
        table.register(method: "GET", path: "/api/Continuity", handler: okHandler("x"))
        XCTAssertNil(table.handler(forMethod: "GET", path: "/api/continuity"))
    }

    func testTrailingSlashIsIgnoredOnBothSides() {
        var table = WebRouteTable()
        table.register(method: "GET", path: "/api/x/", handler: okHandler("x"))
        XCTAssertNotNil(table.handler(forMethod: "GET", path: "/api/x"))
        XCTAssertNotNil(table.handler(forMethod: "GET", path: "/api/x/"))
    }

    func testMissingLeadingSlashIsNormalized() {
        var table = WebRouteTable()
        table.register(method: "GET", path: "api/x", handler: okHandler("x"))
        XCTAssertNotNil(table.handler(forMethod: "GET", path: "/api/x"))
    }

    func testUnregisteredPathReturnsNil() {
        var table = WebRouteTable()
        table.register(method: "GET", path: "/api/x", handler: okHandler("x"))
        XCTAssertNil(table.handler(forMethod: "GET", path: "/api/y"))
    }

    func testPrefixDoesNotMatch() {
        // No wildcards: /api/x must not swallow /api/xyz or /api/x/child.
        var table = WebRouteTable()
        table.register(method: "GET", path: "/api/x", handler: okHandler("x"))
        XCTAssertNil(table.handler(forMethod: "GET", path: "/api/xyz"))
        XCTAssertNil(table.handler(forMethod: "GET", path: "/api/x/child"))
    }

    // MARK: - First registration wins

    func testDuplicateRegistrationIsRejectedAndOriginalHandlerSurvives() async {
        var table = WebRouteTable()
        XCTAssertTrue(table.register(method: "GET", path: "/api/x", handler: okHandler("first")))
        XCTAssertFalse(table.register(method: "GET", path: "/api/x", handler: okHandler("second")))
        XCTAssertEqual(table.count, 1)

        let response = await table.handler(forMethod: "GET", path: "/api/x")!(
            WebRouteRequest(method: "GET", path: "/api/x")
        )
        XCTAssertEqual(marker(of: response), "first")
    }

    func testDuplicateDetectionNormalizesBeforeComparing() {
        var table = WebRouteTable()
        XCTAssertTrue(table.register(method: "GET", path: "/api/x", handler: okHandler("a")))
        XCTAssertFalse(table.register(method: "get", path: "api/x/", handler: okHandler("b")))
        XCTAssertEqual(table.count, 1)
    }

    func testSamePathDifferentMethodsCoexist() {
        var table = WebRouteTable()
        XCTAssertTrue(table.register(method: "GET", path: "/api/x", handler: okHandler("get")))
        XCTAssertTrue(table.register(method: "POST", path: "/api/x", handler: okHandler("post")))
        XCTAssertEqual(table.count, 2)
        XCTAssertTrue(table.hasPath("/api/x"))
    }

    func testHasPathIsMethodAgnostic() {
        var table = WebRouteTable()
        table.register(method: "POST", path: "/api/x", handler: okHandler("post"))
        XCTAssertTrue(table.hasPath("/api/x"))
        XCTAssertTrue(table.hasPath("/api/x/"))
        XCTAssertFalse(table.hasPath("/api/y"))
    }

    // MARK: - Normalization

    func testNormalizeCollapsesOnlyTrailingSlashes() {
        XCTAssertEqual(WebRouteTable.normalize(path: "/a/b"), "/a/b")
        XCTAssertEqual(WebRouteTable.normalize(path: "/a/b/"), "/a/b")
        XCTAssertEqual(WebRouteTable.normalize(path: "/a/b///"), "/a/b")
        XCTAssertEqual(WebRouteTable.normalize(path: "a/b"), "/a/b")
        // The root path keeps its single slash rather than normalizing to "".
        XCTAssertEqual(WebRouteTable.normalize(path: "/"), "/")
        XCTAssertEqual(WebRouteTable.normalize(path: ""), "/")
    }

    // MARK: - Request header lookup

    func testHeaderLookupIsCaseInsensitive() {
        // The server's parser lower-cases header names; handlers written against
        // the HTTP spelling must still find them.
        let request = WebRouteRequest(
            method: "GET", path: "/api/x",
            headers: ["authorization": "Bearer abc", "range": "bytes=0-"]
        )
        XCTAssertEqual(request.header("Authorization"), "Bearer abc")
        XCTAssertEqual(request.header("authorization"), "Bearer abc")
        XCTAssertEqual(request.header("RANGE"), "bytes=0-")
        XCTAssertNil(request.header("X-Absent"))
    }

    // MARK: - Response shapes

    func testErrorResponseCarriesAParsableJSONBody() throws {
        let response = WebRouteResponse.error(status: 401, message: "nope")
        XCTAssertEqual(response.status, 401)
        XCTAssertEqual(response.contentType, "application/json")
        guard case .data(let data) = response.body else { return XCTFail("expected a data body") }
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(parsed["error"], "nope")
    }

    func testReasonPhrasesCoverTheCodesContinuityEmits() {
        XCTAssertEqual(WebRouteResponse.reasonPhrase(for: 200), "OK")
        XCTAssertEqual(WebRouteResponse.reasonPhrase(for: 202), "Accepted")
        XCTAssertEqual(WebRouteResponse.reasonPhrase(for: 206), "Partial Content")
        XCTAssertEqual(WebRouteResponse.reasonPhrase(for: 401), "Unauthorized")
        XCTAssertEqual(WebRouteResponse.reasonPhrase(for: 410), "Gone")
        XCTAssertEqual(WebRouteResponse.reasonPhrase(for: 416), "Range Not Satisfiable")
        XCTAssertEqual(WebRouteResponse.reasonPhrase(for: 429), "Too Many Requests")
        // Unknown codes still produce a legal status line.
        XCTAssertEqual(WebRouteResponse.reasonPhrase(for: 418), "Error")
        XCTAssertEqual(WebRouteResponse.reasonPhrase(for: 207), "OK")
    }
}
