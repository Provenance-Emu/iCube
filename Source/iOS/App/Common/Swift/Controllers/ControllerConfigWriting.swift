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

  /// The device qualifier bound to a port ("" when none). A device that disconnects keeps its
  /// binding, so this can name a device that is gone.
  func defaultDevice(system: EmulatedSystem, port: Int) -> String

  // MARK: Mapping state

  /// True when at least one control of the slot's mapping resolves on the
  /// device currently bound to the slot. Ask it after `setDefaultDevice`.
  ///
  /// Disconnecting a device leaves its binding and its mapping alone, so a
  /// pad that comes back still binds its own mapping and this is true. A mapping left by a different kind of
  /// device (the Touchscreen profile under a physical pad, or the reverse)
  /// binds nothing, and this is false.
  /// `ControllerAssignmentService.assign` uses it to keep a user-picked
  /// profile across a reconnect without leaving a pad on a mapping it cannot
  /// drive.
  func mappingBindsDevice(system: EmulatedSystem, port: Int) -> Bool

  // MARK: Profile

  /// The default input-profile name for a device qualifier
  /// (DSU -> "DSU", iOS -> "Touchscreen", MFi -> "Physical Controller"), or
  /// `nil` if the device type has no known default profile.
  func defaultProfileName(forQualifier qualifier: String) -> String?

  /// Load a named input profile for a port, optionally restoring the bound device.
  func loadProfile(_ name: String, system: EmulatedSystem, port: Int, restoreDevice: Bool)

  // MARK: Mapping stash

  /// Keep the port's live mapping as `qualifier`'s, for when that device is assigned again
  /// (`TVControllerMappingBridge.stashMapping`; one per device and system, the last one wins).
  func stashMapping(forQualifier qualifier: String, system: EmulatedSystem, port: Int)

  /// Load `qualifier`'s stashed mapping into the port, keeping the bound device, and drop the
  /// stash. False, changing nothing, when there is none.
  func restoreStashedMapping(forQualifier qualifier: String, system: EmulatedSystem, port: Int) -> Bool

  // MARK: Touchscreen

  /// Bind the on-screen Touchscreen virtual device to a port (saves config).
  func assignTouchscreen(system: EmulatedSystem, port: Int)

  // MARK: Persistence

  /// Persist the relevant config to disk.
  func saveConfig(system: EmulatedSystem)
}
