// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Foreground-only, opt-in additive ROM mirroring. The adapter owns authentication,
/// manifest/path validation and durable verified import; this type only schedules work.
@MainActor
final class NearbyLibraryMirror {
  struct Entry: Hashable, Sendable {
    /// A distinct catalog resource, including disc/revision/format identity.
    let id: String
  }

  enum State: Equatable {
    case disabled
    case waiting
    case checking(peerID: String)
    case copying(peerID: String, entryID: String)
    case upToDate
    case failed(peerID: String, message: String)
  }

  typealias Cancellation = @MainActor () -> Void
  typealias Scheduler = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Cancellation

  private(set) var enabledPeerIDs = Set<String>()
  private(set) var state: State = .disabled { didSet { onChange?() } }
  var onChange: (@MainActor () -> Void)?

  private let catalog: @MainActor (String) async throws -> [Entry]
  private let copy: @MainActor (String, Entry) async throws -> Void
  private let cancel: Cancellation
  private let isTrusted: @MainActor (String) -> Bool
  private let isDiscovered: @MainActor (String) -> Bool
  private let isActive: @MainActor () -> Bool
  private let isEmulating: @MainActor () -> Bool
  private let isPresent: @MainActor (String, Entry) -> Bool
  private let schedule: Scheduler
  private var task: Task<Void, Never>?
  private var cancelTimer: Cancellation?
  private var epoch: UInt64 = 0
  private var currentPeer: String?
  private var taskEpoch: UInt64?
  private var stopped = false

  init(
    catalog: @escaping @MainActor (String) async throws -> [Entry],
    copy: @escaping @MainActor (String, Entry) async throws -> Void,
    cancel: @escaping Cancellation,
    isTrusted: @escaping @MainActor (String) -> Bool,
    isDiscovered: @escaping @MainActor (String) -> Bool,
    isActive: @escaping @MainActor () -> Bool,
    isEmulating: @escaping @MainActor () -> Bool,
    isPresent: @escaping @MainActor (String, Entry) -> Bool = { _, _ in false },
    schedule: @escaping Scheduler = NearbyLibraryMirror.scheduleAfterDelay
  ) {
    self.catalog = catalog; self.copy = copy; self.cancel = cancel
    self.isTrusted = isTrusted; self.isDiscovered = isDiscovered
    self.isActive = isActive; self.isEmulating = isEmulating
    self.isPresent = isPresent; self.schedule = schedule
  }

  func setEnabled(_ enabled: Bool, for peerID: String) {
    guard !peerID.isEmpty else { return }
    if enabled {
      guard isTrusted(peerID) else { return }
      enabledPeerIDs.insert(peerID)
    } else {
      enabledPeerIDs.remove(peerID)
    }
    stopped = false
    environmentChanged()
    onChange?()
  }

  /// Call when discovery, pairing trust, foreground or emulation ownership changes.
  func environmentChanged() {
    stopped = false
    reconcile()
  }

  func retry() {
    stopped = false
    if case .failed = state { state = .waiting }
    reconcile()
  }

  /// Cancels pending work without forgetting opt-ins. A later explicit event resumes.
  func stop() {
    stopped = true
    invalidate()
    state = enabledPeerIDs.isEmpty ? .disabled : .waiting
  }

  private func eligible(_ peerID: String) -> Bool {
    !stopped && isActive() && !isEmulating() && enabledPeerIDs.contains(peerID)
      && isTrusted(peerID) && isDiscovered(peerID)
  }

  private func reconcile() {
    let trustedIDs = enabledPeerIDs.filter(isTrusted)
    if trustedIDs != enabledPeerIDs {
      enabledPeerIDs = trustedIDs
      onChange?()
    }
    let peers = enabledPeerIDs.filter(eligible).sorted()
    if peers.isEmpty || (currentPeer.map { !eligible($0) } ?? false) {
      invalidate()
      state = enabledPeerIDs.isEmpty ? .disabled : .waiting
    }
    guard !peers.isEmpty, !stopped, task == nil else { return }
    if case .failed = state { return }
    cancelTimer?(); cancelTimer = nil
    let token = epoch
    taskEpoch = token
    // Publish checking synchronously, avoiding an up-to-date state during a queued pass.
    currentPeer = peers[0]
    state = .checking(peerID: peers[0])
    task = Task { [weak self] in
      guard let self else { return }
      await self.run(peers, token: token)
      self.finished(token: token)
    }
  }

  private func invalidate() {
    cancelTimer?(); cancelTimer = nil
    if task != nil, taskEpoch == epoch {
      epoch &+= 1
      task?.cancel()
      cancel()
    } else if task == nil {
      epoch &+= 1
    }
  }

  private func run(_ peers: [String], token: UInt64) async {
    for peer in peers {
      guard token == epoch, !Task.isCancelled else { return }
      // Other peers may disappear while an earlier peer's copy is running.
      guard eligible(peer) else { continue }
      currentPeer = peer
      state = .checking(peerID: peer)
      do {
        let entries = try await catalog(peer)
        guard token == epoch, eligible(peer), !Task.isCancelled else { return }
        var seen = Set<String>()
        for entry in entries where !entry.id.isEmpty && seen.insert(entry.id).inserted {
          guard token == epoch, eligible(peer), !Task.isCancelled else { return }
          if isPresent(peer, entry) { continue }
          state = .copying(peerID: peer, entryID: entry.id)
          try await copy(peer, entry)
          guard token == epoch, eligible(peer), !Task.isCancelled else { return }
        }
      } catch {
        guard token == epoch, eligible(peer), !Task.isCancelled else { return }
        state = .failed(peerID: peer, message: error.localizedDescription)
        return
      }
    }
    guard token == epoch, !Task.isCancelled else { return }
    state = .upToDate
  }

  private func finished(token: UInt64) {
    task = nil; taskEpoch = nil; currentPeer = nil
    if token != epoch {
      // Keep the old task until it exits: even an uncooperative cancellation
      // cannot overlap its physical copy with a replacement task.
      if !stopped { reconcile() }
      return
    }
    guard !stopped, enabledPeerIDs.contains(where: eligible) else { return }
    if case .failed = state { return }
    cancelTimer = schedule(60) { [weak self] in
      guard let self, token == self.epoch else { return }
      self.cancelTimer = nil
      self.reconcile()
    }
  }

  private static func scheduleAfterDelay(_ delay: TimeInterval, _ callback: @escaping @MainActor () -> Void) -> Cancellation {
    let timer = Task { @MainActor in
      do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
      catch { return }
      guard !Task.isCancelled else { return }
      callback()
    }
    return { timer.cancel() }
  }
}
