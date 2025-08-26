// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

internal func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

// Localized labels for controller types (mirrors ControllersSettingsUtil)
internal func localizedSIDevice(_ device: Int) -> String {
  switch device {
  case 0: return L("None")
  case 1: return L("Standard Controller")
  case 2: return L("GameCube Adapter for Wii U")
  case 3: return L("Steering Wheel")
  case 4: return L("Dance Mat")
  case 5: return L("DK Bongos")
  case 6: return L("GBA (Integrated)")
  case 7: return L("GBA (TCP)")
  case 8: return L("Keyboard")
  default: return L("Error")
  }
}

internal func localizedWiimoteSource(_ source: Int) -> String {
  switch source {
  case 0: return L("None")
  case 1: return L("Emulated Wii Remote")
  case 2: return L("Real Wii Remote")
  default: return L("Error")
  }
}
