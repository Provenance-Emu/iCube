// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class UserStopRequestTests: XCTestCase {
  func test_failedSaveAndQuit_keepsSessionOpenAndReportsFailure() {
    var calls: [String] = []
    UserStopRequest.saveAndQuit(save: { nil }, quit: { calls.append("quit:\($0)") }, failed: { calls.append("failed") })
    XCTAssertEqual(calls, ["failed"])
  }

  func test_successfulSaveAndQuit_reusesTheConfirmedPathExactlyOnce() {
    var calls: [String] = []
    UserStopRequest.saveAndQuit(save: { "/GALE01.s01" }, quit: { calls.append("quit:\($0)") }, failed: { calls.append("failed") })
    XCTAssertEqual(calls, ["quit:/GALE01.s01"])
  }

  func test_saveFailureRecovery_defaultsToCancel_andDiscardIsExplicit() {
    var calls: [String] = []
    let model = UserQuitFailureModelBuilder.make(cancel: { calls.append("cancel") }, retry: { calls.append("retry") },
                                                quitWithoutSaving: { calls.append("discard") })
    XCTAssertEqual(model.focusableIDs.first, "quit-failure-cancel")
    model.item(id: "quit-failure-cancel")?.activateInPlace()
    model.item(id: "quit-failure-retry")?.activateInPlace()
    model.item(id: "quit-without-saving")?.activateInPlace()
    XCTAssertEqual(calls, ["cancel", "retry", "discard"])
  }

  func test_defaultRequestsConfirmationWithoutStopping() {
    var calls: [String] = []
    UserStopRequest.handle(confirm: { calls.append("confirm") }, stop: { calls.append("stop") })
    XCTAssertEqual(calls, ["confirm"])
  }

  func test_enabledPreferenceRequestsConfirmationWithoutStopping() {
    var calls: [String] = []
    UserStopRequest.handle(confirmOnStop: true, confirm: { calls.append("confirm") }, stop: { calls.append("stop") })
    XCTAssertEqual(calls, ["confirm"])
  }

  func test_disabledPreferenceStopsExactlyOnceWithoutConfirmation() {
    var calls: [String] = []
    UserStopRequest.handle(confirmOnStop: false, confirm: { calls.append("confirm") }, stop: { calls.append("stop") })
    XCTAssertEqual(calls, ["stop"])
  }
}
