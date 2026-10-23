// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import Foundation

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

  /// pid -> description of the row this service added.
  static let ownedEntriesKey = "dsu_phone_controller_entries"
  /// How often a departing phone's grace is re-checked while the service runs.
  static let tickInterval: TimeInterval = 1

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
    state.owned = defaults.dictionary(forKey: Self.ownedEntriesKey) as? [String: String] ?? [:]
  }

  // MARK: Lifecycle

  /// Scene became active. Browsing restarts from an empty list, so phones already connected get a
  /// fresh grace to be found again instead of being dropped and re-added.
  func start() {
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

  /// The phone's DSU row is in (the TV allowed it): the hub's "Connected".
  func isConnected(pid: String) -> Bool {
    state.owned[pid] != nil
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
        // The bridge refuses an invalid address or port; only a row that landed is ours.
        guard writer.entries().contains(where: { $0.description == entry.description }) else { continue }
        state.owned[pid] = entry.description
        ownedChanged = true
        writer.setEnabled(true)
        EmulationToast.post(String(format: L("%@ is connected as a controller"), displayName(pid)))
      case .update(let pid, _, let entry):
        // Earlier actions in this batch may have moved rows: find it again by what we named it.
        if let index = ownedIndex(of: pid) { writer.update(at: index, to: entry) }
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
    let descriptions = Set(writer.entries().map(\.description))
    let deleted = state.owned.filter { !descriptions.contains($0.value) }.map(\.key)
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
    guard let description = state.owned[pid] else { return nil }
    return writer.entries().firstIndex { $0.description == description }
  }

  private func removeOwnedEntry(of pid: String) {
    if let index = ownedIndex(of: pid) { writer.remove(at: index) }
    state.owned[pid] = nil
  }

  private func saveOwned() {
    defaults.set(state.owned, forKey: Self.ownedEntriesKey)
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
