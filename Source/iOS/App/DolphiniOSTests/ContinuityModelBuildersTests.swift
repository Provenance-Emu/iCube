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
    XCTAssertEqual(m.allItems.map(\.id), ["peer-p1", "device-name", "share-library", "trusted-t1", "done"])
    XCTAssertEqual(m.item(id: "peer-p1")?.subtitle, "Playing Melee")
  }

  func test_browse_hasDeviceNameRow_withTheCurrentNameAsBadge() {
    var renames = 0
    let m = ContinuityBrowseModelBuilder.make(
      peers: [], trusted: [], sharesLibrary: false, showsDone: false,
      peerDetail: { _ in AnyView(EmptyView()) }, trustedDetail: { _ in AnyView(EmptyView()) }, sharing: AnyView(EmptyView()), done: {},
      deviceName: "Den iPhone", renameDevice: { renames += 1 })
    XCTAssertEqual(m.sections[1].id, "this-device")
    XCTAssertEqual(m.sections[1].items.first?.id, "device-name")
    XCTAssertEqual(m.item(id: "device-name")?.badge, "Den iPhone")
    guard case .action(let run)? = m.item(id: "device-name")?.role else { return XCTFail("device-name is not an action row") }
    run()
    XCTAssertEqual(renames, 1)
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

  func test_handoff_idle_offersAndNotice_areRows_andDoneCloses() {
    var began = 0, closed = 0
    let m = ContinuityHandoffModelBuilder.make(gameTitle: "Melee", gameID: "GALE01", isOffering: false, error: nil,
                                               begin: { began += 1 }, stop: {}, done: { closed += 1 })
    XCTAssertEqual(m.sections.map(\.id), ["notice", "game", "handoff", "done"])
    XCTAssertEqual(m.item(id: "notice")?.title, ContinuityManager.transportSecurityNotice)
    XCTAssertEqual(m.item(id: "notice")?.isEnabled, false, "read-only text the remote walks past")
    XCTAssertEqual(m.focusableIDs, [ContinuityHandoffModelBuilder.offerItemID, ContinuityHandoffModelBuilder.doneItemID])
    XCTAssertTrue(m.item(id: ContinuityHandoffModelBuilder.offerItemID)?.activateInPlace() ?? false)
    XCTAssertTrue(m.item(id: ContinuityHandoffModelBuilder.doneItemID)?.activateInPlace() ?? false)
    XCTAssertEqual(began, 1)
    XCTAssertEqual(closed, 1)
  }

  func test_handoff_offering_showsStatusAndStop_andErrorCaption() {
    var stopped = 0
    let m = ContinuityHandoffModelBuilder.make(gameTitle: "Melee", gameID: "GALE01", isOffering: true, error: "Bonjour failed",
                                               begin: {}, stop: { stopped += 1 }, done: {})
    XCTAssertEqual(m.sections.map(\.id), ["notice", "game", "error", "handoff", "done"])
    XCTAssertEqual(m.item(id: "error")?.title, "Bonjour failed")
    XCTAssertNil(m.item(id: ContinuityHandoffModelBuilder.offerItemID))
    XCTAssertEqual(m.item(id: "status")?.isEnabled, false)
    guard case .destructive(let run) = m.item(id: ContinuityHandoffModelBuilder.stopItemID)?.role else { return XCTFail("expected destructive") }
    run()
    XCTAssertEqual(stopped, 1)
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
