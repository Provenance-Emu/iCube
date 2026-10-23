// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

/// Mirrors the live writer: an update is a remove followed by an append, so the row moves to the end.
private final class FakeDSUConfigWriter: DSUConfigWriting {
  var rows: [DSUEntry]
  var enabled = false

  init(rows: [DSUEntry] = []) { self.rows = rows }

  func entries() -> [DSUEntry] { rows }
  func add(_ entry: DSUEntry) { rows.append(entry) }
  func update(at index: Int, to entry: DSUEntry) {
    rows.remove(at: index)
    rows.append(entry)
  }
  func remove(at index: Int) { rows.remove(at: index) }
  func setEnabled(_ enabled: Bool) { self.enabled = enabled }
}

@MainActor
final class PhoneControllerServiceTests: XCTestCase {
  private let suiteName = "PhoneControllerServiceTests"
  private var defaults: UserDefaults!
  private var clock = Date(timeIntervalSince1970: 1_000_000)

  override func setUp() {
    super.setUp()
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    super.tearDown()
  }

  private func makeService(writer: FakeDSUConfigWriter) -> PhoneControllerService {
    PhoneControllerService(writer: writer, defaults: defaults, now: { [unowned self] in self.clock })
  }

  private func phone(pid: String, name: String = "Joe's iPhone", address: String = "192.168.1.20",
                     port: Int = 26760, isController: Bool = true) -> DSUDiscoveredServer {
    DSUDiscoveredServer(name: name, address: address, port: port,
                        advert: DSUAdvert(pid: pid, name: name, deviceType: "iPhone", isController: isController))
  }

  /// The texts posted as toasts while `body` runs.
  private func toasts(during body: () -> Void) -> [String] {
    var seen: [String] = []
    let token = NotificationCenter.default.addObserver(forName: .dolShowSnackbar, object: nil, queue: nil) { note in
      seen.append(note.userInfo?[EmulationToast.textKey] as? String ?? "")
    }
    defer { NotificationCenter.default.removeObserver(token) }
    body()
    return seen
  }

  // MARK: Brief

  func test_allow_addsEntryEnablesClientAndToasts() {
    let writer = FakeDSUConfigWriter()
    let service = makeService(writer: writer)
    service.refresh(servers: [phone(pid: "A")])
    XCTAssertEqual(service.pendingPrompt?.pid, "A")
    XCTAssertEqual(service.pendingPrompt?.name, "Joe's iPhone")
    XCTAssertTrue(writer.rows.isEmpty, "nothing connects before the user answers")

    let seen = toasts { service.respond(pid: "A", allow: true) }

    XCTAssertNil(service.pendingPrompt)
    XCTAssertEqual(writer.rows, [DSUEntry(description: "Joe's iPhone", address: "192.168.1.20", port: 26760)])
    XCTAssertTrue(writer.enabled)
    XCTAssertEqual(seen, [String(format: L("%@ is connected as a controller"), "Joe's iPhone")])
    XCTAssertEqual(defaults.dictionary(forKey: PhoneControllerService.ownedEntriesKey) as? [String: String],
                   ["A": "Joe's iPhone"], "the owned entry persists so a crash-left entry is cleaned up")
  }

  func test_notNow_marksDeclined_andAddsNothing() {
    let writer = FakeDSUConfigWriter()
    let service = makeService(writer: writer)
    service.refresh(servers: [phone(pid: "A")])
    service.respond(pid: "A", allow: false)
    service.refresh(servers: [phone(pid: "A")])

    XCTAssertNil(service.pendingPrompt, "not asked again this launch")
    XCTAssertTrue(writer.rows.isEmpty)
    XCTAssertFalse(writer.enabled)
  }

  /// A phone that changed address is updated and one that left is removed; the user's own servers
  /// are never touched, even though the update moves a row and shifts the indices after it.
  func test_executor_appliesUpdateAndRemove_toOwnedEntriesOnly() {
    let pc = DSUEntry(description: "PC", address: "192.168.1.5", port: 26760)
    let other = DSUEntry(description: "Other", address: "192.168.1.6", port: 26760)
    let writer = FakeDSUConfigWriter(rows: [pc, other])
    let service = makeService(writer: writer)
    service.connect(pid: "A")
    service.connect(pid: "B")
    service.refresh(servers: [phone(pid: "A", name: "Joe's iPhone", address: "192.168.1.20"),
                              phone(pid: "B", name: "Ann's iPhone", address: "192.168.1.21")])
    XCTAssertEqual(writer.rows.map(\.description), ["PC", "Other", "Joe's iPhone", "Ann's iPhone"])
    // Put a manual row between them so A sits below B with one of the user's rows after each.
    writer.rows = [pc, DSUEntry(description: "Joe's iPhone", address: "192.168.1.20", port: 26760),
                   other, DSUEntry(description: "Ann's iPhone", address: "192.168.1.21", port: 26760)]

    // A moves to a new address; B stops advertising and stays gone past the grace period.
    service.refresh(servers: [phone(pid: "A", name: "Joe's iPhone", address: "192.168.1.30")])
    clock += PhoneControllerConnector.departureGrace + 1
    service.refresh(servers: [phone(pid: "A", name: "Joe's iPhone", address: "192.168.1.30")])

    XCTAssertEqual(Set(writer.rows.map(\.description)), ["PC", "Other", "Joe's iPhone"])
    XCTAssertEqual(writer.rows.first { $0.description == "Joe's iPhone" }?.address, "192.168.1.30")
    XCTAssertEqual(writer.rows.first { $0.description == "PC" }, pc)
    XCTAssertEqual(writer.rows.first { $0.description == "Other" }, other)
  }

  /// Update at a lower index than a remove in ONE batch: the remove must still hit the departed phone.
  func test_updateAndRemoveInOneBatch_removeHitsTheDepartedPhone() {
    let pc = DSUEntry(description: "PC", address: "192.168.1.5", port: 26760)
    let writer = FakeDSUConfigWriter()
    let service = makeService(writer: writer)
    service.connect(pid: "A")
    service.connect(pid: "B")
    service.refresh(servers: [phone(pid: "A", name: "Joe's iPhone", address: "192.168.1.20"),
                              phone(pid: "B", name: "Ann's iPhone", address: "192.168.1.21")])
    writer.rows.append(pc)
    // B leaves while A is still there, and A changes address in the same refresh, after the grace.
    service.refresh(servers: [phone(pid: "A", name: "Joe's iPhone", address: "192.168.1.20")])
    clock += PhoneControllerConnector.departureGrace + 1
    service.refresh(servers: [phone(pid: "A", name: "Joe's iPhone", address: "192.168.1.30")])

    XCTAssertEqual(writer.rows.map(\.description).sorted(), ["Joe's iPhone", "PC"])
    XCTAssertEqual(writer.rows.first { $0.description == "Joe's iPhone" }?.address, "192.168.1.30")
  }

  // MARK: Prompting

  func test_prompt_isShownOnce_andTheNextPhoneWaitsItsTurn() {
    let service = makeService(writer: FakeDSUConfigWriter())
    let servers = [phone(pid: "A"), phone(pid: "B", name: "Ann's iPhone", address: "192.168.1.21")]
    service.refresh(servers: servers)
    service.refresh(servers: servers)
    XCTAssertEqual(service.pendingPrompt?.pid, "A")
    service.respond(pid: "A", allow: false)
    XCTAssertEqual(service.pendingPrompt?.pid, "B")
    XCTAssertEqual(service.pendingPrompt?.name, "Ann's iPhone")
  }

  func test_prompt_isWithdrawn_whenThePhoneStopsAdvertising() {
    let service = makeService(writer: FakeDSUConfigWriter())
    service.refresh(servers: [phone(pid: "A")])
    service.refresh(servers: [])
    XCTAssertNil(service.pendingPrompt)
  }

  /// The phone being asked leaves while another waits: the waiting one is asked in the same refresh.
  func test_waitingPhone_isAsked_whenThePhoneBeingAskedLeaves() {
    let service = makeService(writer: FakeDSUConfigWriter())
    let a = phone(pid: "A", name: "Ann's iPhone", address: "192.168.1.21")
    let b = phone(pid: "B", name: "Bob's iPhone", address: "192.168.1.22")
    service.refresh(servers: [b, a])
    XCTAssertEqual(service.pendingPrompt?.pid, "B")
    service.refresh(servers: [a])
    XCTAssertEqual(service.pendingPrompt?.pid, "A")
    XCTAssertEqual(service.pendingPrompt?.name, "Ann's iPhone")
  }

  func test_connect_addsWithoutAPrompt() {
    let writer = FakeDSUConfigWriter()
    let service = makeService(writer: writer)
    service.refresh(servers: [phone(pid: "A")])
    XCTAssertEqual(service.pendingPrompt?.pid, "A")
    service.connect(pid: "A")
    XCTAssertNil(service.pendingPrompt)
    XCTAssertEqual(writer.rows.map(\.description), ["Joe's iPhone"])
  }

  func test_advertisingPhones_listsControllerPhonesOnce() {
    let service = makeService(writer: FakeDSUConfigWriter())
    service.refresh(servers: [phone(pid: "A"), phone(pid: "A"), phone(pid: "B", isController: false),
                              DSUDiscoveredServer(name: "PC", address: "192.168.1.5", port: 26760)])
    XCTAssertEqual(service.advertisingPhones.map { $0.advert?.pid }, ["A"])
  }

  // MARK: Trust model

  func test_launchCleanup_removesEveryOwnedEntry_once() {
    let pc = DSUEntry(description: "PC", address: "192.168.1.5", port: 26760)
    let writer = FakeDSUConfigWriter(rows: [DSUEntry(description: "Joe's iPhone", address: "192.168.1.20", port: 26760), pc])
    defaults.set(["A": "Joe's iPhone"], forKey: PhoneControllerService.ownedEntriesKey)
    let service = makeService(writer: writer)
    service.removeEntriesLeftByAnEarlierLaunch()
    XCTAssertEqual(writer.rows, [pc])
    XCTAssertEqual(defaults.dictionary(forKey: PhoneControllerService.ownedEntriesKey) as? [String: String], [:])

    // A phone owned later in this launch survives a second call (scene phase restarts the service).
    service.connect(pid: "A")
    service.refresh(servers: [phone(pid: "A")])
    service.removeEntriesLeftByAnEarlierLaunch()
    XCTAssertEqual(writer.rows.map(\.description), ["PC", "Joe's iPhone"])
  }

  func test_notNow_removesAnOwnedEntry() {
    let writer = FakeDSUConfigWriter()
    let service = makeService(writer: writer)
    service.connect(pid: "A")
    service.refresh(servers: [phone(pid: "A")])
    XCTAssertEqual(writer.rows.count, 1)
    service.respond(pid: "A", allow: false)
    XCTAssertTrue(writer.rows.isEmpty)
  }

  /// The user deleted the phone's row in DSU settings: it is not re-added behind their back.
  func test_userDeletedEntry_isNotReAdded() {
    let writer = FakeDSUConfigWriter()
    let service = makeService(writer: writer)
    service.connect(pid: "A")
    service.refresh(servers: [phone(pid: "A")])
    writer.rows.removeAll()
    service.refresh(servers: [phone(pid: "A")])
    service.refresh(servers: [phone(pid: "A")])
    XCTAssertTrue(writer.rows.isEmpty)
    XCTAssertNil(service.pendingPrompt)
    XCTAssertEqual(defaults.dictionary(forKey: PhoneControllerService.ownedEntriesKey) as? [String: String], [:])
  }

  /// A brief gap shorter than the grace keeps the entry, even when the phone was last seen long ago.
  func test_departure_waitsForTheGrace_fromWhenThePhoneWasLastSeen() {
    let writer = FakeDSUConfigWriter()
    let service = makeService(writer: writer)
    service.connect(pid: "A")
    service.refresh(servers: [phone(pid: "A")])
    clock += 600
    service.refresh(servers: [phone(pid: "A")])  // a tick while it is still there
    service.refresh(servers: [])
    clock += PhoneControllerConnector.departureGrace - 1
    service.refresh(servers: [])
    XCTAssertEqual(writer.rows.count, 1)
    clock += 2
    service.refresh(servers: [])
    XCTAssertTrue(writer.rows.isEmpty)
  }

  /// `DOLConfigBridge` stores rows as `desc:address:port;` and strips `@`: a name holding those
  /// characters must not break the row or lose track of it.
  func test_nameWithSeparators_isStoredSafely_andStillTracked() {
    let writer = FakeDSUConfigWriter()
    let service = makeService(writer: writer)
    service.connect(pid: "A")
    service.refresh(servers: [phone(pid: "A", name: "Joe: iPhone;@home")])
    XCTAssertEqual(writer.rows.count, 1)
    let description = writer.rows[0].description
    XCTAssertFalse(description.contains(":") || description.contains(";") || description.contains("@"))
    clock += PhoneControllerConnector.departureGrace + 1
    service.refresh(servers: [])
    XCTAssertTrue(writer.rows.isEmpty, "the sanitized row is still the one the service owns")
  }
}
