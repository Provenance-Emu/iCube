// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import XCTest
@testable import iCube

@MainActor
final class PhoneControllerSessionTests: XCTestCase {
  override func tearDown() {
    PhoneControllerSession.end()
    DSUServerBridge.setApprovalRequired(false)
    DSUServerBridge.setRestrictToClient(nil)
    DSUServerBridge.setClient("192.168.1.50", allowed: false)
    super.tearDown()
  }

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

  func test_approvingTheTV_allowsItAndRestrictsTheSessionToIt() {
    DSUServerBridge.setRestrictToClient(nil)

    PhoneControllerSession.approve(address: "192.168.1.50:49152")

    XCTAssertTrue(DSUServerBridge.isClientAllowed("192.168.1.50"))
    XCTAssertEqual(DSUServerBridge.restrictedClient(), "192.168.1.50")
  }

  func test_blockingTheTV_doesNotAllowOrRestrict() {
    DSUServerBridge.setRestrictToClient(nil)

    PhoneControllerSession.block(address: "192.168.1.50:49152")

    XCTAssertFalse(DSUServerBridge.isClientAllowed("192.168.1.50"))
    XCTAssertNil(DSUServerBridge.restrictedClient())
  }

  func test_ending_restoresTheApprovalSettingAndForgetsTheTV() {
    DSUServerBridge.setApprovalRequired(false)
    PhoneControllerSession.apply(PhoneControllerSession.configuration(pid: "PEER-1", name: "Phone"))
    XCTAssertTrue(DSUServerBridge.approvalRequired())
    PhoneControllerSession.approve(address: "192.168.1.50:49152")

    PhoneControllerSession.end()

    XCTAssertFalse(DSUServerBridge.approvalRequired(), "the approval setting the user had comes back")
    XCTAssertNil(DSUServerBridge.restrictedClient())
    XCTAssertFalse(DSUServerBridge.isClientAllowed("192.168.1.50"), "a one-tap approval does not outlive the session")
  }

  func test_ending_keepsATVTheUserAlreadyAlwaysAllowed() {
    DSUServerBridge.setClient("192.168.1.50", allowed: true)
    PhoneControllerSession.apply(PhoneControllerSession.configuration(pid: "PEER-1", name: "Phone"))
    PhoneControllerSession.approve(address: "192.168.1.50:49152")

    PhoneControllerSession.end()

    XCTAssertTrue(DSUServerBridge.isClientAllowed("192.168.1.50"))
  }
}
#endif
