// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Completed saves and requested loads only. Callers display a nonempty message after awaiting,
/// and retain their own surface/request identity so a dismissed picker never updates a new one.
@MainActor
enum QuickSaveActions {
  enum Outcome: Equatable {
    case saved(URL)
    case savedWithCleanupWarning(URL)
    case saveFailed
    case loadRequested(URL)
    case empty
    case incompatible(URL)
    case unavailable
    case keepUpdated
    case keepFailed
    case cancelled

    var message: String {
      switch self {
      case .saved(let url):
        if QuickSaveHistoryPolicy.historyGameID(for: url) != nil { return L("Quick save created") }
        if let slot = Int(url.pathExtension.dropFirst()), url.pathExtension.hasPrefix("s") {
          return QuickSlot.Outcome.saved(slot: slot).message
        }
        return L("Quick save created")
      case .savedWithCleanupWarning: return L("Quick save created; couldn't remove older saves")
      case .saveFailed: return L("Couldn't create save state")
      case .loadRequested: return L("Loading save state")
      case .empty: return L("No save state available")
      case .incompatible: return L("This save state is incompatible with this build")
      case .unavailable: return L("Game isn't ready to load yet")
      case .keepUpdated: return L("Save updated")
      case .keepFailed: return L("Couldn't update Keep")
      case .cancelled: return ""
      }
    }

    var isSuccess: Bool {
      switch self {
      case .saved, .savedWithCleanupWarning, .loadRequested, .keepUpdated: return true
      default: return false
      }
    }
  }

  private struct Session {
    let gameID = TVEmulationBridge.currentGameID()
    let identifier = TVEmulationBridge.currentSessionIdentifier()
    var isCurrent: Bool {
      !gameID.isEmpty && gameID == TVEmulationBridge.currentGameID() &&
        identifier == TVEmulationBridge.currentSessionIdentifier()
    }
  }

  static func save(mode: QuickSaveMode, slot: Int) async -> Outcome {
    if effectiveMode(mode, modded: ModdedBoot.isCurrentBootModded) == .slots { return await saveSlot(slot) }
    return await saveHistory()
  }

  static func load(mode: QuickSaveMode, slot: Int) async -> Outcome {
    if effectiveMode(mode, modded: ModdedBoot.isCurrentBootModded) == .slots { return loadSlot(slot) }
    let session = Session()
    guard session.isCurrent, TVEmulationBridge.isStateOperationAllowed() else { return .unavailable }
    let states = await FilesystemSaveStateProvider().states(for: session.gameID)
    guard session.isCurrent else { return .cancelled }
    switch QuickSaveHistoryPolicy.loadTarget(states: states, modded: ModdedBoot.isCurrentBootModded) {
    case .manual(let url), .automatic(let url):
      return requestLoad(url, session: session)
    case .incompatible(let url): return .incompatible(url)
    case .unavailable: return .empty
    }
  }

  static func effectiveMode(_ mode: QuickSaveMode, modded: Bool) -> QuickSaveMode {
    modded ? .slots : mode
  }

  static func saveHistory() async -> Outcome {
    let session = Session()
    guard session.isCurrent, !ModdedBoot.isCurrentBootModded,
          TVEmulationBridge.isStateOperationAllowed() else { return .unavailable }
    let result = await SaveStateService.saveHistoryResultAsync(expectedGameID: session.gameID,
      expectedSessionIdentifier: session.identifier)
    guard session.isCurrent, !result.cancelled else { return .cancelled }
    guard let snapshot = result.snapshot else { return .saveFailed }
    let url = URL(fileURLWithPath: snapshot.filePath)
    return result.cleanupFailed ? .savedWithCleanupWarning(url) : .saved(url)
  }

  static func saveSlot(_ slot: Int) async -> Outcome {
    let session = Session()
    guard session.isCurrent, TVEmulationBridge.isStateOperationAllowed() else { return .unavailable }
    let snapshot = await QuickSlot.saveSnapshot(slot: slot, expectedGameID: session.gameID,
      expectedSessionIdentifier: session.identifier)
    guard session.isCurrent else { return .cancelled }
    guard let snapshot else { return .saveFailed }
    return .saved(URL(fileURLWithPath: snapshot.filePath))
  }

  static func loadSelected(_ state: SaveStateInfo) async -> Outcome {
    let session = Session()
    guard session.isCurrent, state.gameID == session.gameID,
          TVEmulationBridge.isStateOperationAllowed() else { return .unavailable }
    // Mods deliberately use the explicit classic slot; shared vanilla history and auto are unsafe.
    guard !ModdedBoot.isCurrentBootModded || (state.slot != nil && !state.isAuto && !state.isQuickSave) else { return .unavailable }
    guard FileManager.default.fileExists(atPath: state.path.path) else { return .empty }
    guard state.isCompatible else { return .incompatible(state.path) }
    return requestLoad(state.path, session: session)
  }

  static func setKept(_ kept: Bool, for state: SaveStateInfo) async -> Outcome {
    let session = Session()
    guard session.isCurrent, state.gameID == session.gameID, state.isQuickSave else { return .keepFailed }
    let updated = await SaveStateService.setHistoryKeptAsync(kept, state: state,
      expectedSessionIdentifier: session.identifier)
    guard session.isCurrent else { return .cancelled }
    return updated ? .keepUpdated : .keepFailed
  }

  private static func loadSlot(_ slot: Int) -> Outcome {
    let session = Session()
    guard session.isCurrent, TVEmulationBridge.isStateOperationAllowed() else { return .unavailable }
    guard let path = TVEmulationBridge.stateFilePath(forSlot: slot),
          FileManager.default.fileExists(atPath: path) else { return .empty }
    let url = URL(fileURLWithPath: path)
    guard TVEmulationBridge.stateFileIsCompatible(atPath: path) else { return .incompatible(url) }
    return QuickSlot.requestLoad(slot: slot, expectedGameID: session.gameID,
      expectedSessionIdentifier: session.identifier) ? .loadRequested(url) : .unavailable
  }

  private static func requestLoad(_ url: URL, session: Session) -> Outcome {
    guard session.isCurrent else { return .cancelled }
    guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
    guard TVEmulationBridge.stateFileIsCompatible(atPath: url.path) else { return .incompatible(url) }
    return TVEmulationBridge.loadState(fromPath: url.path, expectedGameID: session.gameID,
      expectedSessionIdentifier: session.identifier) ? .loadRequested(url) : .unavailable
  }
}
