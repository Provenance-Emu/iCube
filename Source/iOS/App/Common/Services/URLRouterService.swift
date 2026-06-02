// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit

final class URLRouterService: NSObject, UIApplicationDelegate {
  func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
    // Supported:
    // dolphinios://dsu/add?ip=192.168.1.23&port=26760&desc=My%20iPhone
    // Also accept legacy: dsu://192.168.1.23:26760
    if handleDSULink(url) { return true }
    return false
  }

  private func handleDSULink(_ url: URL) -> Bool {
    if url.scheme?.lowercased() == "dolphinios" {
      // Path-based routing
      guard url.host?.lowercased() == "dsu" else { return false }
      let path = url.path.lowercased()
      guard path == "/add" else { return false }
      let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
      var ip: String?
      var port: Int?
      var desc: String = "DSU"
      comps?.queryItems?.forEach { item in
        switch item.name.lowercased() {
        case "ip": ip = item.value
        case "port": if let s = item.value, let p = Int(s) { port = p }
        case "desc": if let s = item.value, !s.isEmpty { desc = s }
        default: break
        }
      }
      guard let address = ip, let p = port, p >= 1 && p <= 65535 else { return false }
      DOLConfigBridge.addDsuServer(desc, address: address, port: p)
      NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": "Added DSU server: \(address):\(p)"])
      // Open Settings and jump directly to Controllers page
      NotificationCenter.default.post(name: NSNotification.Name("DOLShowSettings"), object: nil)
      NotificationCenter.default.post(name: NSNotification.Name("DOLSettingsSelectControllers"), object: nil)
      return true
    }

    if url.scheme?.lowercased() == "dsu" {
      // Legacy: dsu://ip:port
      guard let host = url.host, !host.isEmpty else { return false }
      let p = url.port ?? 26760
      if p < 1 || p > 65535 { return false }
      DOLConfigBridge.addDsuServer("DSU", address: host, port: p)
      NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": "Added DSU server: \(host):\(p)"])
      NotificationCenter.default.post(name: NSNotification.Name("DOLShowSettings"), object: nil)
      NotificationCenter.default.post(name: NSNotification.Name("DOLSettingsSelectControllers"), object: nil)
      return true
    }

    return false
  }
}
