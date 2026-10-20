// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Quick save / quick load on a numbered slot, with the toast. Shared by the top bar and anything else
/// (skin buttons) that offers the same actions, so they report identically.
///
/// A toast only follows real success: a save reports what `SaveStateService.saveSlot` returned (false
/// when the core refused or the sidecar could not be written), and a load needs a state file on disk and
/// a running core. A queued load reports "Loading"; only the core can report its final result.
/// A tap's immutable identity. The service validates the requested game under the core guard;
/// this separately prevents delayed UI completions from changing a dismissed/replaced surface.
struct SaveStateUIRequest: Equatable {
  let id = UUID()
  let slot: Int
  let gameID: String
  let sessionIdentifier: UInt64

  func accepts(completedGameID: String?, completedSessionIdentifier: UInt64?,
               currentGameID: String, currentSessionIdentifier: UInt64, activeID: UUID?) -> Bool {
    !gameID.isEmpty && activeID == id && currentGameID == gameID &&
      currentSessionIdentifier == sessionIdentifier &&
      (completedGameID == nil || completedGameID == gameID) &&
      (completedSessionIdentifier == nil || completedSessionIdentifier == sessionIdentifier)
  }
}

enum QuickSlot {
  enum Outcome: Equatable {
    case saved(slot: Int)
    case saveFailed(slot: Int)
    case loadRequested(slot: Int)
    case emptySlot(slot: Int)
    /// The core is not running (still booting or shutting down), so a load would be ignored.
    case loadUnavailable

    var message: String {
      switch self {
      case .saved(let slot): return String(format: L("Saved to Slot %d"), slot)
      case .saveFailed(let slot): return String(format: L("Couldn't save to Slot %d"), slot)
      case .loadRequested(let slot): return String(format: L("Loading Slot %d"), slot)
      case .emptySlot(let slot): return String(format: L("No save in Slot %d"), slot)
      case .loadUnavailable: return L("Game isn't ready to load yet")
      }
    }

    var isSuccess: Bool {
      switch self {
      case .saved, .loadRequested: return true
      case .saveFailed, .emptySlot, .loadUnavailable: return false
      }
    }
  }

  static func saveOutcome(slot: Int, saved: Bool) -> Outcome {
    saved ? .saved(slot: slot) : .saveFailed(slot: slot)
  }

  static func loadOutcome(slot: Int, hasState: Bool, coreRunning: Bool) -> Outcome {
    if !hasState { return .emptySlot(slot: slot) }
    return coreRunning ? .loadRequested(slot: slot) : .loadUnavailable
  }

  static func hasState(_ slot: Int) -> Bool {
    guard let path = TVEmulationBridge.stateFilePath(forSlot: slot) else { return false }
    return FileManager.default.fileExists(atPath: path)
  }

  @MainActor private static var pendingSave: SaveStateUIRequest?

  /// Capture the session before scheduling. Even restarting the same title before the first
  /// task runs must not make an old tap save the new session.
  static func save(slot: Int) {
    let request = SaveStateUIRequest(slot: slot, gameID: TVEmulationBridge.currentGameID(),
                                     sessionIdentifier: TVEmulationBridge.currentSessionIdentifier())
    Task { @MainActor in await completeSave(request) }
  }

  @MainActor
  private static func completeSave(_ request: SaveStateUIRequest) async {
    guard pendingSave == nil else { return }
    guard !request.gameID.isEmpty else {
      if TVEmulationBridge.currentGameID().isEmpty,
         TVEmulationBridge.currentSessionIdentifier() == request.sessionIdentifier {
        EmulationToast.post(saveOutcome(slot: request.slot, saved: false).message)
      }
      return
    }
    guard request.accepts(completedGameID: nil, completedSessionIdentifier: nil,
                          currentGameID: TVEmulationBridge.currentGameID(),
                          currentSessionIdentifier: TVEmulationBridge.currentSessionIdentifier(), activeID: request.id) else { return }
    pendingSave = request
    defer { if pendingSave?.id == request.id { pendingSave = nil } }
    let snapshot = await SaveStateService.saveSlotSnapshotAsync(request.slot, expectedGameID: request.gameID,
                                                               expectedSessionIdentifier: request.sessionIdentifier)
    guard request.accepts(completedGameID: snapshot?.gameID, completedSessionIdentifier: snapshot?.sessionIdentifier,
                          currentGameID: TVEmulationBridge.currentGameID(),
                          currentSessionIdentifier: TVEmulationBridge.currentSessionIdentifier(), activeID: pendingSave?.id) else { return }
    EmulationToast.post(saveOutcome(slot: request.slot, saved: snapshot != nil).message)
  }

  /// A single tap, as the pause menu's own Load button: there is no load-confirmation pattern in the app.
  @discardableResult
  static func load(slot: Int) -> Outcome {
    let outcome = loadOutcome(slot: slot, hasState: hasState(slot), coreRunning: TVEmulationBridge.isStateOperationAllowed())
    if case .loadRequested = outcome { TVEmulationBridge.loadState(fromSlot: slot) }
    EmulationToast.post(outcome.message)
    return outcome
  }
}
