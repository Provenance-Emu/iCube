// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

struct EmulationServerAdvertisement: Equatable {
  let id: UUID
  let name: String
  let server: EmulationServer

  init?(host: String, port: Int, txt: [String: Data]) {
    func value(_ key: String) -> String? { txt[key].flatMap { String(data: $0, encoding: .utf8) } }

    guard value("v") == "1", let id = value("id").flatMap(UUID.init(uuidString:)),
          let tls = value("tls"), tls == "0" || tls == "1",
          let name = value("name"), !name.isEmpty, name.count <= 63,
          (1 ... 65535).contains(port) else { return nil }

    // Keep the resolved hostname for certificate validation on HTTPS servers.
    let hostname = host.hasSuffix(".") ? String(host.dropLast()) : host
    var components = URLComponents()
    components.scheme = tls == "1" ? "https" : "http"
    components.host = hostname
    components.port = port
    guard let address = components.url?.absoluteString,
          let server = try? EmulationServer(address: address) else { return nil }
    self.id = id
    self.name = name
    self.server = server
  }
}

/// Resolves Emulation Server adverts without requesting a catalog or using credentials.
@MainActor
final class EmulationServerDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
  var onChange: ([EmulationServerAdvertisement]) -> Void = { _ in }

  private var browser: NetServiceBrowser?
  private var services: [NetService] = []
  private var resolved: [ObjectIdentifier: EmulationServerAdvertisement] = [:]

  func setBrowsing(_ enabled: Bool) {
    if enabled {
      guard browser == nil else { return }
      let browser = NetServiceBrowser()
      self.browser = browser
      browser.delegate = self
      browser.searchForServices(ofType: "_pvcontent._tcp.", inDomain: "local.")
    } else {
      guard let browser else { return }
      self.browser = nil
      browser.stop()
      services.forEach(stop)
      services.removeAll()
      resolved.removeAll()
      onChange([])
    }
  }

  private func stop(_ service: NetService) {
    service.delegate = nil
    service.stopMonitoring()
    service.stop()
  }

  private func index(of service: NetService) -> Int? {
    services.firstIndex { $0.name == service.name && $0.type == service.type && $0.domain == service.domain }
  }

  nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
    Task { @MainActor in
      guard browser === self.browser, index(of: service) == nil else { return }
      services.append(service)
      service.delegate = self
      service.resolve(withTimeout: 5)
    }
  }

  nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
    Task { @MainActor in
      guard browser === self.browser, let index = index(of: service) else { return }
      let removed = services.remove(at: index)
      stop(removed)
      if resolved.removeValue(forKey: ObjectIdentifier(removed)) != nil {
        onChange(Array(resolved.values))
      }
    }
  }

  nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
    Task { @MainActor in
      guard services.contains(where: { $0 === sender }) else { return }
      update(sender, txt: sender.txtRecordData())
      sender.startMonitoring()
    }
  }

  nonisolated func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
    Task { @MainActor in update(sender, txt: data) }
  }

  private func update(_ service: NetService, txt: Data?) {
    guard services.contains(where: { $0 === service }) else { return }
    let key = ObjectIdentifier(service)
    let advertisement = txt.flatMap { data in
      service.hostName.flatMap { EmulationServerAdvertisement(host: $0, port: service.port, txt: NetService.dictionary(fromTXTRecord: data)) }
    }
    guard resolved[key] != advertisement else { return }
    resolved[key] = advertisement
    onChange(Array(resolved.values))
  }
}
