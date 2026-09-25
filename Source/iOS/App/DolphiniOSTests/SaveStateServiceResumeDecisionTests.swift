// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

/// Covers `SaveStateService.resumeDecision(...)`, the pure precedence table behind
/// `resumeOrBootIntoPendingState()`. It takes an explicit snapshot of the flags/files
/// instead of reading `TVEmulationBridge`/`UserDefaults` live, so every combination —
/// including the regression this file exists for (D12: "Start Fresh" must not resume
/// the last auto-save) — can be exercised without a running core.
final class SaveStateServiceResumeDecisionTests: XCTestCase {
  private func decide(
    watchdogArmed: Bool = false,
    pendingBootStatePath: String? = nil,
    pendingStateExists: Bool = false,
    skipResumeOnce: Bool = false,
    resumeEnabled: Bool = false,
    autoStatePath: String? = nil,
    autoStateExists: Bool = false
  ) -> SaveStateService.ResumeDecision {
    SaveStateService.resumeDecision(
      watchdogArmed: watchdogArmed,
      pendingBootStatePath: pendingBootStatePath,
      pendingStateExists: pendingStateExists,
      skipResumeOnce: skipResumeOnce,
      resumeEnabled: resumeEnabled,
      autoStatePath: autoStatePath,
      autoStateExists: autoStateExists
    )
  }

  // MARK: - D12 regression: "Start Fresh (Skip Resume)" must never resume

  func testSkipResumeOnceWinsEvenWhenAutoStateExists() {
    // This is the exact D12 scenario: resume is on, the game has an auto-save,
    // and the user asked to boot fresh. The auto-state must NOT be loaded.
    let decision = decide(skipResumeOnce: true, resumeEnabled: true, autoStatePath: "/x/GAME01.auto", autoStateExists: true)
    XCTAssertEqual(decision, .skipOnce)
  }

  func testSkipResumeOnceWinsEvenWithoutResumeEnabled() {
    let decision = decide(skipResumeOnce: true, resumeEnabled: false)
    XCTAssertEqual(decision, .skipOnce)
  }

  // MARK: - Normal resume behavior must be unaffected

  func testNormalPlayLoadsAutoStateWhenResumeEnabledAndStateExists() {
    let decision = decide(resumeEnabled: true, autoStatePath: "/x/GAME01.auto", autoStateExists: true)
    XCTAssertEqual(decision, .loadAuto(path: "/x/GAME01.auto"))
  }

  func testNormalPlayDoesNothingWhenResumeDisabled() {
    let decision = decide(resumeEnabled: false, autoStatePath: "/x/GAME01.auto", autoStateExists: true)
    XCTAssertEqual(decision, .none)
  }

  func testNormalPlayDoesNothingWhenNoAutoStateFileExists() {
    let decision = decide(resumeEnabled: true, autoStatePath: "/x/GAME01.auto", autoStateExists: false)
    XCTAssertEqual(decision, .none)
  }

  // MARK: - Precedence: requested state > skip-once > resume

  func testPendingBootStateBeatsResumeEnabled() {
    let decision = decide(pendingBootStatePath: "/x/GAME01.s01", pendingStateExists: true, resumeEnabled: true, autoStatePath: "/x/GAME01.auto", autoStateExists: true)
    XCTAssertEqual(decision, .loadPending(path: "/x/GAME01.s01"))
  }

  func testPendingBootStateBeatsSkipResumeOnce() {
    // A requested numbered-slot boot is a stronger signal than the generic
    // one-shot skip flag, and matches the pre-refactor precedence order.
    let decision = decide(pendingBootStatePath: "/x/GAME01.s01", pendingStateExists: true, skipResumeOnce: true)
    XCTAssertEqual(decision, .loadPending(path: "/x/GAME01.s01"))
  }

  func testMissingPendingStateFileDeclinesInsteadOfFallingBackToAuto() {
    // The requested file vanished from disk; do not silently fall back to auto-resume.
    let decision = decide(pendingBootStatePath: "/x/GAME01.s01", pendingStateExists: false, resumeEnabled: true, autoStatePath: "/x/GAME01.auto", autoStateExists: true)
    XCTAssertEqual(decision, .none)
  }

  // MARK: - Watchdog beats everything

  func testWatchdogBeatsPendingState() {
    let decision = decide(watchdogArmed: true, pendingBootStatePath: "/x/GAME01.s01", pendingStateExists: true)
    XCTAssertEqual(decision, .declineWatchdog)
  }

  func testWatchdogBeatsSkipResumeOnce() {
    let decision = decide(watchdogArmed: true, skipResumeOnce: true)
    XCTAssertEqual(decision, .declineWatchdog)
  }

  func testWatchdogBeatsAutoResume() {
    let decision = decide(watchdogArmed: true, resumeEnabled: true, autoStatePath: "/x/GAME01.auto", autoStateExists: true)
    XCTAssertEqual(decision, .declineWatchdog)
  }
}
