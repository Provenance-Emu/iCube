// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Shared admission for Pause, controller Quick Menu, toolbar and skin actions. Classic saves enter
/// the reviewed browser; only that surface may grant destination-specific replacement consent.
@MainActor
final class QuickSaveMenuActions {
  struct Runtime {
    var isCurrent: @MainActor (QuickSaveSurfaceSession) -> Bool
    var isModded: @MainActor () -> Bool
    var saveHistory: @MainActor (QuickSaveSurfaceSession) async -> QuickSaveActions.Outcome
    var load: @MainActor (QuickSaveMode, Int, QuickSaveSurfaceSession) async -> QuickSaveActions.Outcome

    static var live: Self {
      Self(isCurrent: {
        TVEmulationBridge.currentGameID() == $0.gameID && TVEmulationBridge.currentSessionIdentifier() == $0.identifier
      }, isModded: { ModdedBoot.isCurrentBootModded }, saveHistory: { await QuickSaveActions.saveHistory(expectedSession: $0) },
      load: { await QuickSaveActions.load(mode: $0, slot: $1, expectedSession: $2) })
    }
  }

  private let mode: () -> QuickSaveMode
  private let slot: () -> Int
  private let session: QuickSaveSurfaceSession
  private let isActive: () -> Bool
  private let runtime: Runtime
  private let dismiss: () -> Void
  private let handoff: QuickStateHandoff?
  private let openBrowser: () -> Void
  private let onBusyChanged: (Bool) -> Void
  private let report: (QuickSaveActions.Outcome) -> Void
  private(set) var task: Task<Void, Never>?

  init(mode: @escaping () -> QuickSaveMode, slot: @escaping () -> Int, session: QuickSaveSurfaceSession,
       isActive: @escaping () -> Bool = { true }, runtime: Runtime? = nil,
       dismiss: @escaping () -> Void = {}, handoff: QuickStateHandoff? = nil,
       openBrowser: @escaping () -> Void, onBusyChanged: @escaping (Bool) -> Void = { _ in }, report: @escaping (QuickSaveActions.Outcome) -> Void) {
    self.mode = mode; self.slot = slot; self.session = session; self.isActive = isActive
    self.runtime = runtime ?? .live; self.dismiss = dismiss; self.handoff = handoff; self.openBrowser = openBrowser; self.onBusyChanged = onBusyChanged; self.report = report
  }

  private var acceptsAction: Bool { !session.gameID.isEmpty && isActive() && runtime.isCurrent(session) }

  func save() {
    guard task == nil, acceptsAction else { return }
    if QuickSaveActions.effectiveMode(mode(), modded: runtime.isModded()) == .slots {
      openBrowser()
      return
    }
    onBusyChanged(true)
    let operation = handoff?.begin(session: session, dismiss: dismiss)
    if handoff == nil { dismiss() }
    handoff?.startInputSampling()
    task = Task { @MainActor in
      defer {
        if let operation { handoff?.complete(operation) }
        task = nil; onBusyChanged(false)
      }
      guard runtime.isCurrent(session) else { return }
      let outcome = await runtime.saveHistory(session)
      guard !Task.isCancelled, runtime.isCurrent(session) else { return }
      if !outcome.message.isEmpty { report(outcome) }
    }
  }

  func load() {
    guard task == nil, acceptsAction else { return }
    let mode = QuickSaveActions.effectiveMode(mode(), modded: runtime.isModded())
    let slot = slot()
    onBusyChanged(true)
    let operation = handoff?.begin(session: session, dismiss: dismiss)
    if handoff == nil { dismiss() }
    handoff?.startInputSampling()
    task = Task { @MainActor in
      defer {
        if let operation { handoff?.complete(operation) }
        task = nil; onBusyChanged(false)
      }
      guard runtime.isCurrent(session) else { return }
      let outcome = await runtime.load(mode, slot, session)
      guard !Task.isCancelled, runtime.isCurrent(session) else { return }
      if !outcome.message.isEmpty { report(outcome) }
      if case .incompatible = outcome { openBrowser() }
    }
  }
}
