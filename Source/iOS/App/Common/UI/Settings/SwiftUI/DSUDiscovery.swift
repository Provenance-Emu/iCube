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

// MARK: - DSU Bonjour Discovery

struct DSUDiscoveredServer: Identifiable, Equatable {
  let id = UUID()
  let name: String
  let address: String
  let port: Int

  static func == (lhs: DSUDiscoveredServer, rhs: DSUDiscoveredServer) -> Bool {
    return lhs.address == rhs.address && lhs.port == rhs.port
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
    services.forEach { $0.stop() }
    services.removeAll()
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
      let port = sender.port
      let name = sender.name
      let item = DSUDiscoveredServer(name: name.isEmpty ? "DSU" : name, address: ip, port: port)
      if !servers.contains(item) {
        servers.append(item)
      }
    }
  }
}
