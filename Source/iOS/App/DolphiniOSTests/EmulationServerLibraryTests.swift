// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import Foundation
import PVContinuity
import XCTest

@testable import iCube

final class EmulationServerLibraryTests: XCTestCase {
  func testCatalogFollowsCursorAndFiltersToDolphinSystems() async throws {
    let transport = FixtureTransport()
    let server = try EmulationServer(address: "Example.local")
    let library = EmulationServerLibrary(server: server, token: "test-token", transport: transport)
    let first = try await library.catalog(search: " Wii + GC ")
    XCTAssertEqual(first.entries.map(\.key), ["item:gc1"])
    let firstRequests = await transport.requests
    XCTAssertEqual(firstRequests.filter { $0.url.path == "/api/v1/browse" }.count, 1)
    let cursor = try XCTUnwrap(first.next)
    let second = try await library.catalogPage(after: cursor)
    XCTAssertNil(second.next)
    let entries = first.entries + second.entries
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
    for request in requests.filter({ $0.url.path == "/api/v1/browse" }) {
      let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems
      XCTAssertEqual(query?.first(where: { $0.name == "systemIds" })?.value, "com.provenance.gamecube,com.provenance.wii")
      XCTAssertEqual(query?.first(where: { $0.name == "search" })?.value, "Wii + GC")
    }
    XCTAssertTrue(requests.last?.url.absoluteString.contains("cursor=opaque%2B") == true)
  }

  func testFirstPageSkipsRowsThatCannotBePlayed() async throws {
    let transport = FixtureTransport(skipFirstGame: true)
    let server = try EmulationServer(address: "media.local")
    let library = EmulationServerLibrary(server: server, token: nil, transport: transport)
    let page = try await library.catalog()
    XCTAssertEqual(page.entries.map(\.key), ["source:wii1"])
    XCTAssertNil(page.next)
  }

  // Generated TEST01 GameCube headers, two 32 KiB discs and a text file.
  private static let archiveFixture = "N3q8ryccAATUZjpEEQEAAAAAAAAiAAAAAAAAADf0o37hABAAc10AKhFGrOZlh7L12hrO2arWVvG6q71uPWwtm2W1jjKSnDw/Qa6thy3nQTXdRkS+MxCugNNd7HARbuLuAPaOf1BcYGj8SJVOIOibzjE1Rkz1HEUHie2Q2cbRzg7IPjjzPMZpYOvzzvOmPiMBou6/cpcdo2IgVgAAAIEzB64P1OxLiUIV9rNFfWyKVFKTyoG2wVx6csbct8b6zFJ3wsZZP+eUbg26E4p3VlcudeSAE+VzvJJAN/nl7VqMyf7/YWh1HHusjS4awgLKw3md/H2ZqnCnjUAkslNVh7LhcnVXKvEhwrlcp3P266RABXSaY5iiPwsg9wlQ2GHalqYLATnTrEICeilQkU8gqArAAAAXBnsBCYCWAAcLAQABIwMBAQVdABAAAAyA5goBk1VRkAAA"

  func testSevenZipCatalogDownloadImportsAllDiscsAndRetryReusesThem() async throws {
    let bytes = try XCTUnwrap(Data(base64Encoded: Self.archiveFixture))
    let transport = ArchiveTransport(bytes: bytes)
    let server = try EmulationServer(address: "http://archive-\(UUID().uuidString).invalid")
    let library = EmulationServerLibrary(server: server, token: "generated-token", transport: transport)
    let page = try await library.catalog()
    let entry = try XCTUnwrap(page.entries.first)
    XCTAssertEqual(entry.game.platform, "gc")
    let folder = try server.folder(for: entry)
    defer { try? FileManager.default.removeItem(at: folder) }
    let files = try await library.copy(entry) { _ in }
    XCTAssertEqual(files.map(\.lastPathComponent), ["Disc1.iso", "Disc2.iso"])
    for (index, file) in files.enumerated() {
      let data = try Data(contentsOf: file)
      XCTAssertEqual(data.count, 0x8000)
      XCTAssertEqual(data[6], UInt8(index))
      XCTAssertTrue(file.path.hasPrefix(folder.path + "/"))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("readme.txt").path))
    let repeated = try await library.copy(entry) { _ in }
    XCTAssertEqual(repeated, files)

    try Data("existing user data".utf8).write(to: files[0])
    do {
      _ = try await library.copy(entry) { _ in }
      XCTFail("A different existing file must be preserved")
    } catch {
      XCTAssertEqual(try Data(contentsOf: files[0]), Data("existing user data".utf8))
      XCTAssertEqual(try Data(contentsOf: files[1]).count, 0x8000)
    }
  }

  func testCorruptAndEscapingSevenZipDownloadsDoNotPublishGames() async throws {
    // Generated ../escape.txt archive, also exercised by ZipImportHelperTests.
    let hostile = try XCTUnwrap(Data(base64Encoded: "N3q8ryccAARJoG80CAAAAAAAAABSAAAAAAAAAF59QUdlc2NhcGVkCgEEBgABCQgABwsBAAEBAAwIAAgKAeN2/M4AAAUBER0ALgAuAC8AZQBzAGMAYQBwAGUALgB0AHgAdAAAABQKAQAAmOf7FlLdARUGAQAggKSBAAA="))
    let noGames = try XCTUnwrap(Data(base64Encoded: "N3q8ryccAAQffpTFEgAAAAAAAABiAAAAAAAAALuO3a4BAA1ObyBkaXNjIGltYWdlcwABBAYAAQkSAAcLAQABISEBAAwOAAgKATi7/q4AAAUBGQwAAAAAAAAAAAAAAAARFwByAGUAYQBkAG0AZQAuAHQAeAB0AAAAGQQAAAAAFAoBAOX5obZicd0BFQYBACCApIEAAA=="))
    let invalidDisc = try XCTUnwrap(Data(base64Encoded: "N3q8ryccAATX+P4TFwAAAAAAAABaAAAAAAAAAJT5tWsBABJJbnZhbGlkIGRpc2MgaGVhZGVyAAEEBgABCRcABwsBAAEhIQEADBMACAoBxlKPWgAABQEZDAAAAAAAAAAAAAAAABERAGIAYQBkAC4AaQBzAG8AAAAZAgAAFAoBALI2pbZicd0BFQYBACCApIEAAA=="))
    for bytes in [Data("not an archive".utf8), hostile, noGames, invalidDisc] {
      let server = try EmulationServer(address: "http://rejected-\(UUID().uuidString).invalid")
      let library = EmulationServerLibrary(server: server, token: nil, transport: ArchiveTransport(bytes: bytes))
      let page = try await library.catalog()
      let entry = try XCTUnwrap(page.entries.first)
      let folder = try server.folder(for: entry)
      do {
        _ = try await library.copy(entry) { _ in }
        XCTFail("Invalid archives must be rejected")
      } catch {
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
      }
    }
  }

  func testPlainDiscStillImportsAndReusesItsDestination() async throws {
    var bytes = Data(repeating: 0, count: 0x8000)
    bytes.replaceSubrange(0 ..< 6, with: Data("TEST01".utf8))
    bytes.replaceSubrange(0x1C ..< 0x20, with: [0xC2, 0x33, 0x9F, 0x3D])
    let server = try EmulationServer(address: "http://plain-\(UUID().uuidString).invalid")
    let transport = ArchiveTransport(bytes: bytes, name: "Generated.iso")
    let library = EmulationServerLibrary(server: server, token: nil, transport: transport)
    let page = try await library.catalog()
    let entry = try XCTUnwrap(page.entries.first)
    let folder = try server.folder(for: entry)
    defer { try? FileManager.default.removeItem(at: folder) }
    let files = try await library.copy(entry) { _ in }
    XCTAssertEqual(files.map(\.lastPathComponent), ["Game.iso"])
    XCTAssertEqual(try Data(contentsOf: files[0]), bytes)
    let repeated = try await library.copy(entry) { _ in }
    XCTAssertEqual(repeated, files)
  }

  func testServerImportsBothDiscsFromManifestAndScannedPlaylist() async throws {
    for playlist in [false, true] {
      let server = try EmulationServer(address: "http://discs-\(UUID().uuidString).invalid")
      let transport = DiscSetTransport(playlist: playlist)
      let library = EmulationServerLibrary(server: server, token: nil, transport: transport)
      let page = try await library.catalog()
      let entry = try XCTUnwrap(page.entries.first)
      let folder = try server.folder(for: entry)
      defer { try? FileManager.default.removeItem(at: folder) }
      let urls = try await library.copy(entry) { _ in }
      XCTAssertEqual(urls.map(\.path), [
        folder.appendingPathComponent("discs/Disc 1.iso").path,
        folder.appendingPathComponent("discs/Disc 2.iso").path,
      ])
      XCTAssertEqual(try urls.map { try Data(contentsOf: $0)[6] }, [0, 1])
      let requests = await transport.downloadedIDs
      XCTAssertEqual(requests, ["disc1", "disc2"])
    }
  }

  func testFailedSecondDiscNeverPublishesFirstDisc() async throws {
    let server = try EmulationServer(address: "http://partial-\(UUID().uuidString).invalid")
    let transport = DiscSetTransport(playlist: false, corruptSecondDisc: true)
    let library = EmulationServerLibrary(server: server, token: nil, transport: transport)
    let page = try await library.catalog()
    let entry = try XCTUnwrap(page.entries.first)
    let folder = try server.folder(for: entry)
    do {
      _ = try await library.copy(entry) { _ in }
      XCTFail("A failed digest must prevent publication of the entire set")
    } catch EmulationServerLibrary.ServerError.invalidContent {
      XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
  }

  func testCancelledArchiveDownloadDoesNotPublishGames() async throws {
    let bytes = try XCTUnwrap(Data(base64Encoded: Self.archiveFixture))
    let server = try EmulationServer(address: "http://cancelled-\(UUID().uuidString).invalid")
    let transport = ArchiveTransport(bytes: bytes, cancelDownload: true)
    let library = EmulationServerLibrary(server: server, token: nil, transport: transport)
    let page = try await library.catalog()
    let entry = try XCTUnwrap(page.entries.first)
    let folder = try server.folder(for: entry)
    let task = Task { try await library.copy(entry) { _ in } }
    do {
      _ = try await task.value
      XCTFail("Cancelled downloads must be rejected")
    } catch is CancellationError {
      XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
  }

  func testTokenlessCatalogSendsNoAuthorizationHeader() async throws {
    let transport = FixtureTransport()
    let server = try EmulationServer(address: "media.local")
    let library = EmulationServerLibrary(server: server, token: nil, transport: transport)
    let page = try await library.catalog()
    XCTAssertEqual(page.entries.count, 1)
    let requests = await transport.requests
    XCTAssertTrue(requests.allSatisfy { $0.headers["Authorization"] == nil })
  }

  func testPairingLinkContainsOnlyPublicPIN() throws {
    let server = try EmulationServer(address: "https://media.local:8443")
    let challenge = EmulationServerLibrary.PairingChallenge(id: "challenge", pin: "012345", secret: "device-private-secret", expiresInSeconds: 300)
    let url = try XCTUnwrap(challenge.verificationURL(on: server))
    XCTAssertEqual(url.absoluteString, "https://media.local:8443/ui/?settings=devices#pair=012345")
  }

  func testPairingUsesPublishedV1Responses() async throws {
    let transport = FixtureTransport()
    let server = try EmulationServer(address: "https://media.local:8443")
    let library = EmulationServerLibrary(server: server, token: nil, transport: transport)
    let challenge = try await library.startPairing()
    XCTAssertEqual(challenge.pin, "012345")
    let pending = try await library.redeemPairing(challenge)
    XCTAssertNil(pending)
    let token = try await library.redeemPairing(challenge)
    XCTAssertEqual(token, "fixture-device-token")
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
  private var redemptionAttempts = 0
  private let skipFirstGame: Bool

  init(skipFirstGame: Bool = false) {
    self.skipFirstGame = skipFirstGame
  }

  func request(_ request: ContinuityRequest) async throws -> ContinuityResponse {
    requests.append(request)
    let body: String
    switch request.url.path {
    case "/api/v1/device-pairing":
      return ContinuityResponse(status: 201, body: Data(#"{"id":"challenge","pin":"012345","secret":"fixture-secret","expiresInSeconds":300}"#.utf8))
    case "/api/v1/device-pairing/redeem":
      redemptionAttempts += 1
      if redemptionAttempts == 1 { return ContinuityResponse(status: 202) }
      body = #"{"id":"device","token":"fixture-device-token","scopes":["read"]}"#
    case "/api/v1/capabilities":
      body = #"{"protocol":{"major":1}}"#
    case "/api/v1/browse-libraries":
      body = #"{"items":[{"id":"lib1"}],"nextCursor":null}"#
    case "/api/v1/browse" where URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "cursor" }) == true:
      body = """
      {"items":[
        {"entityType":"source","source":{"id":"wii1","name":"Wii.rvz","title":"Wii title","systemId":"com.provenance.wii","size":1234,"availability":"local"}},
        {"entityType":"source","source":{"id":"offline","name":"Gone.iso","systemId":"com.provenance.wii","size":1234,"availability":"offline"}}
      ],"nextCursor":null}
      """
    case "/api/v1/browse" where skipFirstGame:
      body = #"{"items":[{"entityType":"item","item":{"id":"jag1","title":"Jaguar title","systemIdentifier":"com.provenance.jaguar"}}],"nextCursor":"opaque+cursor/="}"#
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

// Generated archive download with the published source browse shape.
private actor ArchiveTransport: ContinuityTransport {
  let bytes: Data
  let name: String
  let cancelDownload: Bool

  init(bytes: Data, name: String = "Generated.7z", cancelDownload: Bool = false) {
    self.bytes = bytes
    self.name = name
    self.cancelDownload = cancelDownload
  }

  func request(_ request: ContinuityRequest) async throws -> ContinuityResponse {
    let body: String
    switch request.url.path {
    case "/api/v1/capabilities":
      body = #"{"protocol":{"major":1}}"#
    case "/api/v1/browse-libraries":
      body = #"{"items":[{"id":"lib1"}],"nextCursor":null}"#
    case "/api/v1/browse":
      body = """
      {"items":[{"entityType":"source","source":{"id":"archive1","name":"\(name)","systemId":"com.provenance.gamecube","size":\(bytes.count),"availability":"local"}}],"nextCursor":null}
      """
    default:
      throw URLError(.unsupportedURL)
    }
    return ContinuityResponse(status: 200, body: Data(body.utf8))
  }

  func download(_ request: ContinuityRequest, to destination: URL, resumeOffset: Int64,
                progress: (@Sendable (Int64, Int64?) -> Void)?) async throws -> Int64 {
    guard request.url.path == "/api/v1/sources/archive1/content" else { throw URLError(.unsupportedURL) }
    try bytes.write(to: destination)
    if cancelDownload { withUnsafeCurrentTask { $0?.cancel() } }
    progress?(Int64(bytes.count), Int64(bytes.count))
    return Int64(bytes.count)
  }
}

private actor DiscSetTransport: ContinuityTransport {
  let playlist: Bool
  let corruptSecondDisc: Bool
  private(set) var downloadedIDs: [String] = []

  init(playlist: Bool, corruptSecondDisc: Bool = false) {
    self.playlist = playlist
    self.corruptSecondDisc = corruptSecondDisc
  }

  func request(_ request: ContinuityRequest) async throws -> ContinuityResponse {
    let body: String
    switch request.url.path {
    case "/api/v1/capabilities":
      body = #"{"protocol":{"major":1}}"#
    case "/api/v1/browse-libraries":
      body = #"{"items":[{"id":"lib1"}],"nextCursor":null}"#
    case "/api/v1/browse" where playlist:
      body = """
      {"items":[{"entityType":"source","source":{"id":"set","name":"Game.m3u","systemId":"com.provenance.gamecube",
      "size":32,"availability":"local","groupFileCount":3}}],"nextCursor":null}
      """
    case "/api/v1/browse":
      body = """
      {"items":[{"entityType":"item","item":{"id":"set","title":"Game","systemIdentifier":"com.provenance.gamecube"}}],
      "nextCursor":null}
      """
    case "/api/v1/sources/set/group":
      body = """
      {"sourceId":"set","error":null,"files":[
      {"id":"set","relativePath":"Game.m3u","size":32,"availability":"local"},
      {"id":"disc1","relativePath":"discs/Disc 1.iso","size":32768,"availability":"local"},
      {"id":"disc2","relativePath":"discs/Disc 2.iso","size":32768,"availability":"local"}]}
      """
    case "/api/v1/items/set/manifest":
      let files = (1 ... 2).map { disc in
        let hash = SHA256.hash(data: Self.disc(disc)).map { String(format: "%02x", $0) }.joined()
        return """
        {"id":"disc\(disc)","kind":"rom","relativePath":"discs/Disc \(disc).iso","size":32768,
        "sha256":"\(hash)","required":true}
        """
      }
      body = """
      {"itemId":"set","version":1,"files":[\(files.joined(separator: ","))]}
      """
    default:
      throw URLError(.unsupportedURL)
    }
    return ContinuityResponse(status: 200, body: Data(body.utf8))
  }

  func download(_ request: ContinuityRequest, to destination: URL, resumeOffset: Int64,
                progress: (@Sendable (Int64, Int64?) -> Void)?) async throws -> Int64 {
    let collection = playlist ? "sources" : "files"
    let disc: Int
    switch request.url.path {
    case "/api/v1/\(collection)/disc1/content": disc = 1
    case "/api/v1/\(collection)/disc2/content": disc = 2
    default: throw URLError(.unsupportedURL)
    }
    downloadedIDs.append("disc\(disc)")
    var bytes = Self.disc(disc)
    if corruptSecondDisc, disc == 2 { bytes[0] = 0 }
    try bytes.write(to: destination)
    progress?(Int64(bytes.count), Int64(bytes.count))
    return Int64(bytes.count)
  }

  private static func disc(_ number: Int) -> Data {
    var bytes = Data(repeating: 0, count: 0x8000)
    bytes.replaceSubrange(0 ..< 6, with: Data("TEST01".utf8))
    bytes[6] = UInt8(number - 1)
    bytes.replaceSubrange(0x1C ..< 0x20, with: [0xC2, 0x33, 0x9F, 0x3D])
    return bytes
  }
}
