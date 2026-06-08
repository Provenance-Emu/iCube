// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The emulated system a controller assignment targets.
enum EmulatedSystem {
  case gamecube
  case wii
}

/// Write-surface the `ControllerAssignmentService` needs to mutate controller
/// configuration. Abstracted behind a protocol so the service logic can be
/// exercised by a fake in unit tests without touching the C++ Dolphin config.
///
/// IMPORTANT — port convention: every `port` parameter here is **0-based**
/// (port 0 == Player 1, port 1 == Player 2, …). The concrete bridge adapter
/// (`BridgeControllerConfigWriter`) is responsible for converting to the
/// 1-based indices the Objective-C bridges expect.
protocol ControllerConfigWriting {
  // MARK: Port activation (the missing half that left ports 2-4 dead)

  /// Activate/deactivate a GameCube port's SIDevice type
  /// (SIDEVICE_GC_CONTROLLER vs SIDEVICE_NONE).
  func setGCPortActive(_ active: Bool, port: Int)

  /// Set a Wiimote slot's source (Emulated vs None).
  func setWiimoteSource(emulated: Bool, port: Int)

  // MARK: Device binding

  /// Bind a device qualifier as the default device for a port.
  func setDefaultDevice(_ qualifier: String, system: EmulatedSystem, port: Int)

  /// Clear the default device binding for a port.
  func clearDefaultDevice(system: EmulatedSystem, port: Int)

  // MARK: Profile

  /// The default input-profile name for a device qualifier
  /// (DSU -> "DSU", iOS -> "Touchscreen", MFi -> "Physical Controller"), or
  /// `nil` if the device type has no known default profile.
  func defaultProfileName(forQualifier qualifier: String) -> String?

  /// Load a named input profile for a port, optionally restoring the bound device.
  func loadProfile(_ name: String, system: EmulatedSystem, port: Int, restoreDevice: Bool)

  // MARK: Touchscreen

  /// Bind the on-screen Touchscreen virtual device to a port (saves config).
  func assignTouchscreen(system: EmulatedSystem, port: Int)

  // MARK: Persistence

  /// Persist the relevant config to disk.
  func saveConfig(system: EmulatedSystem)
}
