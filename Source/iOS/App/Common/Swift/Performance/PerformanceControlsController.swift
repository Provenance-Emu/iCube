// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Combine

/// Shared UI state and the single manual-write admission boundary. Use from the main thread.
final class PerformanceControlsController: ObservableObject {
  @Published private(set) var state: PerformanceControlsState
  private let read: () -> PerformanceControlsState
  private let write: (PerformanceControlChange) -> Void
  private let sessionIdentifier: () -> UInt64
  private var currentSession: UInt64
  private var reconciliationGeneration: UInt64 = 0
  private var reconciliationTarget: Bool?
  private let scheduleRefresh: (@escaping () -> Void) -> Void

  init(read: @escaping () -> PerformanceControlsState,
       apply: @escaping (PerformanceControlChange) -> Void,
       sessionIdentifier: @escaping () -> UInt64 = { 0 },
       scheduleRefresh: @escaping (@escaping () -> Void) -> Void = { action in
         DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: action)
       }) {
    self.read = read
    self.sessionIdentifier = sessionIdentifier
    currentSession = sessionIdentifier()
    self.write = apply
    self.scheduleRefresh = scheduleRefresh
    state = Self.manualSnapshot(read())
  }

  /// Call on every opening; no refresh is ever allowed to persist values.
  func refresh() {
    stopRefreshing()
    currentSession = sessionIdentifier()
    state = Self.manualSnapshot(read())
    // A reopened surface may still be waiting for the previous CurrentRun clear.
    if !state.adaptiveClock && (state.cpuOverride == .auto || state.viOverride == .auto) {
      reconciliationTarget = false
      scheduleReconciliation()
    }
  }

  /// Close/disappear cancels polling; refresh on the next opening resumes any outstanding clear.
  /// Scheduled work holds only a weak reference, so disposal also stops it automatically.
  func stopRefreshing() {
    reconciliationGeneration &+= 1
    reconciliationTarget = nil
  }

  func apply(_ change: PerformanceControlChange) {
    guard currentSession == sessionIdentifier() else { stopRefreshing(); return }
    let accepted: PerformanceControlChange
    switch change {
    case .cpuEnabled(let value):
      guard state.cpuOverride == .none else { return }
      write(.cpuEnabled(value))
      if value { write(.cpuPercent(Self.percent(state.cpuPercent))) }
      refresh()
      return
    case .viEnabled(let value):
      guard state.viOverride == .none else { return }
      write(.viEnabled(value))
      if value { write(.viPercent(Self.percent(state.viPercent))) }
      refresh()
      return
    case .cpuPercent(let value):
      guard state.cpuOverride == .none else { return }
      accepted = .cpuPercent(Self.percent(value))
    case .viPercent(let value):
      guard state.viOverride == .none else { return }
      accepted = .viPercent(Self.percent(value))
    case .resolutionScale(let value):
      guard state.scalingOverride == .none else { return }
      accepted = .resolutionScale(min(max(1, state.maxResolutionScale), max(0, value)))
    case .anisotropy(let value):
      accepted = .anisotropy(min(16, max(1, value)))
    case .adaptiveClock(let value):
      // The backend queues CurrentRun changes asynchronously. Publish the lock BEFORE calling it.
      // On disable retain ownership until that queue has actually cleared its overrides.
      stopRefreshing()
      reconciliationTarget = value
      state.adaptiveClock = value
      if value {
        state.cpuOverride = .auto
        state.viOverride = .auto
      }
      write(change)
      scheduleReconciliation()
      return
    case .viSkipMode, .hudEnabled, .hudStatistic:
      accepted = change
    }
    write(accepted)
    refresh()
  }

  private func scheduleReconciliation() {
    let generation = reconciliationGeneration
    let session = currentSession
    scheduleRefresh { [weak self] in
      guard let self, self.reconciliationGeneration == generation,
            self.currentSession == session, self.sessionIdentifier() == session,
            let target = self.reconciliationTarget else { return }
      let snapshot = self.read()
      // The preference setter is synchronous in the app backend, but retain the immediate UI
      // ownership until both the preference and queued native changes have caught up.
      if snapshot.adaptiveClock == target {
        self.state = Self.manualSnapshot(snapshot)
        if target || (snapshot.cpuOverride != .auto && snapshot.viOverride != .auto) {
          self.reconciliationTarget = nil
          return
        }
      }
      self.scheduleReconciliation()
    }
  }

  private static func percent(_ value: Int) -> Int { min(400, max(1, value)) }

  private static func manualSnapshot(_ value: PerformanceControlsState) -> PerformanceControlsState {
    var result = value
    // Preference ownership is immediate even before the first timer / CurrentRun job executes.
    if result.adaptiveClock {
      result.cpuOverride = .auto
      result.viOverride = .auto
    }
    return result
  }
}
