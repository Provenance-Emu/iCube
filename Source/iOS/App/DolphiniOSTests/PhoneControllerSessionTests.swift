// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import XCTest
@testable import iCube

/// Stands in for the live pointer mode, which writes the Dolphin config.
@MainActor
private final class FakePointerMode {
  var mode: PointerMode
  init(_ mode: PointerMode) { self.mode = mode }
  var access: PhoneControllerSession.PointerModeAccess {
    .init(read: { self.mode }, write: { self.mode = $0 })
  }
}

@MainActor
final class PhoneControllerSessionTests: XCTestCase {
  private let tv = "192.168.1.50"
  private let tvAddress = "192.168.1.50:49152"
  private var defaults: UserDefaults!
  private var pointer: FakePointerMode!
  private let savedTimeout = PhoneControllerSession.presentationTimeout

  override func setUp() {
    super.setUp()
    defaults = UserDefaults(suiteName: "PhoneControllerSessionTests")!
    defaults.removePersistentDomain(forName: "PhoneControllerSessionTests")
    pointer = FakePointerMode(.touchFollow)
    DSUServerBridge.setApprovalRequired(false)
    DSUServerBridge.setRestrictToClient(nil)
  }

  override func tearDown() {
    end()
    PhoneControllerSession.presentationTimeout = savedTimeout
    DSUServerBridge.setApprovalRequired(false)
    DSUServerBridge.setRestrictToClient(nil)
    DSUServerBridge.setClient(tv, allowed: false)
    defaults.removePersistentDomain(forName: "PhoneControllerSessionTests")
    super.tearDown()
  }

  private func begin(serverRunning: Bool = false) {
    PhoneControllerSession.apply(PhoneControllerSession.configuration(pid: "PEER-1", name: "Phone"),
                                 defaults: defaults, pointerMode: pointer.access, serverRunning: serverRunning)
  }

  private func end() {
    PhoneControllerSession.end(defaults: defaults, pointerMode: pointer.access)
  }

  // MARK: - Configuration and routing

  func test_configuration_isWiiRemoteGyroApprovalRequiredController() {
    let config = PhoneControllerSession.configuration(pid: "PEER-1", name: "Joe's iPhone")

    XCTAssertEqual(config.layout, "wiiRemote")
    XCTAssertEqual(config.pointerMode, .gyro)
    XCTAssertTrue(config.approvalRequired)
    XCTAssertEqual(config.advert.pid, "PEER-1")
    XCTAssertEqual(config.advert.name, "Joe's iPhone")
    XCTAssertTrue(config.advert.isController)
    let expectedType = UIDevice.current.userInterfaceIdiom == .pad ? "pd" : "ip"
    XCTAssertEqual(config.advert.deviceType, expectedType)
    XCTAssertEqual(config.advert.txtRecord()["role"], "controller")
  }

  func test_router_opensTheControllerSession_forTheDSUControllerURL() {
    let router = URLRouterService()
    let began = expectation(description: "controller session begins")
    router.beginPhoneControllerSession = { began.fulfill() }

    let handled = router.application(UIApplication.shared, open: URL(string: "dolphinios://dsu/controller")!)

    XCTAssertTrue(handled)
    wait(for: [began], timeout: 2)
  }

  func test_router_leavesTheAddRouteToTheDSUServerList() {
    let router = URLRouterService()
    router.beginPhoneControllerSession = { XCTFail("dsu/add must not start a controller session") }

    // No ip/port: the add route declines it, and the controller route must not claim it.
    XCTAssertFalse(router.application(UIApplication.shared, open: URL(string: "dolphinios://dsu/add")!))
  }

  // MARK: - Approval

  func test_approvingTheTV_permitsItForTheSessionOnly_andRestrictsToIt() {
    begin()

    PhoneControllerSession.approve(address: tvAddress)

    XCTAssertTrue(DSUServerBridge.isClientPermitted(tv))
    XCTAssertEqual(DSUServerBridge.restrictedClient(), tv)
    XCTAssertFalse(DSUServerBridge.isClientAllowed(tv), "the one-tap approval never reaches the persisted allowlist")
    XCTAssertFalse(DSUServerBridge.allowedClients().contains(tv))
  }

  func test_blockingTheTV_doesNotPermitOrRestrict() {
    begin()

    PhoneControllerSession.block(address: tvAddress)

    XCTAssertFalse(DSUServerBridge.isClientPermitted(tv))
    XCTAssertNil(DSUServerBridge.restrictedClient())
  }

  func test_aTVTheUserAlwaysAllowed_isStillAskedInASession() {
    DSUServerBridge.setClient(tv, allowed: true)
    begin()

    XCTAssertFalse(DSUServerBridge.isClientPermitted(tv))
    XCTAssertTrue(DSUServerBridge.shouldPrompt(forClientIP: tv))
    end()
    XCTAssertTrue(DSUServerBridge.isClientAllowed(tv), "the user's own allowlist is untouched")
  }

  func test_theSameTVIsAskedAgainInTheNextSession() {
    begin()
    XCTAssertTrue(DSUServerBridge.shouldPrompt(forClientIP: tv))
    XCTAssertFalse(DSUServerBridge.shouldPrompt(forClientIP: tv), "asked once per session")
    PhoneControllerSession.approve(address: tvAddress)
    end()

    begin()

    XCTAssertFalse(DSUServerBridge.isClientPermitted(tv), "the last session's approval is gone")
    XCTAssertTrue(DSUServerBridge.shouldPrompt(forClientIP: tv), "so the TV is asked again")
  }

  func test_reassertingTheRestriction_putsTheApprovedTVBack() {
    begin()
    PhoneControllerSession.approve(address: tvAddress)

    DSUServerBridge.setRestrictToClient("10.0.0.9")
    PhoneControllerSession.reassertRestriction()

    XCTAssertEqual(DSUServerBridge.restrictedClient(), tv)
  }

  func test_reassertingTheRestriction_beforeAnApproval_changesNothing() {
    begin()
    DSUServerBridge.setRestrictToClient("10.0.0.9")

    PhoneControllerSession.reassertRestriction()

    XCTAssertEqual(DSUServerBridge.restrictedClient(), "10.0.0.9")
  }

  // MARK: - Settings snapshot

  func test_applying_changesTheSettingsAndPersistsTheSnapshot() {
    DSUServerBridge.setApprovalRequired(false)
    defaults.set("gamecube", forKey: DSUControllerLayout.storageKey)

    begin()

    XCTAssertTrue(DSUServerBridge.approvalRequired())
    XCTAssertEqual(defaults.string(forKey: DSUControllerLayout.storageKey), "wiiRemote")
    XCTAssertEqual(pointer.mode, .gyro)
    XCTAssertEqual(PhoneControllerSession.Snapshot.load(from: defaults),
                   .init(approvalRequired: false, layout: "gamecube", pointerMode: PointerMode.touchFollow.rawValue,
                         serverWasRunning: false))
  }

  func test_ending_restoresTheSettingsAndClearsTheSnapshot() {
    defaults.set("gamecube", forKey: DSUControllerLayout.storageKey)
    DSUServerBridge.setRestrictToClient("10.0.0.9")
    begin()
    PhoneControllerSession.approve(address: tvAddress)

    end()

    XCTAssertFalse(DSUServerBridge.approvalRequired())
    XCTAssertEqual(defaults.string(forKey: DSUControllerLayout.storageKey), "gamecube")
    XCTAssertEqual(pointer.mode, .touchFollow)
    XCTAssertEqual(DSUServerBridge.restrictedClient(), "10.0.0.9")
    XCTAssertFalse(DSUServerBridge.isClientPermitted(tv))
    XCTAssertNil(PhoneControllerSession.Snapshot.load(from: defaults))
  }

  func test_ending_removesALayoutTheUserNeverSet() {
    begin()
    XCTAssertEqual(defaults.string(forKey: DSUControllerLayout.storageKey), "wiiRemote")

    end()

    XCTAssertNil(defaults.object(forKey: DSUControllerLayout.storageKey))
  }

  func test_aSecondApply_keepsTheUsersOriginalSnapshot() {
    defaults.set("gamecube", forKey: DSUControllerLayout.storageKey)
    begin()
    begin()

    end()

    XCTAssertEqual(defaults.string(forKey: DSUControllerLayout.storageKey), "gamecube")
    XCTAssertEqual(pointer.mode, .touchFollow)
  }

  func test_aKilledSession_isPutRightAtTheNextLaunch() {
    defaults.set("gamecube", forKey: DSUControllerLayout.storageKey)
    begin() // the app dies here: end() never runs
    XCTAssertTrue(DSUServerBridge.approvalRequired())

    let restored = PhoneControllerSession.restoreStaleSnapshot(defaults: defaults, pointerMode: pointer.access)

    XCTAssertTrue(restored)
    XCTAssertFalse(DSUServerBridge.approvalRequired())
    XCTAssertEqual(defaults.string(forKey: DSUControllerLayout.storageKey), "gamecube")
    XCTAssertEqual(pointer.mode, .touchFollow)
    XCTAssertNil(PhoneControllerSession.Snapshot.load(from: defaults))
    XCTAssertFalse(PhoneControllerSession.restoreStaleSnapshot(defaults: defaults, pointerMode: pointer.access),
                   "nothing left to restore")
  }

  func test_launchWithoutAStaleSnapshot_changesNothing() {
    DSUServerBridge.setApprovalRequired(true)
    pointer.mode = .touchDrag

    XCTAssertFalse(PhoneControllerSession.restoreStaleSnapshot(defaults: defaults, pointerMode: pointer.access))

    XCTAssertTrue(DSUServerBridge.approvalRequired())
    XCTAssertEqual(pointer.mode, .touchDrag)
  }

  // MARK: - The DSU server

  func test_aServerAlreadyRunning_isRecordedInTheSnapshot() {
    begin(serverRunning: true)
    XCTAssertEqual(PhoneControllerSession.Snapshot.load(from: defaults)?.serverWasRunning, true)
  }

  func test_aSecondApply_keepsWhetherTheServerWasRunningBeforeTheSession() {
    begin(serverRunning: false)
    begin(serverRunning: true) // the session's own server is up by now
    XCTAssertEqual(PhoneControllerSession.Snapshot.load(from: defaults)?.serverWasRunning, false)
  }

  /// Leaving stops the server the session started, and leaves one the user had running.
  func test_leaving_stopsOnlyAServerTheSessionStarted() {
    typealias Snapshot = PhoneControllerSession.Snapshot
    let started = Snapshot(approvalRequired: false, layout: nil, pointerMode: nil, serverWasRunning: false)
    let usersOwn = Snapshot(approvalRequired: false, layout: nil, pointerMode: nil, serverWasRunning: true)
    let older = Snapshot(approvalRequired: false, layout: nil, pointerMode: nil, serverWasRunning: nil)
    XCTAssertTrue(PhoneControllerSession.stopsServerOnEnd(snapshot: started))
    XCTAssertFalse(PhoneControllerSession.stopsServerOnEnd(snapshot: usersOwn))
    XCTAssertFalse(PhoneControllerSession.stopsServerOnEnd(snapshot: older), "unknown: leave it as it is")
    XCTAssertFalse(PhoneControllerSession.stopsServerOnEnd(snapshot: nil), "no session ran: touch nothing")
  }

  /// A server already up is published again on its own port, so a TV re-resolves the controller record.
  func test_appearing_startsAServer_orRestartsTheRunningOneOnItsPort() {
    XCTAssertEqual(PhoneControllerSession.serverStart(serverRunning: false, runningPort: 0), .start)
    XCTAssertEqual(PhoneControllerSession.serverStart(serverRunning: true, runningPort: 26770), .restart(port: 26770))
  }

  /// A snapshot written before the server flag existed still loads, so its settings are still restored.
  func test_aSnapshotWithoutTheServerFlag_stillLoads() throws {
    let json = #"{"approvalRequired":false,"layout":"gamecube","pointerMode":1}"#
    defaults.set(Data(json.utf8), forKey: PhoneControllerSession.Snapshot.defaultsKey)
    let snapshot = try XCTUnwrap(PhoneControllerSession.Snapshot.load(from: defaults))
    XCTAssertEqual(snapshot.layout, "gamecube")
    XCTAssertNil(snapshot.serverWasRunning)
  }

  // MARK: - Presentation

  func test_aControllerScreenThatNeverAppears_leavesTheSessionInactiveAndRetryable() async throws {
    PhoneControllerSession.presentationTimeout = .milliseconds(50)
    let presentation = PhoneControllerSession.Presentation() // not the library's: nothing presents

    PhoneControllerSession.begin(presentation: presentation)
    XCTAssertTrue(presentation.isRequested)
    XCTAssertFalse(presentation.isActive)
    XCTAssertFalse(DSUServerBridge.approvalRequired(), "nothing is applied until the screen appears")
    XCTAssertNil(PhoneControllerSession.Snapshot.load(from: .standard))

    for _ in 0..<40 where presentation.isRequested { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertFalse(presentation.isRequested, "the refused request is dropped")

    PhoneControllerSession.begin(presentation: presentation)
    XCTAssertTrue(presentation.isRequested, "so the next tap can try again")
  }
}
#endif
