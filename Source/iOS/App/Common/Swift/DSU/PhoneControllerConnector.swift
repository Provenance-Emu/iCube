// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One row of the TV's DSU server list.
struct DSUEntry: Equatable {
  let description: String
  let address: String
  let port: Int

  /// Whether this row points at `server`'s address and port, whatever it is called.
  func targets(_ server: DSUDiscoveredServer) -> Bool {
    address == server.address && port == server.port
  }
}

enum PhoneConnectorAction: Equatable {
  /// Ask the user whether this phone may be the controller.
  case prompt(pid: String, name: String)
  case add(pid: String, entry: DSUEntry)
  /// `index` is the position in the `entries` array `actions` was given.
  case update(pid: String, index: Int, entry: DSUEntry)
  case remove(pid: String, index: Int)
}

struct PhoneConnectorState: Equatable {
  /// Phones allowed this TV launch.
  var confirmed: Set<String> = []
  /// Phones answered "Not Now" this launch.
  var declined: Set<String> = []
  /// pid -> the entry we added for it (persisted). Rows are matched on description, address and
  /// port together, so a manual row that shares a name is never mistaken for ours.
  var owned: [String: DSUEntry] = [:]
  /// When each phone was last advertised as a controller. Kept by the caller from discovery.
  var lastSeen: [String: Date] = [:]
}

/// Decides when the TV prompts for, adds, refreshes and removes a phone's DSU entry.
/// Pure: the caller applies the actions and keeps `PhoneConnectorState`.
enum PhoneControllerConnector {
  /// How long an owned phone may go unadvertised before its entry is removed.
  static let departureGrace: TimeInterval = 10

  /// Actions are ordered prompts/adds/updates first, then removes by descending index,
  /// so applying them in order never invalidates a later index.
  static func actions(servers: [DSUDiscoveredServer], entries: [DSUEntry],
                      state: PhoneConnectorState, now: Date) -> [PhoneConnectorAction] {
    var advertised: [(pid: String, name: String, server: DSUDiscoveredServer)] = []
    for server in servers {
      guard let advert = server.advert, advert.isController,
            !advertised.contains(where: { $0.pid == advert.pid }) else { continue }
      advertised.append((advert.pid, advert.name, server))
    }

    var actions: [PhoneConnectorAction] = []
    var removals: [(pid: String, index: Int)] = []
    var taken = entries.map(\.description)

    for phone in advertised {
      let pid = phone.pid
      // The phone already has a row of the user's (added by hand, at its address and port): the core
      // reaches it through that row, so it is in. A second row would seat it twice.
      if state.owned[pid] == nil, entries.contains(where: { $0.targets(phone.server) }) { continue }
      guard state.confirmed.contains(pid) else {
        if !state.declined.contains(pid) { actions.append(.prompt(pid: pid, name: phone.name)) }
        continue
      }
      guard let ownedEntry = state.owned[pid] else {
        let description = uniqueDescription(for: phone.name, taken: taken)
        taken.append(description)
        actions.append(.add(pid: pid, entry: DSUEntry(description: description,
                                                      address: phone.server.address,
                                                      port: phone.server.port)))
        continue
      }
      if let index = entries.firstIndex(of: ownedEntry), !ownedEntry.targets(phone.server) {
        // It moved to an address one of the user's rows already points at: that row carries it now.
        if entries.contains(where: { $0 != ownedEntry && $0.targets(phone.server) }) {
          removals.append((pid, index))
          continue
        }
        actions.append(.update(pid: pid, index: index,
                               entry: DSUEntry(description: ownedEntry.description,
                                               address: phone.server.address,
                                               port: phone.server.port)))
      }
    }

    let present = Set(advertised.map(\.pid))
    for (pid, ownedEntry) in state.owned where !present.contains(pid) {
      let lastSeen = state.lastSeen[pid] ?? .distantPast
      guard now.timeIntervalSince(lastSeen) > departureGrace,
            let index = entries.firstIndex(of: ownedEntry) else { continue }
      removals.append((pid, index))
    }
    let ordered = removals.sorted { $0.index > $1.index }.map { PhoneConnectorAction.remove(pid: $0.pid, index: $0.index) }
    return actions + ordered
  }

  /// `name`, else `name (2)`, `name (3)`... — the first not in `taken`.
  static func uniqueDescription(for name: String, taken: [String]) -> String {
    guard taken.contains(name) else { return name }
    var n = 2
    while taken.contains("\(name) (\(n))") { n += 1 }
    return "\(name) (\(n))"
  }
}
