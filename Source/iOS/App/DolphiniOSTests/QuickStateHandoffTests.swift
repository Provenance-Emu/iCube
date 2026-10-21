import XCTest
@testable import iCube

@MainActor
final class QuickStateHandoffTests: XCTestCase {
  func testCompletionWaitsForNeutralThenFreshInputAndPreservesOtherHolders() {
    var paused = false
    let arbiter = PauseArbiter(core: .init(isRunning: { true }, isPaused: { paused },
      pause: { paused = true }, resume: { paused = false }), schedule: { $0() })
    let handoff = QuickStateHandoff(arbiter: arbiter, isCurrent: { _ in true })
    let session = QuickSaveSurfaceSession(gameID: "GALE01", identifier: 7)
    let overlay = arbiter.claim("overlay")
    let background = arbiter.claim(PauseArbiter.Reason.appInactive)
    var dismissals = 0
    let operation = handoff.begin(session: session) { dismissals += 1 }
    arbiter.release(overlay)
    handoff.sampleInput(active: true)
    handoff.sampleInput(active: false)
    XCTAssertTrue(paused)
    handoff.complete(operation)
    handoff.sampleInput(active: true) // Held/early press is never eligible.
    XCTAssertTrue(arbiter.holders.contains("quick-state-awaiting-input"))
    handoff.sampleInput(active: false)
    handoff.sampleInput(active: true)
    XCTAssertEqual(dismissals, 1)
    XCTAssertTrue(arbiter.holders.contains(PauseArbiter.Reason.appInactive))
    XCTAssertTrue(arbiter.holders.contains("quick-state-awaiting-input"))
    XCTAssertTrue(paused)
    arbiter.release(background)
    handoff.sampleInput(active: true)
    XCTAssertTrue(paused)
    handoff.sampleInput(active: false)
    handoff.sampleInput(active: true)
    XCTAssertFalse(paused)
  }

  func testPresentationInputCannotConsumeAwaitingHoldOrArmResumeAcrossDismissal() {
    let arbiter = PauseArbiter(core: .init(isRunning: { true }, isPaused: { true }, pause: {}, resume: {}))
    let handoff = QuickStateHandoff(arbiter: arbiter, isCurrent: { _ in true })
    let operation = handoff.begin(session: .init(gameID: "GALE01", identifier: 7), dismiss: {})
    handoff.complete(operation)
    handoff.sampleInput(active: false)
    let settings = arbiter.claim("settings")
    handoff.sampleInput(active: false)
    handoff.sampleInput(active: true)
    XCTAssertTrue(arbiter.holders.contains("quick-state-awaiting-input"))
    arbiter.release(settings)
    handoff.sampleInput(active: true) // The press that closed Settings is still down.
    XCTAssertTrue(arbiter.holders.contains("quick-state-awaiting-input"))
    handoff.sampleInput(active: false)
    handoff.sampleInput(active: true)
    XCTAssertFalse(arbiter.isHeld)
  }

  func testMenuHeldBlocksNeutralFenceAndGameplayActivationUntilAllControlsRelease() {
    let arbiter = PauseArbiter(core: .init(isRunning: { true }, isPaused: { true }, pause: {}, resume: {}))
    let handoff = QuickStateHandoff(arbiter: arbiter, isCurrent: { _ in true })
    let operation = handoff.begin(session: .init(gameID: "GALE01", identifier: 7), dismiss: {})
    handoff.complete(operation)
    handoff.sampleInput(active: false, controlsNeutral: false, activationBlocked: true)
    handoff.sampleInput(active: true, controlsNeutral: false, activationBlocked: true)
    XCTAssertTrue(arbiter.isHeld)
    handoff.sampleInput(active: true, controlsNeutral: false, activationBlocked: false)
    XCTAssertTrue(arbiter.isHeld, "Releasing Menu while A remains held is not fresh input")
    handoff.sampleInput(active: false, controlsNeutral: true)
    handoff.sampleInput(active: true, controlsNeutral: false)
    XCTAssertFalse(arbiter.isHeld)
  }

  func testReplacedSessionDropsOnlyItsOwnTokens() {
    var current = true
    let arbiter = PauseArbiter(core: .init(isRunning: { true }, isPaused: { true }, pause: {}, resume: {}))
    let handoff = QuickStateHandoff(arbiter: arbiter, isCurrent: { _ in current })
    let unrelated = arbiter.claim("settings")
    let operation = handoff.begin(session: .init(gameID: "GALE01", identifier: 7), dismiss: {})
    current = false
    handoff.complete(operation)
    XCTAssertEqual(arbiter.holders, [unrelated.reason])
  }
}
