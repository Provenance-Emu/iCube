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
    let gameID: String
    let identifier: UInt64
    init(expected: QuickSaveSurfaceSession? = nil) {
      gameID = expected?.gameID ?? TVEmulationBridge.currentGameID()
      identifier = expected?.identifier ?? TVEmulationBridge.currentSessionIdentifier()
    }
    var isCurrent: Bool {
      !gameID.isEmpty && gameID == TVEmulationBridge.currentGameID() &&
        identifier == TVEmulationBridge.currentSessionIdentifier()
    }
  }

  static func save(mode: QuickSaveMode, slot: Int) async -> Outcome {
    if effectiveMode(mode, modded: ModdedBoot.isCurrentBootModded) == .slots { return await saveSlot(slot) }
    return await saveHistory()
  }

  struct LoadEnvironment {
    var session: () -> QuickSaveSurfaceSession
    var isCurrent: (QuickSaveSurfaceSession) -> Bool
    var allowed: () -> Bool
    var isModded: () -> Bool
    var states: (String) async -> [SaveStateInfo]
    var slotPath: (Int) -> URL?
    var exists: (URL) -> Bool
    var compatible: (URL) -> Bool
    var request: (URL, QuickSaveSurfaceSession) -> Bool

    static var live: Self {
      Self(session: { .init(gameID: TVEmulationBridge.currentGameID(), identifier: TVEmulationBridge.currentSessionIdentifier()) },
        isCurrent: { TVEmulationBridge.currentGameID() == $0.gameID && TVEmulationBridge.currentSessionIdentifier() == $0.identifier },
        allowed: { TVEmulationBridge.isStateOperationAllowed() }, isModded: { ModdedBoot.isCurrentBootModded },
        states: { await FilesystemSaveStateProvider().states(for: $0) },
        slotPath: { TVEmulationBridge.stateFilePath(forSlot: $0).map { URL(fileURLWithPath: $0) } },
        exists: { FileManager.default.fileExists(atPath: $0.path) },
        compatible: { TVEmulationBridge.stateFileIsCompatible(atPath: $0.path) },
        request: { TVEmulationBridge.loadState(fromPath: $0.path, expectedGameID: $1.gameID, expectedSessionIdentifier: $1.identifier) })
    }
  }

  static func load(mode: QuickSaveMode, slot: Int, expectedSession: QuickSaveSurfaceSession? = nil, environment: LoadEnvironment? = nil) async -> Outcome {
    let environment = environment ?? .live
    let session = expectedSession ?? environment.session()
    guard !session.gameID.isEmpty, environment.isCurrent(session), environment.allowed() else { return .unavailable }
    let url: URL
    if effectiveMode(mode, modded: environment.isModded()) == .slots {
      guard let path = environment.slotPath(slot) else { return .empty }
      url = path
    } else {
      let states = await environment.states(session.gameID)
      guard environment.isCurrent(session) else { return .cancelled }
      switch QuickSaveHistoryPolicy.loadTarget(states: states, modded: environment.isModded()) {
      case .manual(let path), .automatic(let path): url = path
      case .incompatible(let path): return .incompatible(path)
      case .unavailable: return .empty
      }
    }
    guard environment.isCurrent(session) else { return .cancelled }
    guard environment.exists(url) else { return .empty }
    guard environment.compatible(url) else { return .incompatible(url) }
    return environment.request(url, session) ? .loadRequested(url) : .unavailable
  }

  static func effectiveMode(_ mode: QuickSaveMode, modded: Bool) -> QuickSaveMode {
    modded ? .slots : mode
  }

  static func saveHistory(expectedSession: QuickSaveSurfaceSession? = nil) async -> Outcome {
    let session = Session(expected: expectedSession)
    guard session.isCurrent, !ModdedBoot.isCurrentBootModded,
          TVEmulationBridge.isStateOperationAllowed() else { return .unavailable }
    let result = await SaveStateService.saveHistoryResultAsync(expectedGameID: session.gameID,
      expectedSessionIdentifier: session.identifier)
    guard session.isCurrent, !result.cancelled else { return .cancelled }
    guard let snapshot = result.snapshot else { return .saveFailed }
    let url = URL(fileURLWithPath: snapshot.filePath)
    return result.cleanupFailed ? .savedWithCleanupWarning(url) : .saved(url)
  }

  /// Unconfirmed callers can create only an empty captured slot. UI replacement consent uses the overload below.
  static func saveSlot(_ slot: Int) async -> Outcome {
    let session = QuickSaveSurfaceSession(gameID: TVEmulationBridge.currentGameID(), identifier: TVEmulationBridge.currentSessionIdentifier())
    guard let path = TVEmulationBridge.stateFilePath(forSlot: slot) else { return .saveFailed }
    let request = QuickSaveSlotSaveRequest(session: session, slot: slot, path: URL(fileURLWithPath: path))
    return await saveSlot(ClassicSlotSaveConsent(request: request, allowsOverwrite: false))
  }

  static func saveSlot(_ consent: ClassicSlotSaveConsent) async -> Outcome {
    let request = consent.request
    guard TVEmulationBridge.currentGameID() == request.session.gameID,
          TVEmulationBridge.currentSessionIdentifier() == request.session.identifier,
          TVEmulationBridge.isStateOperationAllowed() else { return .unavailable }
    let snapshot = await SaveStateService.saveSlotSnapshotAsync(consent)
    guard TVEmulationBridge.currentGameID() == request.session.gameID,
          TVEmulationBridge.currentSessionIdentifier() == request.session.identifier else { return .cancelled }
    guard let snapshot else { return .saveFailed }
    return .saved(URL(fileURLWithPath: snapshot.filePath))
  }

  static func loadSelected(_ state: SaveStateInfo, expectedSession: QuickSaveSurfaceSession? = nil) async -> Outcome {
    let session = Session(expected: expectedSession)
    guard session.isCurrent, state.gameID == session.gameID,
          TVEmulationBridge.isStateOperationAllowed() else { return .unavailable }
    // Mods deliberately use the explicit classic slot; shared vanilla history and auto are unsafe.
    guard !ModdedBoot.isCurrentBootModded || (state.slot != nil && !state.isAuto && !state.isQuickSave) else { return .unavailable }
    guard FileManager.default.fileExists(atPath: state.path.path) else { return .empty }
    guard state.isCompatible else { return .incompatible(state.path) }
    return requestLoad(state.path, session: session)
  }

  static func setKept(_ kept: Bool, for state: SaveStateInfo, expectedSession: QuickSaveSurfaceSession? = nil) async -> Outcome {
    let session = Session(expected: expectedSession)
    guard session.isCurrent, state.gameID == session.gameID, state.isQuickSave else { return .keepFailed }
    let updated = await SaveStateService.setHistoryKeptAsync(kept, state: state,
      expectedSessionIdentifier: session.identifier)
    guard session.isCurrent else { return .cancelled }
    return updated ? .keepUpdated : .keepFailed
  }

  private static func requestLoad(_ url: URL, session: Session) -> Outcome {
    guard session.isCurrent else { return .cancelled }
    guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
    guard TVEmulationBridge.stateFileIsCompatible(atPath: url.path) else { return .incompatible(url) }
    return TVEmulationBridge.loadState(fromPath: url.path, expectedGameID: session.gameID,
      expectedSessionIdentifier: session.identifier) ? .loadRequested(url) : .unavailable
  }
}
