// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// A boot closes admission synchronously, then its worker drains existing local I/O.
/// A lease may span an actor hop; the condition lock never spans I/O or an await.
final class SyncLocalIOGate: @unchecked Sendable {
  static let shared = SyncLocalIOGate()
  private let condition = NSCondition()
  private var emulating = false
  private var localIOCount = 0
  private var generation: UInt64 = 0

  var isEmulating: Bool {
    condition.lock()
    defer { condition.unlock() }
    return emulating
  }

  var currentGeneration: UInt64 {
    condition.lock()
    defer { condition.unlock() }
    return generation
  }

  @discardableResult
  func beginEmulation() -> UInt64 {
    condition.lock()
    defer { condition.unlock() }
    generation &+= 1
    emulating = true
    return generation
  }

  /// Direct policy callers reuse the epoch closed by the synchronous WillStart observer.
  func ensureEmulation() -> UInt64 {
    condition.lock()
    defer { condition.unlock() }
    if !emulating { generation &+= 1; emulating = true }
    return generation
  }

  @discardableResult
  func ensureEmulation(generation expectedGeneration: UInt64) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    guard generation == expectedGeneration else { return false }
    emulating = true
    return true
  }

  func isCurrentEmulation(_ expectedGeneration: UInt64) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    return generation == expectedGeneration && emulating
  }

  func isCurrentDrain(_ expectedGeneration: UInt64) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    return generation == expectedGeneration && !emulating
  }

  /// Called only after true core Uninitialized. An old teardown cannot open a new boot.
  @discardableResult
  func finishCoreDrain(generation expectedGeneration: UInt64) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    guard generation == expectedGeneration else { return false }
    emulating = false
    return true
  }

  /// Convenience for callers that already know this is the current physical drain.
  func endEmulation() {
    _ = finishCoreDrain(generation: currentGeneration)
  }

  func beginLocalIO(generation expectedGeneration: UInt64? = nil) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    guard !emulating, expectedGeneration == nil || expectedGeneration == generation else { return false }
    localIOCount += 1
    return true
  }

  func endLocalIO() {
    condition.lock()
    precondition(localIOCount > 0, "Every local I/O lease must be released exactly once")
    localIOCount -= 1
    if localIOCount == 0 { condition.broadcast() }
    condition.unlock()
  }

  /// Called on the emulation worker, never MainActor, before the core opens User files.
  func waitForLocalIO() {
    condition.lock()
    defer { condition.unlock() }
    while localIOCount > 0 { condition.wait() }
  }
}
