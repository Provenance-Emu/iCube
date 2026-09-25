// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

final class EcosystemBridgeTests: XCTestCase {

    // MARK: - parse: gameInfo

    func test_parse_gameInfo_validCallbackScheme() {
        let url = URL(string: "dolphinios://gameInfo?scheme=provenance")!
        XCTAssertEqual(EcosystemBridge.parse(url), .gameInfo(callbackScheme: "provenance"))
    }

    func test_parse_gameInfo_missingScheme_returnsNil() {
        let url = URL(string: "dolphinios://gameInfo")!
        XCTAssertNil(EcosystemBridge.parse(url))
    }

    // MARK: - parse: open (alias of play)

    func test_parse_open_validId() {
        let url = URL(string: "dolphinios://open?id=GALE01")!
        XCTAssertEqual(EcosystemBridge.parse(url), .open(gameID: "GALE01"))
    }

    func test_parse_open_emptyId_returnsNil() {
        let url = URL(string: "dolphinios://open?id=")!
        XCTAssertNil(EcosystemBridge.parse(url))
    }

    func test_parse_open_missingId_returnsNil() {
        let url = URL(string: "dolphinios://open")!
        XCTAssertNil(EcosystemBridge.parse(url))
    }

    // MARK: - parse: requestGame

    func test_parse_requestGame_validIdAndScheme() {
        let url = URL(string: "dolphinios://requestGame?id=GALE01&scheme=provenance")!
        XCTAssertEqual(
            EcosystemBridge.parse(url),
            .requestGame(gameID: "GALE01", callbackScheme: "provenance")
        )
    }

    func test_parse_requestGame_missingScheme_returnsNil() {
        let url = URL(string: "dolphinios://requestGame?id=GALE01")!
        XCTAssertNil(EcosystemBridge.parse(url))
    }

    // MARK: - parse: rejected callback schemes

    func test_parse_rejectsCallbackSchemeWithSlash() {
        // A forged scheme trying to shape the reply URL (e.g. embedding a path).
        let url = URL(string: "dolphinios://gameInfo?scheme=evil/../thing")!
        XCTAssertNil(EcosystemBridge.parse(url))
    }

    func test_parse_rejectsEmptyCallbackScheme() {
        let url = URL(string: "dolphinios://gameInfo?scheme=")!
        XCTAssertNil(EcosystemBridge.parse(url))
    }

    func test_parse_rejectsCallbackSchemeStartingWithDigit() {
        // Scheme charset requires an alpha first character (RFC 3986 scheme grammar).
        let url = URL(string: "dolphinios://requestGame?id=GALE01&scheme=1bad")!
        XCTAssertNil(EcosystemBridge.parse(url))
    }

    func test_parse_rejectsOverlongCallbackScheme() {
        let long = String(repeating: "a", count: 65)
        let url = URL(string: "dolphinios://gameInfo?scheme=\(long)")!
        XCTAssertNil(EcosystemBridge.parse(url))
    }

    func test_parse_acceptsCallbackSchemeWithAllowedPunctuation() {
        let url = URL(string: "dolphinios://gameInfo?scheme=my-app.v2+beta")!
        XCTAssertEqual(EcosystemBridge.parse(url), .gameInfo(callbackScheme: "my-app.v2+beta"))
    }

    // MARK: - parse: not ours

    func test_parse_wrongScheme_returnsNil() {
        let url = URL(string: "provenance://gameInfo?scheme=dolphinios")!
        XCTAssertNil(EcosystemBridge.parse(url))
    }

    func test_parse_unknownHost_returnsNil() {
        let url = URL(string: "dolphinios://unknownroute?id=GALE01")!
        XCTAssertNil(EcosystemBridge.parse(url))
    }

    // MARK: - Callback URL building

    func test_callbackURL_buildsExpectedShape() {
        let url = EcosystemBridge.callbackURL(scheme: "provenance", query: "games", value: "abc123")
        XCTAssertEqual(url?.absoluteString, "provenance://dolphinios?games=abc123")
    }

    func test_callbackURL_fetchShape() {
        let url = EcosystemBridge.callbackURL(scheme: "provenance", query: "fetch", value: "xyz")
        XCTAssertEqual(url?.absoluteString, "provenance://dolphinios?fetch=xyz")
    }

    // MARK: - base64url

    func test_base64url_hasNoPaddingOrUnsafeCharacters() {
        // Payload length chosen so standard base64 would need padding.
        let data = Data([0x01])
        let encoded = EcosystemBridge.base64url(data)
        XCTAssertFalse(encoded.contains("="))
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
    }

    func test_base64url_roundTripsGamePayload() throws {
        let games = [
            EcosystemBridge.GamePayload(titleName: "Wave Race: Blue Storm", titleId: "GWQE01", developer: "01", version: "GameCube", iconData: nil),
            EcosystemBridge.GamePayload(titleName: "Metroid Prime", titleId: "GM8E01", developer: "01", version: "GameCube", iconData: nil)
        ]
        let data = try JSONEncoder().encode(games)
        let encoded = EcosystemBridge.base64url(data)

        var restored = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = restored.count % 4
        if remainder != 0 { restored += String(repeating: "=", count: 4 - remainder) }

        let decodedData = try XCTUnwrap(Data(base64Encoded: restored))
        let decoded = try JSONDecoder().decode([EcosystemBridge.GamePayload].self, from: decodedData)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded.first?.titleName, "Wave Race: Blue Storm")
        XCTAssertEqual(decoded.first?.titleId, "GWQE01")
    }

    // MARK: - Maker code

    func test_makerCode_isLastTwoCharactersOfGameID() {
        XCTAssertEqual(EcosystemBridge.makerCode(forGameID: "GALE01"), "01")
        XCTAssertEqual(EcosystemBridge.makerCode(forGameID: "GM8E08"), "08")
    }

    func test_makerCode_nilForShortID() {
        XCTAssertNil(EcosystemBridge.makerCode(forGameID: "GAL"))
    }

    // MARK: - Transfer id (FetchPayload.md5)

    func test_transferId_isHexAndCorrectLength() {
        let id = EcosystemBridge.transferId(gameID: "GALE01", filename: "game.rvz")
        XCTAssertEqual(id.count, 32)
        XCTAssertTrue(id.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(id, id.lowercased())
    }

    func test_transferId_isStableForSameInputs() {
        let first = EcosystemBridge.transferId(gameID: "GALE01", filename: "game.rvz")
        let second = EcosystemBridge.transferId(gameID: "GALE01", filename: "game.rvz")
        XCTAssertEqual(first, second)
    }

    func test_transferId_differsForDifferentInputs() {
        let a = EcosystemBridge.transferId(gameID: "GALE01", filename: "game.rvz")
        let b = EcosystemBridge.transferId(gameID: "GALE02", filename: "game.rvz")
        let c = EcosystemBridge.transferId(gameID: "GALE01", filename: "other.rvz")
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
