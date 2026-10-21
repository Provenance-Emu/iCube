import GameController
#if os(iOS)
import UIKit
#endif
import XCTest
@testable import iCube

@MainActor
final class QuickStateInputSamplingTests: XCTestCase {
  private final class Profile: GCPhysicalInputProfile {
    let a = SynthesizedButtonInput()
    let menu = SynthesizedButtonInput()
    let stick = SynthesizedDirectionPad()
    override var elements: [String: GCControllerElement] { ["A": a, "Start": menu, "Joystick": stick] }
    override var buttons: [String: GCControllerButtonInput] { ["A": a, "Start": menu] }
    override var axes: [String: GCControllerAxisInput] { ["X": stick.xAxis, "Y": stick.yAxis] }
  }
  private final class ProfileOnlyController: GCController {
    let profile = Profile()
    override var extendedGamepad: GCExtendedGamepad? { nil }
    override var microGamepad: GCMicroGamepad? { nil }
    override var physicalInputProfile: GCPhysicalInputProfile { profile }
    override var vendorName: String? { "N64 Controller" }
    override var productCategory: String { "Nintendo N64" }
  }

  func testPhysicalProfileOnlyPadUsesRealNormalizedWrapperForFreshResume() {
    let raw = ProfileOnlyController()
    XCTAssertNil(raw.extendedGamepad)
    XCTAssertNil(raw.microGamepad)
    let normalized = PhysicalProfileController(wrapping: raw)
    let arbiter = PauseArbiter(core: .init(isRunning: { true }, isPaused: { true }, pause: {}, resume: {}))
    let handoff = QuickStateHandoff(arbiter: arbiter, isCurrent: { _ in true })
    let operation = handoff.begin(session: .init(gameID: "GALE01", identifier: 7), dismiss: {})
    handoff.complete(operation)
    handoff.sampleInput(active: QuickStateHandoff.gameplayInputActive(controllers: [normalized]))
    raw.profile.a.update(value: 1, pressed: true)
    XCTAssertTrue(QuickStateHandoff.gameplayInputActive(controllers: [normalized]))
    handoff.sampleInput(active: QuickStateHandoff.gameplayInputActive(controllers: [normalized]))
    XCTAssertFalse(handoff.hasPendingOperation)
    raw.profile.a.update(value: 0, pressed: false)
    raw.profile.menu.update(value: 1, pressed: true)
    XCTAssertFalse(QuickStateHandoff.gameplayInputActive(controllers: [normalized]), "Menu cannot activate")
    let menuOperation = handoff.begin(session: .init(gameID: "GALE01", identifier: 7), dismiss: {})
    handoff.complete(menuOperation)
    raw.profile.menu.update(value: 0, pressed: false)
    handoff.sampleInput(active: false)
    raw.profile.menu.update(value: 1, pressed: true)
    raw.profile.a.update(value: 1, pressed: true)
    XCTAssertTrue(QuickStateHandoff.navigationControlsActive(controllers: [normalized]))
    handoff.sampleInput(active: QuickStateHandoff.gameplayInputActive(controllers: [normalized]),
      controlsNeutral: false, activationBlocked: QuickStateHandoff.navigationControlsActive(controllers: [normalized]))
    XCTAssertTrue(handoff.hasPendingOperation, "Normalized Menu must block A even after initial arming")
    raw.profile.a.update(value: 0, pressed: false)
    raw.profile.menu.update(value: 0, pressed: false)
    raw.profile.stick.update(x: 0.8, y: 0)
    XCTAssertTrue(QuickStateHandoff.gameplayInputActive(controllers: [normalized]))
  }

  #if os(iOS)
  func testLegacyAndHostedControlSubtreesTrackHeldFreshCancelledAndRemovedContacts() {
    for hosted in [false, true] {
      let host = EmulationScreen.TouchPadsContainer.HostView()
      let control: UIView = hosted ? TouchOverlaySurface.SurfaceView() : TCButton(frame: .zero)
      host.addSubview(control)
      XCTAssertTrue(host.gameplayContactObserver.view === host)
      XCTAssertTrue(GameplayTouchContactObserver.isGameplayControl(control, in: host, at: .zero))
      let arbiter = PauseArbiter(core: .init(isRunning: { true }, isPaused: { true }, pause: {}, resume: {}))
      let handoff = QuickStateHandoff(arbiter: arbiter, isCurrent: { _ in true })
      let scope = host.gameplayContactObserver.contacts
      scope.onGameplayBegan = { handoff.sampleInput(active: true, controlsNeutral: false) }
      let first = NSObject(), second = NSObject()
      let one: Set<ObjectIdentifier> = [ObjectIdentifier(first)]
      let two: Set<ObjectIdentifier> = [ObjectIdentifier(second)]
      let operation = handoff.begin(session: .init(gameID: "GALE01", identifier: 7), dismiss: {})
      host.gameplayContactObserver.recordContactsBegan(one, target: control, gameplay: one)
      handoff.complete(operation)
      handoff.sampleInput(active: scope.hasGameplayContacts, controlsNeutral: !GameplayTouchContacts.hasAnyContacts)
      XCTAssertTrue(handoff.hasPendingOperation, "Touch held across completion cannot arm")
      host.gameplayContactObserver.recordContactsBegan(two, target: control, gameplay: two)
      XCTAssertTrue(handoff.hasPendingOperation, "Another finger while held cannot bypass neutral")
      scope.ended(one)
      XCTAssertTrue(GameplayTouchContacts.hasAnyContacts, "Final remaining contact blocks neutral")
      scope.ended(two)
      handoff.sampleInput(active: false, controlsNeutral: !GameplayTouchContacts.hasAnyContacts)
      host.gameplayContactObserver.recordContactsBegan(one, target: control, gameplay: one)
      XCTAssertFalse(handoff.hasPendingOperation)
      control.removeFromSuperview()
      XCTAssertFalse(GameplayTouchContacts.hasAnyContacts, "Subtree teardown releases the contact scope")
      scope.began(two, gameplay: [])
      XCTAssertFalse(scope.hasGameplayContacts, "App actions cannot activate resume")
      scope.cancelAll()
      XCTAssertFalse(GameplayTouchContacts.hasAnyContacts)
    }
  }

  func testMixedGameplayAndAppActionBeginBatchCannotResumeInEitherContactOrder() {
    for gameplayFirst in [true, false] {
      let host = EmulationScreen.TouchPadsContainer.HostView()
      let game = TouchOverlaySurface.SurfaceView(), action = TouchOverlaySurface.SurfaceView()
      action.gameplayHitTest = { _ in false }
      host.addSubview(game); host.addSubview(action)
      let finger = NSObject(), other = NSObject()
      let gameplay = GameplayTouchContactObserver.BeganContact(id: ObjectIdentifier(finger), target: game, gameplay: true)
      let appAction = GameplayTouchContactObserver.BeganContact(id: ObjectIdentifier(other), target: action, gameplay: false)
      let arbiter = PauseArbiter(core: .init(isRunning: { true }, isPaused: { true }, pause: {}, resume: {}))
      let handoff = QuickStateHandoff(arbiter: arbiter, isCurrent: { _ in true })
      let operation = handoff.begin(session: .init(gameID: "GALE01", identifier: 7), dismiss: {})
      handoff.complete(operation)
      handoff.sampleInput(active: false)
      var activations = 0
      host.gameplayContactObserver.contacts.onGameplayBegan = {
        activations += 1
        XCTAssertTrue(GameplayTouchContacts.hasNonGameplayContacts, "Complete batch must exist before activation")
        handoff.sampleInput(active: true, controlsNeutral: false,
          activationBlocked: GameplayTouchContacts.hasNonGameplayContacts)
      }
      host.gameplayContactObserver.recordContactsBegan(gameplayFirst ? [gameplay, appAction] : [appAction, gameplay])
      XCTAssertEqual(activations, 1, "One begin batch emits at most one gameplay activation")
      XCTAssertTrue(handoff.hasPendingOperation, "Mixed app-action batch cannot consume the armed hold")
      host.gameplayContactObserver.cancelAllContacts()
    }
  }

  func testRemovingOneHostedSurfacePreservesOtherHeldContact() {
    let host = EmulationScreen.TouchPadsContainer.HostView()
    let first = TouchOverlaySurface.SurfaceView(), second = TouchOverlaySurface.SurfaceView()
    host.addSubview(first); host.addSubview(second)
    let finger = NSObject(), other = NSObject()
    let one: Set<ObjectIdentifier> = [ObjectIdentifier(finger)]
    let two: Set<ObjectIdentifier> = [ObjectIdentifier(other)]
    let observer = host.gameplayContactObserver
    observer.recordContactsBegan(one, target: first, gameplay: one)
    observer.recordContactsBegan(two, target: second, gameplay: two)
    first.removeFromSuperview()
    XCTAssertTrue(GameplayTouchContacts.hasAnyContacts)
    XCTAssertTrue(observer.contacts.hasGameplayContacts)
    second.removeFromSuperview()
    XCTAssertFalse(GameplayTouchContacts.hasAnyContacts)
  }

  func testHostedAppActionSurfaceIsNotGameplayAndMotionWritesDoNotCreateContacts() {
    let host = EmulationScreen.TouchPadsContainer.HostView()
    let action = TouchOverlaySurface.SurfaceView()
    action.gameplayHitTest = { _ in false }
    host.addSubview(action)
    XCTAssertFalse(GameplayTouchContactObserver.isGameplayControl(action, in: host, at: .zero))
    TCManagerInterface.setAxisValueFor(TCButtonType.wiiGyroPitchUp.rawValue, controller: 0, value: 0.75)
    XCTAssertFalse(GameplayTouchContacts.hasAnyContacts)
    TCManagerInterface.setAxisValueFor(TCButtonType.wiiGyroPitchUp.rawValue, controller: 0, value: 0)
  }
  #endif
}
