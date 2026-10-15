// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

/// The shared "tap to play" tag format: what iCube writes, and how it reads
/// its own, a sibling's, and a foreign tag.
final class GameTagPayloadTests: XCTestCase {
  func test_launchURL_isTheExistingPlayRoute() {
    XCTAssertEqual(GameTagPayload.launchURL(gameID: "GALE01")?.absoluteString, "dolphinios://play?id=GALE01")
    XCTAssertNil(GameTagPayload.launchURL(gameID: "  "))
  }

  func test_textRecord_carriesAppAndTitle_andDropsSeparators() {
    let payload = GameTagPayload(gameID: "GALE01", title: "Smash; Melee")
    XCTAssertEqual(payload?.textRecord, "app=com.joemattiello.iCube;title=Smash  Melee")
  }

  func test_parseTextRecord_roundTrips_andToleratesSpacing() {
    let parsed = GameTagPayload.parseTextRecord("app=com.joemattiello.iCube; title = Metroid Prime")
    XCTAssertEqual(parsed?.appID, "com.joemattiello.iCube")
    XCTAssertEqual(parsed?.title, "Metroid Prime")
    XCTAssertNil(GameTagPayload.parseTextRecord("title=No App"))
  }

  func test_classify_ownTag_yieldsTheGameID() {
    XCTAssertEqual(GameTagPayload.classify(URL(string: "dolphinios://play?id=GM8E01")!), .own(gameID: "GM8E01"))
    XCTAssertEqual(GameTagPayload.classify(URL(string: "DOLPHINIOS://PLAY?id=GM8E01")!), .own(gameID: "GM8E01"))
  }

  func test_classify_ownSchemeWithoutAGame_isUnknown() {
    XCTAssertEqual(GameTagPayload.classify(URL(string: "dolphinios://gameInfo?scheme=provenance")!), .unknown)
    XCTAssertEqual(GameTagPayload.classify(URL(string: "dolphinios://play")!), .unknown)
  }

  func test_classify_universalLinks_ownAndSibling() {
    XCTAssertEqual(GameTagPayload.classify(URL(string: "https://icube-emu.com/play?id=GALE01")!), .own(gameID: "GALE01"))
    XCTAssertEqual(GameTagPayload.classify(URL(string: "https://www.icube-emu.com/play?id=GALE01")!), .own(gameID: "GALE01"))
    XCTAssertEqual(GameTagPayload.classify(URL(string: "https://icube-emu.com/other")!), .unknown)
    XCTAssertEqual(GameTagPayload.classify(URL(string: "https://provenance-emu.com/game/0123ABCD")!), .sibling(.provenance))
    XCTAssertEqual(GameTagPayload.classify(URL(string: "https://provenance.app/game/x")!), .sibling(.provenance))
    XCTAssertEqual(GameTagPayload.classify(URL(string: "https://ifly-emu.com/open?id=x")!), .sibling(.ifly))
    XCTAssertEqual(GameTagPayload.classify(URL(string: "https://notprovenance-emu.com/game/x")!), .unknown)
  }

  func test_classify_siblingTags_areNamedNotOpened() {
    XCTAssertEqual(GameTagPayload.classify(URL(string: "provenance://open?md5=abc")!), .sibling(.provenance))
    XCTAssertEqual(GameTagPayload.classify(URL(string: "ifly://open?id=/some/path")!), .sibling(.ifly))
    XCTAssertEqual(GameTagPayload.classify(URL(string: "https://example.com")!), .unknown)
  }

  func test_outcome_launchesOwn_announcesSibling_rejectsForeign() {
    let own = GameTagPayload(launchURL: URL(string: "dolphinios://play?id=GALE01")!, appID: GameTagPayload.ownAppID, title: "Melee")
    XCTAssertEqual(GameTagCenter.outcome(for: own).launchGameID, "GALE01")
    XCTAssertNil(GameTagCenter.outcome(for: own).message)

    let sibling = GameTagPayload(launchURL: URL(string: "ifly://open?id=x")!, appID: "com.joemattiello.iFly", title: "Crazy Taxi")
    XCTAssertNil(GameTagCenter.outcome(for: sibling).launchGameID)
    XCTAssertEqual(GameTagCenter.outcome(for: sibling).message, "This tag belongs to iFly.")

    let foreign = GameTagPayload(launchURL: URL(string: "https://example.com")!, appID: "", title: "")
    XCTAssertNil(GameTagCenter.outcome(for: foreign).launchGameID)
    XCTAssertNotNil(GameTagCenter.outcome(for: foreign).message)
  }

  func test_from_requiresAURI_andSurvivesAMissingTextRecord() {
    XCTAssertNil(GameTagPayload.from(uri: nil, text: "app=x;title=y"))
    let bare = GameTagPayload.from(uri: URL(string: "dolphinios://play?id=GALE01")!, text: nil)
    XCTAssertEqual(bare?.appID, "")
    XCTAssertEqual(bare?.title, "")
  }
}
