// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

// MARK: - DSU Controller Session (iOS)

#if os(iOS)
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import SwiftUI

@available(iOS 17.0, *)
struct DSUSessionView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var ip: String = ""
  @State private var port: Int = 26760
  @State private var portText: String = "26760"
  @State private var running: Bool = false
  @State private var autoStart: Bool = true
  @State private var showDebug: Bool = false
  @State private var txCount: UInt = 0
  @State private var rxCount: UInt = 0
  @State private var tick: Int = 0
  @State private var showController: Bool = false
  @State private var hasClient: Bool = false
  @State private var clientAddr: String = ""
  @State private var clients: [String] = []
  @State private var approvalRequired: Bool = false
  @State private var pendingApprovalAddr: String? = nil
  @State private var showApprovalAlert: Bool = false

  var body: some View {
    NavigationStack {
      Form {
        Section(header: Text(L("Server"))) {
          HStack {
            Text(L("Address"))
            Spacer()
            Text("\(ip.isEmpty ? "-" : ip) : \(running ? port : (Int(portText) ?? 26760))")
              .foregroundStyle(.secondary)
          }
          .alert(isPresented: $showApprovalAlert) {
            Alert(
              title: Text(L("Receiver requests input")),
              message: Text(pendingApprovalAddr ?? ""),
              primaryButton: .default(Text(L("Allow"))) {
                if let addr = pendingApprovalAddr { DSUServerBridge.setClient(addr, allowed: true) }
                pendingApprovalAddr = nil
              },
              secondaryButton: .destructive(Text(L("Block"))) {
                if let addr = pendingApprovalAddr { DSUServerBridge.setClient(addr, allowed: false) }
                pendingApprovalAddr = nil
              }
            )
          }
          HStack {
            Text(L("Client"))
            Spacer()
            if hasClient {
              Circle().fill(Color.green).frame(width: 10, height: 10)
              Text(clientAddr.isEmpty ? L("Connected") : clientAddr)
                .foregroundStyle(.secondary)
            } else {
              Circle().fill(Color.red).frame(width: 10, height: 10)
              Text(L("Waiting for client…")).foregroundStyle(.secondary)
            }
          }
          HStack {
            Text(L("Port"))
            Spacer()
            TextField("26760", text: $portText)
              .multilineTextAlignment(.trailing)
              .keyboardType(.numberPad)
              .frame(maxWidth: 120)
              .disabled(running)
          }
          Toggle(L("Start Server"), isOn: $running)
            .onChange(of: running) { v in
              if v {
                let p = validatedPort()
                let ok = DSUServerBridge.start(onPort: NSNumber(value: p).intValue)
                if ok {
                  ip = DSUServerBridge.ipAddress()
                  port = p
                  UserDefaults.standard.set(p, forKey: "dsu_server_port")
                } else {
                  let err = DSUServerBridge.lastError()
                  NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": err.isEmpty ? L("Failed to start DSU server") : err])
                  running = false
                }
              } else {
                DSUServerBridge.stop()
                ip = ""
              }
            }
          Toggle(L("Auto‑start when opening"), isOn: $autoStart)
            .onChange(of: autoStart) { UserDefaults.standard.set($0, forKey: "dsu_server_autostart") }
        }

        Section(header: Text(L("Quick Links"))) {
          NavigationLink(destination: ControllersRootView()) {
            Label(L("Controller Settings"), systemImage: "gamecontroller")
          }
          Toggle(L("Show DSU Debug"), isOn: $showDebug)
        }

        if running && !ip.isEmpty {
          Section(header: Text(L("Share"))) {
            HStack {
              Text(L("Copy Link"))
              Spacer()
              Button(action: {
                let p = running ? port : (Int(portText) ?? 26760)
                let link = "dolphinios://dsu/add?ip=\(ip)&port=\(p)"
                UIPasteboard.general.string = link
                NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Copied")])
              }) {
                Label(L("Copy Link"), systemImage: "doc.on.doc")
              }
              .buttonStyle(.bordered)
            }
            VStack(alignment: .center) {
              let p = running ? port : (Int(portText) ?? 26760)
              let payload = "dolphinios://dsu/add?ip=\(ip)&port=\(p)"
              HStack { Spacer()
                QRCodeView(text: payload).frame(width: 160, height: 160)
                Spacer()
              }
              Text(payload).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
          }
        }

        if showDebug {
          Section(header: Text(L("DSU Debug"))) {
            HStack { Text("TX")
              Spacer()
              Text("\(txCount)").foregroundStyle(.secondary)
            }
            HStack { Text("RX")
              Spacer()
              Text("\(rxCount)").foregroundStyle(.secondary)
            }
          }
        }

        Section(header: Text(L("Connected Receivers")), footer: Text(L("When approval is required, only allowed receivers will receive input. Version pings are still answered so clients can detect this server."))) {
          Toggle(L("Approval Required"), isOn: $approvalRequired)
            .onChange(of: approvalRequired) { DSUServerBridge.setApprovalRequired($0) }
          if clients.isEmpty {
            Text(L("No receivers seen yet")).foregroundStyle(.secondary)
          } else {
            ForEach(clients, id: \.self) { addr in
              HStack {
                Text(addr)
                Spacer()
                let allowed = DSUServerBridge.isClientAllowed(addr)
                Toggle(L("Allow"), isOn: Binding(get: { allowed }, set: { v in DSUServerBridge.setClient(addr, allowed: v) }))
                  .labelsHidden()
              }
            }
            HStack {
              Button(L("Allow All")) {
                for a in clients { DSUServerBridge.setClient(a, allowed: true) }
              }
              .buttonStyle(.bordered)
              Button(L("Block All")) {
                for a in clients { DSUServerBridge.setClient(a, allowed: false) }
              }
              .buttonStyle(.bordered)
            }
          }
        }

        Section {
          Button {
            showController = true
          } label: {
            Label(L("Open On‑Screen Controller"), systemImage: "rectangle.and.hand.point.up.left.filled")
          }
          .disabled(!running)
        }
      }
      .navigationTitle(L("DSU Controller"))
      .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L("Done")) { dismiss() } } }
      .onAppear {
        running = DSUServerBridge.isRunning()
        // Load persisted defaults
        let savedPort = UserDefaults.standard.integer(forKey: "dsu_server_port")
        if savedPort > 0 { portText = String(savedPort) }
        if UserDefaults.standard.object(forKey: "dsu_server_autostart") != nil {
          autoStart = UserDefaults.standard.bool(forKey: "dsu_server_autostart")
        }
        approvalRequired = DSUServerBridge.approvalRequired()
        if running {
          ip = DSUServerBridge.ipAddress()
          let cur = DSUServerBridge.port()
          port = Int(cur)
          portText = String(cur)
        } else if autoStart {
          let p = validatedPort()
          if DSUServerBridge.start(onPort: NSNumber(value: p).intValue) {
            running = true
            ip = DSUServerBridge.ipAddress()
            port = p
            UserDefaults.standard.set(p, forKey: "dsu_server_port")
          } else {
            let err = DSUServerBridge.lastError()
            NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": err.isEmpty ? L("Failed to start DSU server") : err])
          }
        }
        // Approval prompt observer
        NotificationCenter.default.addObserver(forName: NSNotification.Name("DSUNewClientApproval"), object: nil, queue: .main) { note in
          if let addr = note.userInfo?["address"] as? String {
            pendingApprovalAddr = addr
            showApprovalAlert = true
          }
        }
      }
      .onDisappear { if running { DSUServerBridge.stop() } }
      .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
        if showDebug {
          txCount = UInt(DSUServerBridge.txCount())
          rxCount = UInt(DSUServerBridge.rxCount())
        }
        let prev = hasClient
        hasClient = DSUServerBridge.hasClient()
        clientAddr = DSUServerBridge.lastClientAddress()
        clients = DSUServerBridge.clients()
        if !prev && hasClient {
          NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Receiver connected")])
        }
      }
      .onChange(of: autoStart) { UserDefaults.standard.set($0, forKey: "dsu_server_autostart") }
      .onChange(of: portText) { if let p = Int($0), p >= 1 && p <= 65535 { UserDefaults.standard.set(p, forKey: "dsu_server_port") } }
      .fullScreenCover(isPresented: $showController) { DSUControllerView(onClose: { showController = false }) }
    }
  }
}

@available(iOS 17.0, *)
extension DSUSessionView {
  private func validatedPort() -> Int {
    if let p = Int(portText), p >= 1 && p <= 65535 { return p }
    portText = "26760"
    return 26760
  }
}
#endif
