// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import CryptoKit
import XCTest
@testable import iCube

final class NearbySaveTransferTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_000_000)

  func testRequestIsBoundToPairedKeyServerGameAndTime() throws {
    let key = Curve25519.Signing.PrivateKey()
    let request = NearbySaveWire.Request(peerID: "phone", serverID: "tv", gameKey: "id:GALE01|d0|r0",
                                         nonce: UUID().uuidString, issuedAt: now)
    let payload = try JSONEncoder().encode(request)
    let signed = NearbySaveWire.SignedRequest(payload: payload, signature: try key.signature(for: NearbySaveWire.signingData(payload)))
    let publicKey = key.publicKey.rawRepresentation
    XCTAssertEqual(NearbySaveWire.verify(signed, publicKey: publicKey, serverID: "tv", now: now)?.gameKey, request.gameKey)
    XCTAssertNil(NearbySaveWire.verify(signed, publicKey: publicKey, serverID: "other", now: now))
    XCTAssertNil(NearbySaveWire.verify(signed, publicKey: publicKey, serverID: "tv", now: now.addingTimeInterval(121)))
    XCTAssertNil(NearbySaveWire.verify(signed, publicKey: publicKey, serverID: "tv", now: now.addingTimeInterval(-121)))
    XCTAssertNil(NearbySaveWire.verify(signed, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, serverID: "tv", now: now))
    let tampered = NearbySaveWire.SignedRequest(payload: Data(String(decoding: payload, as: UTF8.self).replacingOccurrences(of: "GALE01", with: "GZLE01").utf8), signature: signed.signature)
    XCTAssertNil(NearbySaveWire.verify(tampered, publicKey: publicKey, serverID: "tv", now: now))
  }

  func testUnsignedAndOtherProtocolSignaturesCannotAuthorizeSaves() throws {
    let key = Curve25519.Signing.PrivateKey()
    let payload = try JSONEncoder().encode(NearbySaveWire.Request(peerID: "phone", serverID: "tv",
                                                                  gameKey: "game", nonce: UUID().uuidString, issuedAt: now))
    let signed = NearbySaveWire.SignedRequest(payload: payload, signature: try key.signature(for: payload))
    XCTAssertNil(NearbySaveWire.verify(signed, publicKey: key.publicKey.rawRepresentation, serverID: "tv", now: now))
  }

  func testReplayIsRejectedAndMemoryIsBounded() {
    var guardState = NearbySaveReplayGuard()
    XCTAssertTrue(guardState.accept("nonce", now: now))
    XCTAssertFalse(guardState.accept("nonce", now: now.addingTimeInterval(119)))
    for index in 0 ..< 255 { XCTAssertTrue(guardState.accept("\(index)", now: now)) }
    XCTAssertFalse(guardState.accept("overflow", now: now))
    XCTAssertTrue(guardState.accept("fresh", now: now.addingTimeInterval(241)))
  }

  func testProgressKeepsMBAndOneDecimalAtUnitBoundaries() {
    let locale = Locale(identifier: "en_US")
    XCTAssertEqual(NearbyTransferFormat.label(bytes: 900_000, total: 2_000_000_000, locale: locale), "0.9 / 2,000.0 MB")
    XCTAssertEqual(NearbyTransferFormat.label(bytes: 10_000_000, total: 2_000_000_000, locale: locale), "10.0 / 2,000.0 MB")
    XCTAssertEqual(NearbyTransferFormat.label(bytes: 1_000_000_000, total: 2_000_000_000, locale: locale), "1,000.0 / 2,000.0 MB")
    XCTAssertEqual(NearbyTransferFormat.label(bytes: -1, total: 0, locale: locale), "0.0 / 0.0 MB")
  }
}
