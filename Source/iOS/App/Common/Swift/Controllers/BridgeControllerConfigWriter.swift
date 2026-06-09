// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Concrete `ControllerConfigWriting` over the existing Objective-C bridges
/// (`TVControllerMappingBridge`, `DOLConfigBridge`, `EmulationCoordinator`).
///
/// The protocol's `port` parameters are 0-based; the bridges are all 1-based
/// (`portOneBased` / `indexOneBased`), so every call here converts with `port + 1`.
final class BridgeControllerConfigWriter: ControllerConfigWriting {

  // MARK: Port activation

  func setGCPortActive(_ active: Bool, port: Int) {
    // SIDevices: 0 = SIDEVICE_NONE, 6 = SIDEVICE_GC_CONTROLLER (NOT sequential).
    // Mirrors SettingsRootView.swift device-type selection.
    DOLConfigBridge.setGCPortDeviceForPort(port + 1, device: active ? 6 : 0)
  }

  func setWiimoteSource(emulated: Bool, port: Int) {
    // 0 = None, 1 = Emulated. Mirrors SettingsRootView.swift source selection.
    DOLConfigBridge.setWiimoteSourceFor(port + 1, source: emulated ? 1 : 0)
  }

  // MARK: Device binding

  func setDefaultDevice(_ qualifier: String, system: EmulatedSystem, port: Int) {
    switch system {
    case .gamecube:
      TVControllerMappingBridge.setDefaultDevice(qualifier, forGCPort: port + 1)
    case .wii:
      TVControllerMappingBridge.setDefaultDevice(qualifier, forWiimote: port + 1)
    }
  }

  func clearDefaultDevice(system: EmulatedSystem, port: Int) {
    switch system {
    case .gamecube:
      TVControllerMappingBridge.clearDefaultDevice(forGCPort: port + 1)
    case .wii:
      // No dedicated Wiimote clear on the bridge; clearing == binding empty.
      TVControllerMappingBridge.setDefaultDevice("", forWiimote: port + 1)
    }
  }

  // MARK: Profile

  func defaultProfileName(forQualifier qualifier: String) -> String? {
    // Mirrors ButtonMappingView.swift's defaultProfileName(forQualified:).
    if qualifier.hasPrefix("DSUClient/") { return "DSU" }
    if qualifier.hasPrefix("iOS/") { return "Touchscreen" }
    // Every other real hardware device (MFi and any generic/HID source) gets the
    // physical-controller profile, which wires Rumble/Motor so game rumble reaches
    // the device's motors.
    return "Physical Controller"
  }

  func loadProfile(_ name: String, system: EmulatedSystem, port: Int, restoreDevice: Bool) {
    switch system {
    case .gamecube:
      _ = TVControllerMappingBridge.loadProfile(name, forGCPort: port + 1, restoreDevice: restoreDevice)
    case .wii:
      _ = TVControllerMappingBridge.loadProfile(name, forWiimote: port + 1, restoreDevice: restoreDevice)
    }
  }

  // MARK: Touchscreen

  func assignTouchscreen(system: EmulatedSystem, port: Int) {
    switch system {
    case .gamecube:
      // assignTouchscreen(toGCPort:) loads the Touchscreen profile and saves config.
      TVControllerMappingBridge.assignTouchscreen(toGCPort: port + 1)
    case .wii:
      EmulationCoordinator.ensureWiimoteDefaultsToTouchscreen(forPort: port + 1)
    }
  }

  // MARK: Persistence

  func saveConfig(system: EmulatedSystem) {
    // The mutating bridge calls above (setDefaultDevice / setGCPortDeviceForPort /
    // assignTouchscreen / loadProfile) already persist via SaveConfig. This is an
    // explicit flush to guarantee the assignment is durable regardless of path.
    DOLConfigBridge.flushSettingsToDisk()
  }
}
