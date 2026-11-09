// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVContinuity
import XCTest

@testable import iCube

final class EmulationServerLibraryTests: XCTestCase {
  func testCatalogFollowsCursorAndFiltersToDolphinSystems() async throws {
    let transport = FixtureTransport()
    let server = try EmulationServer(address: "Example.local")
    let library = EmulationServerLibrary(server: server, token: "test-token", transport: transport)
    let entries = try await library.catalog()
    XCTAssertEqual(entries.map(\.key), ["item:gc1", "source:wii1"])
    XCTAssertEqual(entries.map(\.game.platform), ["gc", "wii"])
    XCTAssertEqual(entries.first?.hasArtwork, true)
    XCTAssertEqual(entries.last?.sizeBytes, 1234)
    let requests = await transport.requests
    XCTAssertNil(requests.first?.headers["Authorization"])
    XCTAssertTrue(requests.dropFirst().allSatisfy { $0.headers["Authorization"] == "Bearer test-token" })
    XCTAssertTrue(requests.allSatisfy { $0.url.host == "example.local" && $0.url.port == 8473 })
    let query = requests.last.flatMap { URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems }
    XCTAssertEqual(query?.first(where: { $0.name == "libraryId" })?.value, "lib1")
    XCTAssertEqual(query?.first(where: { $0.name == "cursor" })?.value, "opaque+cursor/=")
    XCTAssertTrue(requests.last?.url.absoluteString.contains("cursor=opaque%2B") == true)
  }

  func testBonjourAdvertUsesResolvedHostPortAndTLS() throws {
    let id = UUID()
    let txt = ["id": id.uuidString, "v": "1", "tls": "1", "pair": "0", "name": "Living Room"]
      .mapValues { Data($0.utf8) }
    let advert = try XCTUnwrap(EmulationServerAdvertisement(host: "media.local.", port: 8443, txt: txt))
    XCTAssertEqual(advert.id, id)
    XCTAssertEqual(advert.name, "Living Room")
    XCTAssertEqual(advert.server.origin.absoluteString, "https://media.local:8443")

    var unsupported = txt
    unsupported["v"] = Data("2".utf8)
    XCTAssertNil(EmulationServerAdvertisement(host: "media.local.", port: 8443, txt: unsupported))
    XCTAssertNil(EmulationServerAdvertisement(host: "media.local.", port: 0, txt: txt))
  }

  func testServerAddressRejectsCredentialsAndNonOriginPaths() throws {
    for address in ["file:///tmp/games", "http://user:password@server", "https://server/api/v1", "https://server?token=test"] {
      XCTAssertThrowsError(try EmulationServer(address: address))
    }
    XCTAssertEqual(try EmulationServer(address: "https://SERVER:443/").origin.absoluteString, "https://server")
  }
}

private actor FixtureTransport: ContinuityTransport {
  private(set) var requests: [ContinuityRequest] = []

  func request(_ request: ContinuityRequest) async throws -> ContinuityResponse {
    requests.append(request)
    let body: String
    switch request.url.path {
    case "/api/v1/capabilities":
      body = #"{"protocol":{"major":1}}"#
    case "/api/v1/browse-libraries":
      body = #"{"items":[{"id":"lib1"}],"nextCursor":null}"#
    case "/api/v1/browse" where URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "cursor" }) == true:
      body = """
      {"items":[
        {"entityType":"source","source":{"id":"wii1","name":"Wii.rvz","title":"Wii title","systemId":"com.provenance.wii","size":1234,"availability":"online"}},
        {"entityType":"source","source":{"id":"offline","name":"Gone.iso","systemId":"com.provenance.wii","size":1234,"availability":"offline"}}
      ],"nextCursor":null}
      """
    case "/api/v1/browse":
      body = """
      {"items":[
        {"entityType":"item","item":{"id":"gc1","title":"GameCube title","systemIdentifier":"com.provenance.gamecube"},"previewAsset":{"id":"art1"}},
        {"entityType":"item","item":{"id":"jag1","title":"Jaguar title","systemIdentifier":"com.provenance.jaguar"}}
      ],"nextCursor":"opaque+cursor/="}
      """
    default:
      throw URLError(.unsupportedURL)
    }
    return ContinuityResponse(status: 200, body: Data(body.utf8))
  }

  func download(_ request: ContinuityRequest, to destination: URL, resumeOffset: Int64,
                progress: (@Sendable (Int64, Int64?) -> Void)?) async throws -> Int64 {
    throw URLError(.unsupportedURL)
  }
}
