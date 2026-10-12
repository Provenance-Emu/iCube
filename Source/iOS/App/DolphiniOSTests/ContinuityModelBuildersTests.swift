// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import PVContinuity
import SwiftUI
import XCTest
@testable import iCube

final class ContinuityModelBuildersTests: XCTestCase {
  func test_browse_emptyPeers_showsLookingCaption_andSharingRow() {
    let m = ContinuityBrowseModelBuilder.make(peers: [], trusted: [], sharesLibrary: true, showsDone: false,
                                              peerDetail: { _ in AnyView(EmptyView()) }, trustedDetail: { _ in AnyView(EmptyView()) },
                                              sharing: AnyView(EmptyView()), done: {})
    XCTAssertEqual(m.sections.map(\.id), ["peers", "this-device"])
    XCTAssertEqual(m.item(id: "looking")?.isEnabled, false)
    XCTAssertEqual(m.item(id: "share-library")?.badge, "On")
    XCTAssertEqual(m.sections[0].footer, ContinuityManager.transportSecurityNotice)
  }

  func test_browse_peersAndTrusted_becomeDestinationRows() {
    let m = ContinuityBrowseModelBuilder.make(
      peers: [.init(id: "p1", name: "Joe's iPad", subtitle: "Playing Melee", glyph: "ipad")],
      trusted: [("t1", "Living Room TV")], sharesLibrary: false, showsDone: true,
      peerDetail: { _ in AnyView(EmptyView()) }, trustedDetail: { _ in AnyView(EmptyView()) }, sharing: AnyView(EmptyView()), done: {})
    XCTAssertEqual(m.allItems.map(\.id), ["peer-p1", "share-library", "trusted-t1", "done"])
    XCTAssertEqual(m.item(id: "peer-p1")?.subtitle, "Playing Melee")
  }

  func test_sharing_toggle_andShareAgain() {
    var shares: [Bool] = []
    var again: [String] = []
    let m = ContinuitySharingModelBuilder.make(sharesLibrary: true, grants: [], excluded: [("GALE01", "Melee")],
                                               grantDetail: { _, _ in AnyView(EmptyView()) }, setShares: { shares.append($0) }, shareAgain: { again.append($0) })
    guard case .toggle(let b) = m.item(id: "share")?.role else { return XCTFail() }
    b.wrappedValue = false
    guard case .action(let run) = m.item(id: "excluded-GALE01")?.role else { return XCTFail() }
    run()
    XCTAssertEqual(shares, [false])
    XCTAssertEqual(again, ["GALE01"])
  }

  func test_grant_isAPicker_withClearOnlyWhenExplicit() {
    var chosen: [ContinuityLibraryGrant] = []
    let explicit = ContinuitySharingModelBuilder.grant(peerName: "iPad", current: .askPerGame, hasExplicitGrant: true, choose: { chosen.append($0) }, clear: {})
    guard case .picker(let options, let sel) = explicit.item(id: "grant")?.role else { return XCTFail() }
    XCTAssertEqual(options.map(\.0), ["Always Allow", "Ask Every Time", "Don't Share"])
    sel.wrappedValue = AnyHashable(ContinuityLibraryGrant.everything)
    XCTAssertEqual(chosen, [.everything])
    XCTAssertNotNil(explicit.item(id: "clear"))
    XCTAssertNil(ContinuitySharingModelBuilder.grant(peerName: "iPad", current: .askPerGame, hasExplicitGrant: false, choose: { _ in }, clear: {}).item(id: "clear"))
  }
}
