// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The single source of truth for mutating controller assignment.
///
/// Every assign path (auto-assign on connect, reconcile, Settings, Pause) routes
/// through this service so that activating the port, binding the device, and
/// applying the device-default input profile always happen together. Before this
/// existed, the assign paths only *bound* the device (`SetDefaultDevice`) without
/// activating the port's SIDevice type, so only Player 1 (activated at boot)
/// produced input — ports 2-4 were silently dead.
///
/// It also keeps the user's mappings: whenever a slot bound to a physical
/// controller goes to another device (the Touchscreen after a disconnect,
/// another pad, No Device), that controller's mapping is stashed first, and it
/// comes back when the controller is assigned again — before, the Touchscreen
/// profile replaced it and the pad came back to "Physical Controller".
///
/// Port indices are 0-based here (port 0 == Player 1).
///
/// Note: `ControllerManager.reconcile()` and the `ControllerAssignmentsChanged`
/// notification stay in the `ControllerManager` wrappers that call this service,
/// so the service's mutation sequence stays deterministic and unit-testable.
final class ControllerAssignmentService {
  private let writer: ControllerConfigWriting

  init(writer: ControllerConfigWriting) {
    self.writer = writer
  }

  /// Atomically assign a physical/DSU device qualifier to a player:
  /// (1) stash the mapping of the controller the slot held, (2) activate the
  /// port, (3) bind the device, (4) give it back its own stashed mapping, or
  /// else apply the device-default profile — but only when the slot's mapping
  /// binds nothing on that device, (5) save.
  ///
  /// Step 4 keeps a user-picked profile across a reconnect: a device that
  /// disconnects keeps its binding and its mapping, so when it comes back to
  /// the same slot nothing is reloaded; when another device took the slot
  /// meanwhile, its mapping is in the stash.
  ///
  /// The test is "binds on this device", not "is non-empty": a slot the
  /// Touchscreen held keeps the Touchscreen profile (`Button 0`, `Axis 11`),
  /// none of which exist on a physical pad, so keeping it left the pad dead
  /// until the user reset the profile. Step 3 must come first — binding the
  /// device is what re-resolves the mapping against it. Every caller passes
  /// the qualifier of a device the ControllerInterface currently enumerates
  /// (`allQualifiedDevices`, `qualifiedName(for:)`), so "binds nothing" means
  /// the mapping is for another kind of device, not that the device is late.
  func assign(qualifier: String, toPlayer port: Int, system: EmulatedSystem) {
    let previous = writer.defaultDevice(system: system, port: port)
    let changesDevice = previous != qualifier
    if changesDevice { stashMapping(of: previous, player: port, system: system) }
    activate(system: system, port: port)
    writer.setDefaultDevice(qualifier, system: system, port: port)
    let restored = changesDevice && writer.restoreStashedMapping(forQualifier: qualifier, system: system, port: port)
    if !restored, !writer.mappingBindsDevice(system: system, port: port),
       let profile = writer.defaultProfileName(forQualifier: qualifier) {
      writer.loadProfile(profile, system: system, port: port, restoreDevice: true)
    }
    writer.saveConfig(system: system)
  }

  /// Activate the port and bind the on-screen Touchscreen virtual device, after
  /// stashing the mapping of the controller the slot held.
  /// (`assignTouchscreen` on the writer already persists config.)
  func assignTouchscreen(toPlayer port: Int, system: EmulatedSystem) {
    stashMapping(of: writer.defaultDevice(system: system, port: port), player: port, system: system)
    activate(system: system, port: port)
    writer.assignTouchscreen(system: system, port: port)
  }

  /// Clear a player's device binding and save. The mapping stays on the slot and
  /// is stashed for the controller that had it.
  func clear(player port: Int, system: EmulatedSystem) {
    stashMapping(of: writer.defaultDevice(system: system, port: port), player: port, system: system)
    writer.clearDefaultDevice(system: system, port: port)
    writer.saveConfig(system: system)
  }

  /// Apply a named profile to a player and save.
  func loadProfile(_ name: String, player port: Int, system: EmulatedSystem) {
    writer.loadProfile(name, system: system, port: port, restoreDevice: true)
    writer.saveConfig(system: system)
  }

  /// Activate a port without binding (used by fallback paths that bind via a
  /// legacy bridge call but still need the SIDevice/Wiimote-source activated).
  func activate(port: Int, system: EmulatedSystem) {
    activate(system: system, port: port)
  }

  /// Applies one `AssignmentEngine` decision, in order.
  func apply(_ decision: AssignmentDecision) {
    for assignment in decision.assignments {
      if let qualifier = assignment.qualifier {
        assign(qualifier: qualifier, toPlayer: assignment.playerZeroBased, system: assignment.system)
      } else {
        assignTouchscreen(toPlayer: assignment.playerZeroBased, system: assignment.system)
      }
    }
  }

  /// The writes of one `ControllerManager.reconcile()` pass over `state`: with
  /// `autoAssign`, what `AssignmentEngine` decides; then every slot bound to a
  /// CONNECTED physical controller is re-affirmed active (SIDevice / Wii Remote
  /// source Emulated) even if some other writer deactivated it since the binding
  /// was made. The engine only emits writes for NEW bindings, so without this
  /// pass a slot could stay bound-but-dead until the controller reconnected.
  func reconcile(_ state: ControllerStateStore.State, pinned: Set<PinnedSlot>, autoAssign: Bool) {
    if autoAssign {
      apply(AssignmentEngine().decide(from: state, pinned: pinned))
    }
    let connected = Set(state.connectedQualifiers)
    func isConnectedPad(_ qualifier: String) -> Bool {
      AssignmentEngine.isPhysical(qualifier) && connected.contains(qualifier)
    }
    for slot in state.portAssignments where isConnectedPad(slot.defaultDeviceQualifier) {
      activate(system: .gamecube, port: slot.portOneBased - 1)
    }
    if state.isWiiSystem {
      for slot in state.wiimoteAssignments where isConnectedPad(slot.defaultDeviceQualifier) {
        activate(system: .wii, port: slot.portOneBased - 1)
      }
    }
  }

  // MARK: Private

  private func activate(system: EmulatedSystem, port: Int) {
    switch system {
    case .gamecube: writer.setGCPortActive(true, port: port)
    case .wii: writer.setWiimoteSource(emulated: true, port: port)
    }
  }

  /// The slot is about to stop being `qualifier`'s: keep its mapping for when that controller is
  /// assigned again. Nothing for the Touchscreen (its mapping comes back from its profile) or an
  /// empty slot.
  private func stashMapping(of qualifier: String, player port: Int, system: EmulatedSystem) {
    guard AssignmentEngine.isPhysical(qualifier) else { return }
    writer.stashMapping(forQualifier: qualifier, system: system, port: port)
  }
}
