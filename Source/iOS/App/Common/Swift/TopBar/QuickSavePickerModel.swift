// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation

/// Selection is a stable file URL, never the provider's per-scan UUID. No selection mutates a save.
struct QuickSavePickerSelection: Equatable {
  var historyPath: URL?

  mutating func select(_ state: SaveStateInfo) { historyPath = state.path }

  mutating func reconcile(states: [SaveStateInfo]) {
    if let historyPath, states.contains(where: { $0.path == historyPath }) { return }
    historyPath = QuickSavePickerModel.manualStates(states).first?.path
      ?? states.first(where: { $0.isAuto })?.path
  }
}

enum QuickSavePickerModel {
  static let slots = Array(1...10)

  static func manualStates(_ states: [SaveStateInfo]) -> [SaveStateInfo] {
    states.filter { !$0.isAuto }.sorted(by: QuickSaveHistoryPolicy.newestFirst)
  }

  static func visibleStates(_ states: [SaveStateInfo], modded: Bool) -> [SaveStateInfo] {
    modded ? states.filter { !$0.isAuto && !$0.isQuickSave } : states
  }

  static func slotState(_ slot: Int, states: [SaveStateInfo]) -> SaveStateInfo? {
    manualStates(states).first { $0.slot == slot }
  }

  static func canLoad(_ state: SaveStateInfo?, busy: Bool) -> Bool {
    !busy && state?.isCompatible == true
  }

  static func needsOverwriteConfirmation(slot: Int, states: [SaveStateInfo]) -> Bool {
    slotState(slot, states: states) != nil
  }
}

enum QuickSaveSlotSaveDecision: Equatable {
  case unavailable
  case confirm(QuickSaveSlotSaveRequest)
  case save(QuickSaveSlotSaveRequest)
}

/// Shared by the picker and the tvOS primary pane. A completed catalogue scan is required, but its
/// absence of a state never substitutes for checking the actual bridge destination immediately before Save.
@MainActor
@Observable
final class QuickSavePickerScan {
  private(set) var states: [SaveStateInfo] = []
  private(set) var hasCompletedScan = false

  func reload(using load: @MainActor () async -> [SaveStateInfo]) async {
    hasCompletedScan = false
    let loaded = await load()
    guard !Task.isCancelled else { return }
    states = loaded
    hasCompletedScan = true
  }

  func prepareSave(slot: Int, session: QuickSaveSurfaceSession, destination: URL?,
                   occupancy: QuickSaveDestinationOccupancy) -> QuickSaveSlotSaveDecision {
    guard hasCompletedScan, QuickSavePickerModel.slots.contains(slot), !session.gameID.isEmpty,
          let destination, occupancy != .unknown else { return .unavailable }
    let request = QuickSaveSlotSaveRequest(session: session, slot: slot, path: destination)
    return occupancy == .occupied || QuickSavePickerModel.needsOverwriteConfirmation(slot: slot, states: states)
      ? .confirm(request) : .save(request)
  }

  func save<Outcome>(_ request: QuickSaveSlotSaveRequest, confirmed: Bool,
                     isCurrent: @MainActor (QuickSaveSurfaceSession) -> Bool, destination: @MainActor (Int) -> URL?,
                     occupancy: (URL) -> QuickSaveDestinationOccupancy,
                     operation: @MainActor (QuickSaveSlotSaveRequest) async -> Outcome) async -> Outcome? {
    guard hasCompletedScan, isCurrent(request.session), destination(request.slot) == request.path else { return nil }
    let currentOccupancy = occupancy(request.path)
    guard currentOccupancy != .unknown else { return nil }
    guard confirmed || (currentOccupancy == .empty &&
      !QuickSavePickerModel.needsOverwriteConfirmation(slot: request.slot, states: states)) else { return nil }
    let outcome = await operation(request)
    return isCurrent(request.session) ? outcome : nil
  }
}

@MainActor
enum QuickSaveSurfaceActions {
  /// UI gating and callback safety use the same compatible file and captured presentation session.
  static func load<Outcome>(_ state: SaveStateInfo?, session: QuickSaveSurfaceSession,
                            isCurrent: @MainActor (QuickSaveSurfaceSession) -> Bool,
                            operation: @MainActor (SaveStateInfo) async -> Outcome) async -> Outcome? {
    guard let state, state.isCompatible, state.gameID == session.gameID, isCurrent(session) else { return nil }
    let outcome = await operation(state)
    return isCurrent(session) ? outcome : nil
  }
}
