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

  func defaultDevice(system: EmulatedSystem, port: Int) -> String {
    switch system {
    case .gamecube:
      return TVControllerMappingBridge.defaultDevice(forGCPort: port + 1) as String
    case .wii:
      return TVControllerMappingBridge.defaultDevice(forWiimote: port + 1) as String
    }
  }

  // MARK: Mapping state

  func mappingBindsDevice(system: EmulatedSystem, port: Int) -> Bool {
    switch system {
    case .gamecube:
      return TVControllerMappingBridge.padMappingBindsDevice(forGCPort: port + 1)
    case .wii:
      return TVControllerMappingBridge.wiimoteMappingBindsDevice(forWiimote: port + 1)
    }
  }

  // MARK: Profile

  func defaultProfileName(forQualifier qualifier: String) -> String? {
    // The device-default profile picked when a device is bound to a port.
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

  // MARK: Mapping stash

  func stashMapping(forQualifier qualifier: String, system: EmulatedSystem, port: Int) {
    switch system {
    case .gamecube:
      _ = TVControllerMappingBridge.stashMapping(forGCPort: port + 1, qualifier: qualifier)
    case .wii:
      _ = TVControllerMappingBridge.stashMapping(forWiimote: port + 1, qualifier: qualifier)
    }
  }

  func restoreStashedMapping(forQualifier qualifier: String, system: EmulatedSystem, port: Int) -> Bool {
    switch system {
    case .gamecube:
      return TVControllerMappingBridge.restoreStashedMapping(forGCPort: port + 1, qualifier: qualifier)
    case .wii:
      return TVControllerMappingBridge.restoreStashedMapping(forWiimote: port + 1, qualifier: qualifier)
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
    // Two files hold an assignment: the port's SIDevice / Wii Remote source live in Dolphin.ini
    // (`setGCPortDeviceForPort` / `setWiimoteSourceFor` only change the in-memory Base layer), the
    // device binding and the mapping in the system's input ini. Most mapping bridge calls save the
    // latter themselves; writing both here makes the assignment durable whatever path made it.
    DOLConfigBridge.flushSettingsToDisk()
    switch system {
    case .gamecube: TVControllerMappingBridge.saveGCPadConfig()
    case .wii: TVControllerMappingBridge.saveWiimoteConfig()
    }
  }
}
