// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit
import CoreHaptics
import QuartzCore
import PVWebServer
import PVHelp
#if os(iOS)
import SafariServices
import AudioToolbox
#endif
#if canImport(GameController)
import GameController
#endif
#if os(iOS)
#endif
import Foundation
import os

// MARK: - DSU Bonjour Discovery

struct DSUDiscoveredServer: Identifiable, Equatable {
  let id = UUID()
  let name: String
  let address: String
  let port: Int
  /// Who the server says it is, when it is a phone publishing a DSU advert.
  var advert: DSUAdvert?

  static func == (lhs: DSUDiscoveredServer, rhs: DSUDiscoveredServer) -> Bool {
    return lhs.address == rhs.address && lhs.port == rhs.port && lhs.advert?.pid == rhs.advert?.pid
  }
}

@MainActor
final class DSUDiscoveryBrowser: NSObject, ObservableObject {
  @Published var servers: [DSUDiscoveredServer] = []

  private var browser: NetServiceBrowser?
  private var services: [NetService] = []

  func start() {
    stop()
    servers.removeAll()
    services.removeAll()
    let b = NetServiceBrowser()
    b.delegate = self
    browser = b
    b.searchForServices(ofType: "_dolphin-dsu._udp", inDomain: "local.")
  }

  func stop() {
    browser?.stop()
    browser = nil
    services.forEach {
      $0.stopMonitoring()
      $0.stop()
    }
    services.removeAll()
  }

  /// The row a resolve produced, in place of the service's earlier row. Nil when nothing changed, so
  /// an unchanged resolve does not republish the list. The advert counts in full: a phone that only
  /// gained or lost the controller role is a change.
  nonisolated static func upserting(_ item: DSUDiscoveredServer, into servers: [DSUDiscoveredServer]) -> [DSUDiscoveredServer]? {
    if let existing = servers.first(where: { $0.name == item.name }),
       existing.address == item.address, existing.port == item.port, existing.advert == item.advert {
      return nil
    }
    var updated = servers
    updated.removeAll { $0.name == item.name }
    updated.append(item)
    return updated
  }

  /// A service's TXT record changed (a phone starting or leaving its controller session): its row
  /// takes the new advert. Nil when the service has no row yet or its advert is unchanged.
  nonisolated static func updatingAdvert(_ advert: DSUAdvert?, ofServiceNamed name: String,
                             in servers: [DSUDiscoveredServer]) -> [DSUDiscoveredServer]? {
    guard let index = servers.firstIndex(where: { $0.name == name }), servers[index].advert != advert else { return nil }
    var updated = servers
    updated[index].advert = advert
    return updated
  }

  nonisolated fileprivate static func rowName(_ service: NetService) -> String {
    service.name.isEmpty ? "DSU" : service.name
  }

  nonisolated fileprivate static func advert(of service: NetService) -> DSUAdvert? {
    service.txtRecordData().flatMap { DSUAdvert.parse(NetService.dictionary(fromTXTRecord: $0)) }
  }
}

extension DSUDiscoveryBrowser: NetServiceBrowserDelegate {
  nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
    Task { @MainActor in
      service.delegate = self
      services.append(service)
      service.resolve(withTimeout: 5.0)
    }
  }

  nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
    Task { @MainActor in
      service.stopMonitoring()
      services.removeAll { $0 == service }
      if let name = service.name as String? {
        servers.removeAll { $0.name == name }
      }
    }
  }
}

extension DSUDiscoveryBrowser: NetServiceDelegate {
  nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
    Task { @MainActor in
      guard let addresses = sender.addresses, !addresses.isEmpty else { return }
      var ipv4: String?
      for data in addresses {
        data.withUnsafeBytes { (rawPtr: UnsafeRawBufferPointer) in
          guard let sa = rawPtr.bindMemory(to: sockaddr.self).baseAddress else { return }
          if sa.pointee.sa_family == sa_family_t(AF_INET) {
            let sin = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in.self).pointee
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var addr = sin.sin_addr
            inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
            ipv4 = String(cString: buf)
          }
        }
        if ipv4 != nil { break }
      }
      guard let ip = ipv4 else { return }
      let item = DSUDiscoveredServer(name: Self.rowName(sender), address: ip, port: sender.port,
                                     advert: Self.advert(of: sender))
      // The same service resolving again with a new address or advert replaces its old row.
      if let updated = Self.upserting(item, into: servers) { servers = updated }
      // The TXT record is read once here; later changes (the controller role) arrive as updates.
      sender.startMonitoring()
    }
  }

  nonisolated func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
    Task { @MainActor in
      let advert = DSUAdvert.parse(NetService.dictionary(fromTXTRecord: data))
      if let updated = Self.updatingAdvert(advert, ofServiceNamed: Self.rowName(sender), in: servers) {
        ICubeLog.logger("DSU").notice(
          "DSU advert updated for \(sender.name, privacy: .public): controller \(advert?.isController ?? false, privacy: .public)")
        servers = updated
      }
      // An update can come with a new address (the phone moved networks): resolve again to pick it up.
      sender.resolve(withTimeout: 5.0)
    }
  }
}
