// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

/// `https://icube-emu.com/play?id=…` universal links onto the custom-scheme play route, and nothing else.
final class UniversalLinkRouterTests: XCTestCase {
  private func map(_ string: String) -> String? {
    URL(string: string).flatMap(UniversalLinkRouter.customSchemeURL(for:))?.absoluteString
  }

  func test_playLink_mapsToTheCustomSchemePlayRoute() {
    XCTAssertEqual(map("https://icube-emu.com/play?id=GALE01"), "dolphinios://play?id=GALE01")
    XCTAssertEqual(UniversalLinkRouter.route(for: URL(string: "https://icube-emu.com/play?id=GALE01")!), .play(gameID: "GALE01"))
  }

  func test_hostAndPathAndSchemeCase_areIgnored() {
    XCTAssertEqual(map("HTTPS://ICube-Emu.com/PLAY?id=GM8E01"), "dolphinios://play?id=GM8E01")
    XCTAssertEqual(map("https://www.icube-emu.com/play?id=GM8E01"), "dolphinios://play?id=GM8E01")
  }

  func test_otherQueryItemsAndFragment_areDropped() {
    XCTAssertEqual(map("https://icube-emu.com/play?utm=x&id=RSBE01&scheme=evil#frag"), "dolphinios://play?id=RSBE01")
  }

  func test_unknownPaths_areIgnored() {
    for path in ["", "/", "/play/", "/play/x", "/help/web-import", "/support", "/api/v2/update.json",
                 "/dsu/add", "/dsu/controller", "/gameinfo", "/requestgame", "/open", "/.well-known/apple-app-site-association"] {
      XCTAssertNil(map("https://icube-emu.com\(path)?id=GALE01&ip=10.0.0.2&port=26760&scheme=x"), path)
    }
  }

  func test_otherSchemesHostsPortsAndCredentials_areIgnored() {
    XCTAssertNil(map("http://icube-emu.com/play?id=GALE01"))
    XCTAssertNil(map("dolphinios://play?id=GALE01"))
    XCTAssertNil(map("https://example.com/play?id=GALE01"))
    XCTAssertNil(map("https://notice-emu.com/play?id=GALE01"))
    XCTAssertNil(map("https://icube-emu.com.evil.test/play?id=GALE01"))
    XCTAssertNil(map("https://evil.icube-emu.com/play?id=GALE01"))
    XCTAssertNil(map("https://icube-emu.com:8443/play?id=GALE01"))
    XCTAssertNil(map("https://user:pass@icube-emu.com/play?id=GALE01"))
    XCTAssertNil(map("https://icube-emu.com@evil.test/play?id=GALE01"))
  }

  func test_missingOrRepeatedID_isIgnored() {
    XCTAssertNil(map("https://icube-emu.com/play"))
    XCTAssertNil(map("https://icube-emu.com/play?id="))
    XCTAssertNil(map("https://icube-emu.com/play?game=GALE01"))
    XCTAssertNil(map("https://icube-emu.com/play?id=GALE01&id=GM8E01"))
  }

  func test_gameIDsThatCouldReachAPath_areRejected() {
    for id in ["..", "../x", "a/b", "a%2Fb", "%2e%2e%2f", "a.b", "a b", "a%20b", "a%00b", "a\\b", "ａｂｃ", "é", "<x>", "a;b", "a?b"] {
      let url = URL(string: "https://icube-emu.com/play?id=\(id)")
      XCTAssertNil(url.flatMap(UniversalLinkRouter.customSchemeURL(for:)), id)
    }
    XCTAssertNil(map("https://icube-emu.com/play?id=" + String(repeating: "A", count: UniversalLinkRouter.maxGameIDLength + 1)))
  }

  func test_validGameIDs_areAccepted() {
    for id in ["GALE01", "GM8E", "gale01", "DOL-homebrew_1", String(repeating: "A", count: UniversalLinkRouter.maxGameIDLength)] {
      XCTAssertEqual(map("https://icube-emu.com/play?id=\(id)"), "dolphinios://play?id=\(id)", id)
    }
  }

  func test_validGameID_rules() {
    XCTAssertTrue(UniversalLinkRouter.isValidGameID("GALE01"))
    XCTAssertFalse(UniversalLinkRouter.isValidGameID(""))
    XCTAssertFalse(UniversalLinkRouter.isValidGameID("a/b"))
    XCTAssertFalse(UniversalLinkRouter.isValidGameID("a.b"))
  }

  /// The mapped URL is a route the router really claims: it classifies as our own tag with the same id.
  func test_mappedURL_agreesWithTheNFCTagClassifier() throws {
    let web = try XCTUnwrap(URL(string: "https://icube-emu.com/play?id=GALE01"))
    let mapped = try XCTUnwrap(UniversalLinkRouter.customSchemeURL(for: web))
    XCTAssertEqual(GameTagPayload.classify(web), .own(gameID: "GALE01"))
    XCTAssertEqual(GameTagPayload.classify(mapped), GameTagPayload.classify(web))
  }

  func test_classifierAndMapper_acceptTheSameOwnLinks() {
    for string in ["https://icube-emu.com/play?id=GALE01", "https://www.icube-emu.com/play?id=GALE01",
                   "https://icube-emu.com/other", "https://icube-emu.com/play",
                   "https://provenance-emu.com/game/0123ABCD", "https://example.com/play?id=GALE01"] {
      let url = URL(string: string)!
      let isOwn: Bool
      if case .own = GameTagPayload.classify(url) { isOwn = true } else { isOwn = false }
      XCTAssertEqual(UniversalLinkRouter.route(for: url) != nil, isOwn, string)
    }
  }

  func test_webActivity_mapsOnlyBrowsingWebActivities() {
    let web = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
    web.webpageURL = URL(string: "https://icube-emu.com/play?id=GALE01")
    XCTAssertEqual(UniversalLinkRouter.customSchemeURL(for: web)?.absoluteString, "dolphinios://play?id=GALE01")

    let other = NSUserActivity(activityType: "com.joemattiello.icube.continuity.play")
    other.webpageURL = URL(string: "https://icube-emu.com/play?id=GALE01")
    XCTAssertNil(UniversalLinkRouter.customSchemeURL(for: other))

    let noURL = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
    XCTAssertNil(UniversalLinkRouter.customSchemeURL(for: noURL))

    let unknown = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
    unknown.webpageURL = URL(string: "https://icube-emu.com/help/web-import")
    XCTAssertNil(UniversalLinkRouter.customSchemeURL(for: unknown))
  }

  /// The mapped URL has the scheme and host `URLRouterService.handlePlayLink` claims.
  func test_mappedURL_hasTheSchemeAndHostThePlayRouteClaims() throws {
    let web = try XCTUnwrap(URL(string: "https://icube-emu.com/play?id=GALE01"))
    let mapped = try XCTUnwrap(UniversalLinkRouter.customSchemeURL(for: web))
    XCTAssertEqual(mapped.scheme, EcosystemSchemes.ownScheme)
    XCTAssertEqual(mapped.host, GameTagPayload.launchHost)
  }
}
