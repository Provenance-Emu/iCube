// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class PhoneControllerConnectorTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_000_000)

  private func server(pid: String, name: String = "Joe's iPhone", address: String = "192.168.1.20",
                      port: Int = 26760, isController: Bool = true) -> DSUDiscoveredServer {
    DSUDiscoveredServer(name: name, address: address, port: port,
                        advert: DSUAdvert(pid: pid, name: name, deviceType: "iPhone", isController: isController))
  }

  private func entry(_ description: String, address: String = "192.168.1.20", port: Int = 26760) -> DSUEntry {
    DSUEntry(description: description, address: address, port: port)
  }

  func test_newPhone_isPromptedOnce() {
    let phone = server(pid: "A")
    let state = PhoneConnectorState()
    // Listed twice (two resolves of one phone): still one prompt.
    let actions = PhoneControllerConnector.actions(servers: [phone, phone], entries: [], state: state, now: now)
    XCTAssertEqual(actions, [.prompt(pid: "A", name: "Joe's iPhone")])
  }

  func test_confirmedPhone_isAdded_withAUniqueDescription() {
    var state = PhoneConnectorState()
    state.confirmed = ["A"]
    let actions = PhoneControllerConnector.actions(servers: [server(pid: "A")],
                                                   entries: [entry("Joe's iPhone", address: "10.0.0.9")],
                                                   state: state, now: now)
    XCTAssertEqual(actions, [.add(pid: "A", entry: entry("Joe's iPhone (2)"))])
  }

  func test_declinedPhone_isNotAskedAgainThisLaunch() {
    var state = PhoneConnectorState()
    state.declined = ["A"]
    let actions = PhoneControllerConnector.actions(servers: [server(pid: "A")], entries: [], state: state, now: now)
    XCTAssertEqual(actions, [])
  }

  func test_ipChange_updatesTheSameEntry() {
    var state = PhoneConnectorState()
    state.confirmed = ["A"]
    state.owned = ["A": entry("Joe's iPhone")]
    let entries = [entry("Living room"), entry("Joe's iPhone", address: "192.168.1.20")]
    let moved = server(pid: "A", address: "192.168.1.77", port: 26761)
    let actions = PhoneControllerConnector.actions(servers: [moved], entries: entries, state: state, now: now)
    XCTAssertEqual(actions, [.update(pid: "A", index: 1, entry: entry("Joe's iPhone", address: "192.168.1.77", port: 26761))])
  }

  func test_unchangedAddress_doesNothing() {
    var state = PhoneConnectorState()
    state.confirmed = ["A"]
    state.owned = ["A": entry("Joe's iPhone")]
    let actions = PhoneControllerConnector.actions(servers: [server(pid: "A")], entries: [entry("Joe's iPhone")],
                                                   state: state, now: now)
    XCTAssertEqual(actions, [])
  }

  func test_twoPhonesSameName_getDistinctDescriptions() {
    var state = PhoneConnectorState()
    state.confirmed = ["A", "B"]
    let actions = PhoneControllerConnector.actions(servers: [server(pid: "A"), server(pid: "B", address: "192.168.1.21")],
                                                   entries: [], state: state, now: now)
    XCTAssertEqual(actions, [
      .add(pid: "A", entry: entry("Joe's iPhone")),
      .add(pid: "B", entry: entry("Joe's iPhone (2)", address: "192.168.1.21")),
    ])
    XCTAssertEqual(PhoneControllerConnector.uniqueDescription(for: "Joe's iPhone", taken: ["Joe's iPhone", "Joe's iPhone (2)"]),
                   "Joe's iPhone (3)")
    XCTAssertEqual(PhoneControllerConnector.uniqueDescription(for: "Joe's iPhone", taken: []), "Joe's iPhone")
  }

  func test_departedPhone_isRemovedOnlyAfterTheGrace() {
    var state = PhoneConnectorState()
    state.confirmed = ["A"]
    state.owned = ["A": entry("Joe's iPhone")]
    let entries = [entry("Living room"), entry("Joe's iPhone")]

    state.lastSeen = ["A": now.addingTimeInterval(-9)]
    XCTAssertEqual(PhoneControllerConnector.actions(servers: [], entries: entries, state: state, now: now), [])

    state.lastSeen = ["A": now.addingTimeInterval(-11)]
    XCTAssertEqual(PhoneControllerConnector.actions(servers: [], entries: entries, state: state, now: now),
                   [.remove(pid: "A", index: 1)])

    // A phone that never recorded a sighting counts as gone now.
    state.lastSeen = [:]
    XCTAssertEqual(PhoneControllerConnector.actions(servers: [], entries: entries, state: state, now: now),
                   [.remove(pid: "A", index: 1)])
  }

  func test_manualEntries_areNeverTouched() {
    var state = PhoneConnectorState()
    state.confirmed = ["A"]
    state.owned = ["A": entry("Joe's iPhone")]
    state.lastSeen = ["A": now.addingTimeInterval(-60)]
    // A manual entry with the phone's address, one for a phone not owned, and the owned one.
    let entries = [entry("Manual", address: "192.168.1.20"), entry("Desk PC", address: "10.0.0.5"), entry("Joe's iPhone")]
    let actions = PhoneControllerConnector.actions(servers: [], entries: entries, state: state, now: now)
    XCTAssertEqual(actions, [.remove(pid: "A", index: 2)])

    // An owned description with no matching entry (the user deleted it) removes nothing.
    let none = PhoneControllerConnector.actions(servers: [], entries: [entry("Manual")], state: state, now: now)
    XCTAssertEqual(none, [])
  }

  func test_nonControllerAdverts_areIgnored() {
    var state = PhoneConnectorState()
    state.confirmed = ["B"]
    let plainDSUServer = DSUDiscoveredServer(name: "Cemu", address: "10.0.0.4", port: 26760, advert: nil)
    let actions = PhoneControllerConnector.actions(
      servers: [server(pid: "A", isController: false), server(pid: "B", isController: false), plainDSUServer],
      entries: [], state: state, now: now)
    XCTAssertEqual(actions, [])
  }

  // MARK: A row the user added by hand

  /// The owner added the phone by hand from the DSU list (named after its Bonjour name): it is already in,
  /// so it is neither asked about nor given a second row, which would seat it on two Wii Remotes.
  func test_manualRowAtThePhonesAddress_getsNoPromptAndNoSecondRow() {
    let manual = [entry("Joe's iPhone")]
    XCTAssertEqual(PhoneControllerConnector.actions(servers: [server(pid: "A")], entries: manual,
                                                    state: PhoneConnectorState(), now: now), [])
    var confirmed = PhoneConnectorState()
    confirmed.confirmed = ["A"]
    XCTAssertEqual(PhoneControllerConnector.actions(servers: [server(pid: "A")], entries: manual,
                                                    state: confirmed, now: now), [], "allowing it adds nothing either")
    // Same address, another port: a different server, so the phone still gets its own row.
    XCTAssertEqual(PhoneControllerConnector.actions(servers: [server(pid: "A")], entries: [entry("PC", port: 26761)],
                                                    state: confirmed, now: now),
                   [.add(pid: "A", entry: entry("Joe's iPhone"))])
  }

  /// Ownership is the whole row: a manual row with the owned row's name at another address is the user's.
  func test_ownedRow_isMatchedByAddressToo_notByNameAlone() {
    var state = PhoneConnectorState()
    state.confirmed = ["A"]
    state.owned = ["A": entry("Joe's iPhone")]
    let entries = [entry("Joe's iPhone", address: "10.0.0.9"), entry("Joe's iPhone")]

    let moved = server(pid: "A", address: "192.168.1.77")
    XCTAssertEqual(PhoneControllerConnector.actions(servers: [moved], entries: entries, state: state, now: now),
                   [.update(pid: "A", index: 1, entry: entry("Joe's iPhone", address: "192.168.1.77"))])

    state.lastSeen = ["A": now.addingTimeInterval(-60)]
    XCTAssertEqual(PhoneControllerConnector.actions(servers: [], entries: entries, state: state, now: now),
                   [.remove(pid: "A", index: 1)])

    // Only the manual row is left: nothing of ours to remove.
    XCTAssertEqual(PhoneControllerConnector.actions(servers: [], entries: [entries[0]], state: state, now: now), [])
  }

  /// The owned phone moves to an address a manual row already points at: its own row goes, not a duplicate.
  func test_ownedPhoneMovingOntoAManualRow_dropsItsOwnRow() {
    var state = PhoneConnectorState()
    state.confirmed = ["A"]
    state.owned = ["A": entry("Joe's iPhone")]
    let entries = [entry("Joe's iPhone"), entry("Desk", address: "192.168.1.77")]
    let moved = server(pid: "A", address: "192.168.1.77")
    XCTAssertEqual(PhoneControllerConnector.actions(servers: [moved], entries: entries, state: state, now: now),
                   [.remove(pid: "A", index: 0)])
  }

  func test_serverEquality_includesThePid() {
    XCTAssertNotEqual(server(pid: "A"), server(pid: "B"))
    XCTAssertEqual(server(pid: "A"), server(pid: "A"))
  }
}
