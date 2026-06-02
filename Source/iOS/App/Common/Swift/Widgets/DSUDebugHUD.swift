// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// DSU HUD with RX blink indicator (always compiled; visibility controlled by setting)
struct DSUDebugHUD: View {
  @State private var rx: UInt = 0
  @State private var blink: Bool = false
  var body: some View {
    VStack {
      HStack(spacing: 8) {
        let enabled = DOLConfigBridge.dsuClientEnabled()
        Circle().fill(enabled ? Color.green : Color.red).frame(width: 8, height: 8)
        Text("DSU: \(enabled ? "On" : "Off")")
          .font(.caption2).foregroundColor(.white)
          .lineLimit(1)
        let list = (DOLConfigBridge.dsuServersParsed() as? [[String: Any]]) ?? []
        Text("Srv=\(list.count)")
          .font(.caption2).foregroundColor(.white.opacity(0.9))
        // RX indicator + count
        Circle().fill(Color.green.opacity(blink ? 1.0 : 0.25)).frame(width: 8, height: 8)
        Text("RX=\(rx)").font(.caption2).foregroundColor(.white)
        if let first = list.first,
           let addr = first["address"] as? String,
           let port = (first["port"] as? NSNumber)?.intValue {
          Button("Ping") {
            DSUPingBridge.pingServerAddress(addr, port: port, timeout: 1.0) { ok, info in
              let msg = ok ?
              "[DSU] Ping OK: \(info ?? "" )" :
              "[DSU] Ping Timeout"
              NSLog("%@", msg)
              NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": msg])
            }
          }
          .buttonStyle(.bordered)
          #if !os(tvOS)
          .controlSize(.mini)
          #endif
        }
      }
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(Color.black.opacity(0.5))
      .clipShape(Capsule())
      .padding(.top, 8)
      .padding(.leading, 12)
      Spacer()
    }
    .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
      let newRx = UInt(DOLConfigBridge.dsuClientRxCount())
      if newRx != rx {
        rx = newRx
        blink = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { blink = false }
      }
    }
  }
}
