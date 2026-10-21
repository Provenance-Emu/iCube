// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Presentation owns no pause token. Transitions give the caller time to claim its own token.
final class LivePerformanceOwnership {
  private(set) var isPresented = false
  private var session: String?
  func open(session: String) -> Bool {
    guard !isPresented else { return false }
    self.session = session
    isPresented = true
    return true
  }
  func close() { isPresented = false; session = nil }
  func reconcile(session: String?) { if self.session != session { close() } }
  func transitionToPause(claim: () -> Void) {
    guard isPresented else { return }
    claim()
    close()
  }
}

/// Physical remote polling only. Initial held controls must become neutral; Select never repeats.
struct LivePerformanceRemoteInput {
  enum Action: Equatable { case up, down, left, right, select }
  private var awaitingNeutral = true
  private var previousSelect = false
  private var direction: Action?
  private var nextRepeat: TimeInterval = 0

  mutating func poll(horizontal: Float, vertical: Float, select: Bool, now: TimeInterval) -> [Action] {
    let neutral = abs(horizontal) < 0.2 && abs(vertical) < 0.2 && !select
    if awaitingNeutral {
      if neutral { awaitingNeutral = false }
      return []
    }
    var actions: [Action] = []
    let current: Action?
    if abs(vertical) >= 0.5 && abs(vertical) >= abs(horizontal) { current = vertical > 0 ? .up : .down }
    else if abs(horizontal) >= 0.5 { current = horizontal > 0 ? .right : .left }
    else { current = nil }
    if let current {
      if direction != current { actions.append(current); nextRepeat = now + 0.4 }
      else if now >= nextRepeat { actions.append(current); nextRepeat = now + 0.09 }
    }
    direction = current
    if select && !previousSelect { actions.append(.select) }
    previousSelect = select
    return actions
  }
}

/// Keeps native leases alive after the view disappears. Identity, never product/player index,
/// decides which disconnected controller can bypass the neutral fence.
final class LivePerformanceReleaseFence<Controller: AnyObject> {
  private struct Entry {
    let controller: Controller
    let poll: () -> Bool
    let disconnect: () -> Void
  }
  private var entries: [Entry] = []
  var isEmpty: Bool { entries.isEmpty }
  func retain(controller: Controller, request: () -> Void, poll: @escaping () -> Bool, disconnect: @escaping () -> Void) {
    request()
    entries.append(Entry(controller: controller, poll: poll, disconnect: disconnect))
  }
  func reap(connected: [Controller]) {
    entries.removeAll { entry in
      if !connected.contains(where: { $0 === entry.controller }) { entry.disconnect(); return true }
      return entry.poll()
    }
  }
}
