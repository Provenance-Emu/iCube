// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Quick save / quick load on a numbered slot, with the toast. Shared by the top bar and anything else
/// (skin buttons) that offers the same actions, so they report identically.
///
/// A toast only follows real success: a save reports what `SaveStateService.saveSlot` returned (false
/// when the core refused or the sidecar could not be written), and a load needs a state file on disk and
/// a running core. The load itself is queued onto the CPU thread, so "Loaded" means it was accepted.
enum QuickSlot {
  enum Outcome: Equatable {
    case saved(slot: Int)
    case saveFailed(slot: Int)
    case loaded(slot: Int)
    case emptySlot(slot: Int)
    /// The core is not running (still booting or shutting down), so a load would be ignored.
    case loadUnavailable

    var message: String {
      switch self {
      case .saved(let slot): return String(format: L("Saved to Slot %d"), slot)
      case .saveFailed(let slot): return String(format: L("Couldn't save to Slot %d"), slot)
      case .loaded(let slot): return String(format: L("Loaded Slot %d"), slot)
      case .emptySlot(let slot): return String(format: L("No save in Slot %d"), slot)
      case .loadUnavailable: return L("Game isn't ready to load yet")
      }
    }

    var isSuccess: Bool {
      switch self {
      case .saved, .loaded: return true
      case .saveFailed, .emptySlot, .loadUnavailable: return false
      }
    }
  }

  static func saveOutcome(slot: Int, saved: Bool) -> Outcome {
    saved ? .saved(slot: slot) : .saveFailed(slot: slot)
  }

  static func loadOutcome(slot: Int, hasState: Bool, coreRunning: Bool) -> Outcome {
    if !hasState { return .emptySlot(slot: slot) }
    return coreRunning ? .loaded(slot: slot) : .loadUnavailable
  }

  static func hasState(_ slot: Int) -> Bool {
    guard let path = TVEmulationBridge.stateFilePath(forSlot: slot) else { return false }
    return FileManager.default.fileExists(atPath: path)
  }

  @discardableResult
  static func save(slot: Int) -> Outcome {
    let outcome = saveOutcome(slot: slot, saved: SaveStateService.saveSlot(slot))
    EmulationToast.post(outcome.message)
    return outcome
  }

  /// A single tap, as the pause menu's own Load button: there is no load-confirmation pattern in the app.
  @discardableResult
  static func load(slot: Int) -> Outcome {
    let outcome = loadOutcome(slot: slot, hasState: hasState(slot), coreRunning: TVEmulationBridge.isStateOperationAllowed())
    if case .loaded = outcome { TVEmulationBridge.loadState(fromSlot: slot) }
    EmulationToast.post(outcome.message)
    return outcome
  }
}
