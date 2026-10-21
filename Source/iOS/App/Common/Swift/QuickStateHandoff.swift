// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import GameController
import UIKit

/// Session ownership outlives the presenting menu. Completion drops only the I/O claim;
/// a neutral sample followed by new gameplay input drops the separate user hold.
@MainActor
final class QuickStateHandoff {
  struct Operation: Equatable { let id: UUID }
  private struct Pending {
    let operation: Operation
    let session: QuickSaveSurfaceSession
    let io: PauseArbiter.Token
    let awaitingInput: PauseArbiter.Token
    var completed = false
    var sawNeutral = false
  }
  static let shared = QuickStateHandoff(arbiter: .shared, isCurrent: {
    TVEmulationBridge.currentGameID() == $0.gameID && TVEmulationBridge.currentSessionIdentifier() == $0.identifier
  })
  private let arbiter: PauseArbiter
  private let isCurrent: (QuickSaveSurfaceSession) -> Bool
  private var pending: [UUID: Pending] = [:]
  private var timer: Timer?
  private var touchObserver: NSObjectProtocol?

  /// Includes both in-flight I/O and the completed action awaiting fresh gameplay input.
  var hasPendingOperation: Bool { !pending.isEmpty }

  init(arbiter: PauseArbiter, isCurrent: @escaping (QuickSaveSurfaceSession) -> Bool) {
    self.arbiter = arbiter; self.isCurrent = isCurrent
  }

  @discardableResult
  func begin(session: QuickSaveSurfaceSession, dismiss: () -> Void) -> Operation {
    let operation = Operation(id: UUID())
    let io = arbiter.claim("quick-state-operation")
    let awaitingInput = arbiter.claim("quick-state-awaiting-input")
    pending[operation.id] = Pending(operation: operation, session: session, io: io, awaitingInput: awaitingInput)
    dismiss()
    return operation
  }

  func complete(_ operation: Operation) {
    guard var state = pending[operation.id] else { return }
    if !isCurrent(state.session) { discard(operation.id); return }
    state.completed = true
    state.sawNeutral = false // input during I/O never arms resume
    pending[operation.id] = state
    arbiter.release(state.io)
  }

  func sampleInput(active: Bool, controlsNeutral: Bool? = nil, activationBlocked: Bool = false) {
    let owned = Set(pending.values.flatMap { [$0.io, $0.awaitingInput] })
    let anotherOwnerIsPausing = arbiter.hasHolders(excluding: owned)
    for id in Array(pending.keys) {
      guard var state = pending[id] else { continue }
      guard isCurrent(state.session) else { discard(id); continue }
      guard state.completed else { continue }
      // Input used by another presentation or pause reason never carries across its dismissal.
      if anotherOwnerIsPausing || activationBlocked {
        state.sawNeutral = false
        pending[id] = state
        continue
      }
      if controlsNeutral ?? !active { state.sawNeutral = true; pending[id] = state }
      else if active && state.sawNeutral { discard(id) }
    }
    if pending.isEmpty { timer?.invalidate(); timer = nil }
  }

  private func discard(_ id: UUID) {
    guard let state = pending.removeValue(forKey: id) else { return }
    arbiter.release(state.io)
    arbiter.release(state.awaitingInput)
  }

  /// Poll physical gameplay values without replacing GameController's existing handlers.
  /// Neutrality covers every physical control, including navigation buttons. Only gameplay input
  /// activates resume; Menu/Home/Options can block arming but can never activate it.
  func startInputSampling() {
    guard timer == nil else { return }
    if touchObserver == nil {
      touchObserver = NotificationCenter.default.addObserver(forName: .DOLGameplayInputBegan, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.noteGameplayInputBegan()
        }
      }
    }
    timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        // Neither activation nor controller connection is input. Sample only in gameplay.
        let allowed = UIApplication.shared.applicationState == .active && !EmuEventVC.isPauseOverlayVisible()
        self.sampleInput(active: allowed && Self.gameplayInputActive(controllers: ControllerManager.shared.controllers),
          controlsNeutral: allowed && Self.allControlsNeutral(),
          activationBlocked: !allowed || Self.navigationControlsActive(controllers: ControllerManager.shared.controllers))
      }
    }
  }

  /// A new touch/pill edge uses the same physical navigation and ownership fence as polling.
  func noteGameplayInputBegan() {
    let allowed = UIApplication.shared.applicationState == .active && !EmuEventVC.isPauseOverlayVisible()
    sampleInput(active: allowed, controlsNeutral: false,
      activationBlocked: !allowed || Self.navigationControlsActive(controllers: ControllerManager.shared.controllers))
  }

  static func navigationControlsActive(controllers: [GCController]) -> Bool {
    if GameplayTouchContacts.hasNonGameplayContacts { return true }
    if EmuEventVC.menuPressIsActive() || PauseGestureTracker.shared.hasMenuPressInProgress { return true }
    for controller in controllers {
      if let pad = controller.extendedGamepad {
        if pad.buttonMenu.isPressed || pad.buttonOptions?.isPressed == true || pad.buttonHome?.isPressed == true { return true }
      } else if controller.microGamepad?.buttonMenu.isPressed == true { return true }
    }
    return false
  }

  private static func allControlsNeutral() -> Bool {
    guard !EmuEventVC.gameplayTouchIsActive(), !GameplayTouchContacts.hasAnyContacts,
          !navigationControlsActive(controllers: ControllerManager.shared.controllers) else { return false }
    for controller in GCController.controllers() {
      let profile = controller.physicalInputProfile
      if profile.buttons.values.contains(where: { $0.isPressed || abs($0.value) > 0.35 }) { return false }
      if profile.axes.values.contains(where: { abs($0.value) > 0.35 }) { return false }
    }
    return true
  }

  static func gameplayInputActive(controllers: [GCController]) -> Bool {
    if EmuEventVC.gameplayTouchIsActive() || GameplayTouchContacts.hasAnyGameplayContacts { return true }
    for controller in controllers {
      if let pad = controller.extendedGamepad {
        let buttons = [pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY,
          pad.leftShoulder, pad.rightShoulder, pad.leftTrigger, pad.rightTrigger]
        if buttons.contains(where: { $0.isPressed }) || pad.leftThumbstickButton?.isPressed == true || pad.rightThumbstickButton?.isPressed == true { return true }
        for axis in [pad.dpad, pad.leftThumbstick, pad.rightThumbstick] {
          if abs(axis.xAxis.value) > 0.35 || abs(axis.yAxis.value) > 0.35 { return true }
        }
      } else if let pad = controller.microGamepad {
        if pad.buttonA.isPressed || pad.buttonX.isPressed || abs(pad.dpad.xAxis.value) > 0.35 || abs(pad.dpad.yAxis.value) > 0.35 { return true }
      }
    }
    return false
  }
}
