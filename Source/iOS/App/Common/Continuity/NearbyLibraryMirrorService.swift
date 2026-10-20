// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Combine
import Foundation
import PVContinuity
import UIKit

/// Connects the foreground mirror scheduler to paired discovery and verified imports.
@MainActor
final class NearbyLibraryMirrorService: ObservableObject {
  @Published private(set) var state: NearbyLibraryMirror.State = .disabled
  @Published private(set) var enabledPeerIDs = Set<String>()
  @Published private(set) var progress: PullProgress?
  private static let preferenceKey = "icube.nearbyLibraryMirror.peerIDs"
  private weak var manager: ContinuityManager?
  private let defaults: UserDefaults
  private var scheduler: NearbyLibraryMirror!
  private var active = UIApplication.shared.applicationState == .active
  private var controller: ContinuityLibraryBrowseController?
  private var controllerPeerID: String?
  private var entries: [String: [String: ContinuityLibraryEntry]] = [:]
  private var observation: AnyCancellable?
  private var observers: [NSObjectProtocol] = []
  private var restored = false
  private var receipts: [String: ContinuityVerifiedFileReceipt] = [:]
  private var currentDescriptors: [String: [String: [FileDescriptor]]] = [:]

  init(manager: ContinuityManager, defaults: UserDefaults = .standard) {
    self.manager = manager
    self.defaults = defaults
    scheduler = NearbyLibraryMirror(
      catalog: { [weak self] peer in try await self?.catalog(peer) ?? [] },
      copy: { [weak self] peer, entry in
        guard let self else { throw CancellationError() }
        try await self.copy(peer, entry: entry)
      },
      cancel: { [weak self] in self?.controller?.cancel() },
      isTrusted: { [weak manager] id in manager?.trustedPeers.contains { $0.id == id } == true },
      isDiscovered: { [weak self] id in self?.advertisement(for: id) != nil },
      isActive: { [weak self] in self?.active == true },
      isEmulating: { EmulationState.shared.isActive || SyncLocalIOGate.shared.isEmulating },
      isPresent: { [weak self] peer, entry in self?.hasVerifiedCopy(peer: peer, entry: entry) == true }
    )
    scheduler.onChange = { [weak self] in self?.publish() }
    for (name, foreground) in [(UIApplication.didBecomeActiveNotification, true),
                               (UIApplication.willResignActiveNotification, false)] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.active = foreground
          self?.environmentChanged()
        }
      })
    }
    EmulationState.shared.addTransitionHandler { [weak self] _ in self?.environmentChanged() }
    environmentChanged()
  }

  deinit {
    for token in observers { NotificationCenter.default.removeObserver(token) }
  }

  func setEnabled(_ enabled: Bool, for peerID: String) {
    scheduler.setEnabled(enabled, for: peerID)
  }

  func retry() { scheduler.retry() }

  func disableAll() {
    for id in scheduler.enabledPeerIDs { scheduler.setEnabled(false, for: id) }
  }

  func environmentChanged() {
    guard let manager, manager.hasLoadedTrustedPeers else { return }
    if !restored {
      restored = true
      for id in defaults.stringArray(forKey: Self.preferenceKey) ?? [] {
        scheduler.setEnabled(true, for: id)
      }
    }
    scheduler.environmentChanged()
    publish()
  }

  func peerName(_ id: String) -> String {
    manager?.trustedPeers.first { $0.id == id }?.name ?? id
  }

  func entryName(peer: String, entry: String) -> String {
    entries[peer]?[entry]?.game.displayName ?? entry
  }

  private func publish() {
    state = scheduler.state
    enabledPeerIDs = scheduler.enabledPeerIDs
    defaults.set(enabledPeerIDs.sorted(), forKey: Self.preferenceKey)
    manager?.setMirrorBrowsingRequired(!enabledPeerIDs.isEmpty && active)
    if case .copying = state {} else { progress = nil }
  }

  private func advertisement(for peerID: String) -> ContinuityAdvertisement? {
    manager?.discoveredPeers.compactMap(\.advertisement).first {
      $0.peerId == peerID && $0.sharesLibrary && !$0.urlCandidates.isEmpty
    }
  }

  private func catalog(_ peerID: String) async throws -> [NearbyLibraryMirror.Entry] {
    guard let manager, let advertisement = advertisement(for: peerID) else {
      throw CancellationError()
    }
    // This instance is separate from a user's manual browse/copy operation.
    let browser = ContinuityLibraryBrowseController(identity: manager.identity)
    controller = browser
    controllerPeerID = peerID
    observation = browser.$phase.sink { [weak self] phase in
      MainActor.assumeIsolated {
        if case .copying(_, let progress) = phase { self?.progress = progress }
      }
    }
    await browser.load(from: advertisement, allowsPairing: false)
    try Task.checkCancellation()
    guard case .browsing(let catalog) = browser.phase else {
      let phase = browser.phase
      browser.cancel()
      throw failure(for: phase)
    }
    var descriptors: [String: [FileDescriptor]] = [:]
    for item in catalog where receipts[receiptKey(peerID, item.key)] != nil {
      descriptors[item.key] = try await browser.validatedManifest(for: item).files
    }
    try Task.checkCancellation()
    currentDescriptors[peerID] = descriptors
    entries[peerID] = Dictionary(catalog.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    return catalog.map { .init(id: $0.key) }
  }

  private func copy(_ peerID: String, entry: NearbyLibraryMirror.Entry) async throws {
    guard controllerPeerID == peerID, let controller, let item = entries[peerID]?[entry.id] else {
      throw CancellationError()
    }
    await controller.copy(item)
    try Task.checkCancellation()
    guard case .copied = controller.phase, !controller.copiedFileURLs.isEmpty else {
      throw failure(for: controller.phase)
    }
    receipts[receiptKey(peerID, entry.id)] = try ContinuityVerifiedFileReceipt(
      descriptors: controller.verifiedDescriptors, urls: controller.copiedFileURLs)
  }

  private func hasVerifiedCopy(peer: String, entry: NearbyLibraryMirror.Entry) -> Bool {
    guard let receipt = receipts[receiptKey(peer, entry.id)],
          let descriptors = currentDescriptors[peer]?[entry.id] else { return false }
    return receipt.matches(current: descriptors)
  }

  private func receiptKey(_ peer: String, _ entry: String) -> String { peer + "\n" + entry }

  private func failure(for phase: ContinuityLibraryBrowseController.Phase) -> Error {
    let message: String
    switch phase {
    case .failed(let reason): message = reason
    case .awaitingPairing: message = L("Pair this device again in Nearby before enabling automatic copying.")
    default: message = L("The game could not be verified and added to this library.")
    }
    return NSError(domain: "iCube.NearbyLibraryMirror", code: 1,
                   userInfo: [NSLocalizedDescriptionKey: message])
  }
}
