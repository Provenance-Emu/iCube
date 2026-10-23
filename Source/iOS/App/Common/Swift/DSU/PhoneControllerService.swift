// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import Foundation
import os

/// The TV's DSU server list (`DSUClient.ini`), behind a seam so tests run without the core.
protocol DSUConfigWriting {
  func entries() -> [DSUEntry]
  func add(_ entry: DSUEntry)
  func update(at index: Int, to entry: DSUEntry)
  func remove(at index: Int)
  func setEnabled(_ enabled: Bool)
}

/// `DOLConfigBridge`, which saves the config on every change.
struct LiveDSUConfigWriter: DSUConfigWriting {
  func entries() -> [DSUEntry] {
    DOLConfigBridge.dsuServersParsed().map {
      DSUEntry(description: $0["description"] as? String ?? "",
               address: $0["address"] as? String ?? "",
               port: ($0["port"] as? NSNumber)?.intValue ?? 0)
    }
  }

  func add(_ entry: DSUEntry) {
    DOLConfigBridge.addDsuServer(entry.description, address: entry.address, port: entry.port)
  }

  /// The bridge has no update call: the row is removed and added again, so it moves to the end.
  func update(at index: Int, to entry: DSUEntry) {
    remove(at: index)
    add(entry)
  }

  func remove(at index: Int) {
    DOLConfigBridge.removeDsuServer(at: index)
  }

  func setEnabled(_ enabled: Bool) {
    DOLConfigBridge.setDsuClientEnabled(enabled)
  }
}

/// tvOS: browses for phones offering themselves as a controller, asks the user once per launch for each,
/// and adds, refreshes and removes the DSU rows of the ones allowed. `PhoneControllerConnector` decides;
/// this applies its actions and keeps `PhoneConnectorState`.
///
/// Trust model: nothing connects silently. The rows this service added (`owned`) persist only so a row
/// left behind by a crash is removed at the next launch, before any phone is confirmed again.
@MainActor
final class PhoneControllerService: ObservableObject {
  static let shared = PhoneControllerService(writer: LiveDSUConfigWriter())

  /// pid -> the row this service added (description, address, port).
  static let ownedEntriesKey = "dsu_phone_controller_entries"
  /// How often a departing phone's grace is re-checked while the service runs.
  static let tickInterval: TimeInterval = 1
  private static let log = ICubeLog.logger("DSU")

  /// The phone waiting for the user's answer. One at a time: the next one is asked after this is answered.
  @Published private(set) var pendingPrompt: (pid: String, name: String)?
  /// Phones advertising as a controller now, one per pid, whether or not they are allowed.
  @Published private(set) var advertisingPhones: [DSUDiscoveredServer] = []

  private let writer: DSUConfigWriting
  private let defaults: UserDefaults
  private let now: () -> Date
  private var state = PhoneConnectorState()
  private var servers: [DSUDiscoveredServer] = []
  private var didRemoveEntriesLeftByAnEarlierLaunch = false

  private var browser: DSUDiscoveryBrowser?
  private var browserSubscription: AnyCancellable?
  private var tick: Timer?

  /// Side-effect free: nothing is read from or written to the core until `start()`.
  init(writer: DSUConfigWriting, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
    self.writer = writer
    self.defaults = defaults
    self.now = now
    state.owned = Self.ownedEntries(in: defaults)
  }

  // MARK: Lifecycle

  /// Scene became active. Browsing restarts from an empty list, so phones already connected get a
  /// fresh grace to be found again instead of being dropped and re-added.
  func start() {
    Self.log.notice("Phone controller service started (browsing for phones)")
    removeEntriesLeftByAnEarlierLaunch()
    let stamp = now()
    for pid in state.owned.keys { state.lastSeen[pid] = stamp }

    if browser == nil {
      let browser = DSUDiscoveryBrowser()
      browserSubscription = browser.$servers.sink { [weak self] servers in
        // `@Published` emits on the browser's actor, the main actor.
        MainActor.assumeIsolated { self?.refresh(servers: servers) }
      }
      self.browser = browser
    }
    browser?.start()

    tick?.invalidate()
    tick = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        // Only a departure waits on the clock; browse changes drive everything else. Skipping the
        // idle ticks keeps a running game's main thread from re-reading the config every second.
        guard let self, self.hasOwnedPhoneNotAdvertising else { return }
        self.refresh(servers: self.servers)
      }
    }
  }

  /// Scene left the foreground. The question is withdrawn and asked again on return; who was allowed
  /// or declined this launch is kept.
  func stop() {
    Self.log.notice("Phone controller service stopped")
    tick?.invalidate()
    tick = nil
    browser?.stop()
    pendingPrompt = nil
  }

  /// Once per launch: the rows an earlier launch added are removed, so every phone is confirmed again.
  func removeEntriesLeftByAnEarlierLaunch() {
    guard !didRemoveEntriesLeftByAnEarlierLaunch else { return }
    didRemoveEntriesLeftByAnEarlierLaunch = true
    for pid in state.owned.keys { removeOwnedEntry(of: pid) }
    saveOwned()
  }

  // MARK: Answers

  func respond(pid: String, allow: Bool) {
    if pendingPrompt?.pid == pid { pendingPrompt = nil }
    if allow {
      state.declined.remove(pid)
      state.confirmed.insert(pid)
    } else {
      state.confirmed.remove(pid)
      state.declined.insert(pid)
      removeOwnedEntry(of: pid)
      saveOwned()
    }
    refresh(servers: servers)
  }

  /// The user picked this phone on the TV ("Use <phone>"): that choice is the confirmation.
  func connect(pid: String) {
    respond(pid: pid, allow: true)
  }

  /// The phone has a DSU row: the one the TV added when it was allowed, or one the user added by hand
  /// at its address. The hub's "Added"; it says nothing about the phone having answered yet.
  func isAdded(pid: String) -> Bool {
    if state.owned[pid] != nil { return true }
    guard let server = advertisingPhones.first(where: { $0.advert?.pid == pid }) else { return false }
    return writer.entries().contains { $0.targets(server) }
  }

  // MARK: Discovery

  /// Applies the connector's decisions for the phones advertising now. Called on every browse change
  /// and every tick.
  func refresh(servers: [DSUDiscoveredServer]) {
    self.servers = servers
    let stamp = now()

    var phones: [DSUDiscoveredServer] = []
    for server in servers {
      guard let advert = server.advert, advert.isController,
            !phones.contains(where: { $0.advert?.pid == advert.pid }) else { continue }
      phones.append(server)
      state.lastSeen[advert.pid] = stamp
    }
    if phones != advertisingPhones { advertisingPhones = phones }

    forgetEntriesTheUserDeleted()
    let actions = PhoneControllerConnector.actions(servers: phones.map(Self.storable), entries: writer.entries(),
                                                   state: state, now: stamp)
    apply(actions, phones: phones)
  }

  // MARK: Executor

  private func apply(_ actions: [PhoneConnectorAction], phones: [DSUDiscoveredServer]) {
    func displayName(_ pid: String) -> String {
      phones.first { $0.advert?.pid == pid }?.advert?.name ?? ""
    }

    // One question at a time: keep the one up while its phone still asks, else ask the first that does.
    let prompting = actions.compactMap { action -> String? in
      if case .prompt(let pid, _) = action { return pid }
      return nil
    }
    if let current = pendingPrompt?.pid, !prompting.contains(current) { pendingPrompt = nil }
    if pendingPrompt == nil, let next = prompting.first { pendingPrompt = (next, displayName(next)) }

    var ownedChanged = false
    for action in actions {
      switch action {
      case .prompt:
        break
      case .add(let pid, let entry):
        writer.add(entry)
        // The bridge refuses an invalid address or port; only a row that landed is ours. Record it as
        // the bridge stored it (it trims the address), so later matches find it.
        guard let landed = writer.entries().last(where: { $0.description == entry.description && $0.port == entry.port })
        else { continue }
        state.owned[pid] = landed
        ownedChanged = true
        writer.setEnabled(true)
        // The phone still has to allow this TV on its own screen: nothing is connected yet.
        EmulationToast.post(String(format: L("Waiting for %@ to allow this Apple TV"), displayName(pid)))
      case .update(let pid, _, let entry):
        // Earlier actions in this batch may have moved rows: find it again by the row we recorded.
        guard let index = ownedIndex(of: pid) else { continue }
        writer.update(at: index, to: entry)
        if let landed = writer.entries().last(where: { $0.description == entry.description && $0.port == entry.port }) {
          state.owned[pid] = landed
        } else {
          state.owned[pid] = nil
        }
        ownedChanged = true
      case .remove(let pid, _):
        removeOwnedEntry(of: pid)
        ownedChanged = true
      }
    }
    if ownedChanged { saveOwned() }
  }

  /// A row the user deleted in DSU settings stays deleted: its phone counts as declined this launch,
  /// so it is neither re-added nor asked about again ("Use <phone>" can still bring it back).
  private func forgetEntriesTheUserDeleted() {
    let rows = writer.entries()
    let deleted = state.owned.filter { !rows.contains($0.value) }.map(\.key)
    guard !deleted.isEmpty else { return }
    for pid in deleted {
      state.owned[pid] = nil
      state.confirmed.remove(pid)
      state.declined.insert(pid)
    }
    saveOwned()
  }

  private var hasOwnedPhoneNotAdvertising: Bool {
    state.owned.keys.contains { pid in !advertisingPhones.contains { $0.advert?.pid == pid } }
  }

  private func ownedIndex(of pid: String) -> Int? {
    guard let owned = state.owned[pid] else { return nil }
    return writer.entries().firstIndex(of: owned)
  }

  private func removeOwnedEntry(of pid: String) {
    if let index = ownedIndex(of: pid) { writer.remove(at: index) }
    state.owned[pid] = nil
  }

  private func saveOwned() {
    Self.setOwnedEntries(state.owned, in: defaults)
  }

  static func setOwnedEntries(_ owned: [String: DSUEntry], in defaults: UserDefaults) {
    defaults.set(owned.mapValues { ["description": $0.description, "address": $0.address, "port": $0.port] },
                 forKey: ownedEntriesKey)
  }

  /// A value in another shape (a build that kept only the description) cannot be matched safely and is
  /// dropped: that build never shipped, so at worst a row it left stays for the user to delete.
  static func ownedEntries(in defaults: UserDefaults) -> [String: DSUEntry] {
    let stored = defaults.dictionary(forKey: ownedEntriesKey) ?? [:]
    return stored.compactMapValues { value in
      guard let row = value as? [String: Any], let description = row["description"] as? String,
            let address = row["address"] as? String, let port = row["port"] as? Int else { return nil }
      return DSUEntry(description: description, address: address, port: port)
    }
  }

  /// The bridge stores rows as `description:address:port;`, trims them and strips every `@`, so a
  /// name holding those characters would break its row or stop matching what we recorded.
  private static func storable(_ server: DSUDiscoveredServer) -> DSUDiscoveredServer {
    guard let advert = server.advert else { return server }
    let unsafe = CharacterSet(charactersIn: ":;@")
    let cleaned = advert.name.components(separatedBy: unsafe.union(.whitespacesAndNewlines))
      .filter { !$0.isEmpty }.joined(separator: " ")
    var copy = server
    copy.advert = DSUAdvert(pid: advert.pid, name: cleaned.isEmpty ? "iPhone" : cleaned,
                            deviceType: advert.deviceType, isController: advert.isController)
    return copy
  }
}
