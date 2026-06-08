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
/// Port indices are 0-based here (port 0 == Player 1).
///
/// Note: `reconcile()` and the `ControllerAssignmentsChanged` notification are
/// deliberately NOT performed here — they remain the responsibility of the
/// `ControllerManager` wrappers that call this service, so the service's mutation
/// sequence stays deterministic and unit-testable.
final class ControllerAssignmentService {
  private let writer: ControllerConfigWriting

  init(writer: ControllerConfigWriting) {
    self.writer = writer
  }

  /// Atomically assign a physical/DSU device qualifier to a player:
  /// (1) activate the port, (2) bind the device, (3) apply the device-default
  /// profile, (4) save.
  func assign(qualifier: String, toPlayer port: Int, system: EmulatedSystem) {
    activate(system: system, port: port)
    writer.setDefaultDevice(qualifier, system: system, port: port)
    if let profile = writer.defaultProfileName(forQualifier: qualifier) {
      writer.loadProfile(profile, system: system, port: port, restoreDevice: true)
    }
    writer.saveConfig(system: system)
  }

  /// Activate the port and bind the on-screen Touchscreen virtual device.
  /// (`assignTouchscreen` on the writer already persists config.)
  func assignTouchscreen(toPlayer port: Int, system: EmulatedSystem) {
    activate(system: system, port: port)
    writer.assignTouchscreen(system: system, port: port)
  }

  /// Clear a player's device binding and save.
  func clear(player port: Int, system: EmulatedSystem) {
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

  // MARK: Private

  private func activate(system: EmulatedSystem, port: Int) {
    switch system {
    case .gamecube: writer.setGCPortActive(true, port: port)
    case .wii: writer.setWiimoteSource(emulated: true, port: port)
    }
  }
}
