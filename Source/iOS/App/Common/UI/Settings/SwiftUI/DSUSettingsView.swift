// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The DSU motion source, pushed from the Controllers hub ("Motion Source (DSU)"). Moved out of
/// Settings → Controllers unchanged, except that Add Server is pushed instead of presented: the
/// hub is itself a sheet from the pause menu and the top bar.
struct DSUSettingsView: View {
  @State private var dsuEnabled = false
  @State private var dsuServers: [[String: Any]] = [] // keys: description, address, port
  @State private var showAddServer = false
  @StateObject private var dsuBrowser = DSUDiscoveryBrowser()
  @State private var recentlyAdded: Set<String> = [] // address:port keys
  @AppStorage(DSUSettings.Key.role) private var dsuRole: String = DSUSettings.Role.sender.rawValue
  @State private var pingingServerKey: String?

  /// Sender mode shares this device's input instead of receiving it, so the client toggle is locked
  /// while Sender is picked. iOS only: tvOS has no Role picker, so with "sender" registered as the
  /// default a tvOS lock could never be lifted.
  private var isClientLocked: Bool {
    #if os(iOS)
    return dsuRole == DSUSettings.Role.sender.rawValue
    #else
    return false
    #endif
  }

  var body: some View {
    List {
      Section(
        header: HStack {
          Text("DSU Client")
          if !dsuBrowser.servers.isEmpty {
            Text(String(format: L("%d found"), dsuBrowser.servers.count))
              .font(.caption)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.blue.opacity(0.15), in: Capsule())
          }
        }
      ) {
        #if !os(tvOS)
        settingsCaption(
          Picker(L("Role"), selection: $dsuRole) {
            Text(L("Receiver")).tag(DSUSettings.Role.receiver.rawValue)
            Text(L("Sender")).tag(DSUSettings.Role.sender.rawValue)
          }
          .onChange(of: dsuRole) { _, role in
            if role == DSUSettings.Role.sender.rawValue {
              dsuEnabled = false
              DOLConfigBridge.setDsuClientEnabled(false)
            }
          },
          L("Receiver pulls motion/input from a DSU server; Sender shares this device's input instead."))
        #endif
        settingsCaption(
          Toggle(L("Enable DSU Client"), isOn: $dsuEnabled)
            .onChange(of: dsuEnabled) { _, enabled in DOLConfigBridge.setDsuClientEnabled(enabled) }
            .disabled(isClientLocked),
          L("Receives input from a Cemuhook DSU server on your network (e.g. a phone's gyro). Add servers below as IP:Port."))
        Toggle(L("Show DSU Debug HUD"), isOn: Binding(get: {
#if DEBUG
          true
#else
          UserDefaults.standard.bool(forKey: "ui_show_dsu_debug_hud")
#endif
        }, set: { v in
#if !DEBUG
          UserDefaults.standard.set(v, forKey: "ui_show_dsu_debug_hud")
#endif
        }))
        Toggle(L("Map IR (Gyro) to DSU Touch"), isOn: Binding(get: {
          UserDefaults.standard.bool(forKey: "dsu_map_ir_to_touch")
        }, set: { v in
          UserDefaults.standard.set(v, forKey: "dsu_map_ir_to_touch")
          NotificationCenter.default.post(name: Notification.Name("DOLMotionSettingsChanged"), object: nil)
        }))
        Toggle(L("Send DSU Gyro/Accel"), isOn: Binding(get: {
          let has = UserDefaults.standard.object(forKey: "dsu_enable_gyro") != nil
          return has ? UserDefaults.standard.bool(forKey: "dsu_enable_gyro") : true
        }, set: { v in
          UserDefaults.standard.set(v, forKey: "dsu_enable_gyro")
        }))
        if dsuServers.isEmpty {
          HStack {
            Text(L("Servers"))
            Spacer()
            Text(L("None")).foregroundStyle(.secondary)
          }
        } else {
          ForEach(0 ..< dsuServers.count, id: \.self) { idx in
            serverRow(idx)
          }
        }
        Button {
          showAddServer = true
        } label: {
          Label(L("Add Server"), systemImage: "plus")
        }
      }

      if !dsuBrowser.servers.isEmpty {
        Section(header: Text(L("Discovered on Network"))) {
          ForEach(dsuBrowser.servers) { s in
            discoveredRow(s)
          }
        }
      }
    }
    .navigationTitle(L("Motion Source (DSU)"))
    // On the List, never on a row: see the plan's lockup note.
    .navigationDestination(isPresented: $showAddServer) {
      AddDSUServerView { name, address, port in
        DOLConfigBridge.addDsuServer(name, address: address, port: port)
        refreshServers()
      }
    }
    .onAppear {
      dsuEnabled = DOLConfigBridge.dsuClientEnabled()
      refreshServers()
      dsuBrowser.start()
    }
    .onDisappear { dsuBrowser.stop() }
  }

  @ViewBuilder
  private func serverRow(_ idx: Int) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(serverTitle(idx))
        Text(serverAddressPort(idx)).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      let addr = (dsuServers[idx]["address"] as? String) ?? ""
      let sanAddr: String = {
        let trimmed = addr.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = trimmed.firstIndex(of: "@") { return String(trimmed[..<at]) } else { return trimmed }
      }()
      let port = (dsuServers[idx]["port"] as? NSNumber)?.intValue ?? 26760
      let key = "\(sanAddr):\(port)"
      if pingingServerKey == key {
        ProgressView().padding(.vertical, 4)
      } else {
        Button {
          pingingServerKey = key
          NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Pinging %@…"), key)])
          DSUPingBridge.pingServerAddress(sanAddr, port: port, timeout: 1.0) { ok, info in
            pingingServerKey = nil
            let msg = ok ? String(format: L("Reachable: %@"), info ?? key) : L("No response")
            NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": msg])
          }
        } label: {
          Label(L("Test"), systemImage: "paperplane")
            .labelStyle(.titleAndIcon)
            .frame(minWidth: 72)
        }
        .buttonStyle(.bordered)
        #if !os(tvOS)
        .controlSize(.regular)
        #endif
        .padding(.vertical, 4)
      }
    }
    #if !os(tvOS)
    .swipeActions(edge: .trailing) {
      Button(role: .destructive) {
        DOLConfigBridge.removeDsuServer(at: idx)
        refreshServers()
      } label: { Label(L("Delete"), systemImage: "trash") }
    }
    #endif
  }

  @ViewBuilder
  private func discoveredRow(_ s: DSUDiscoveredServer) -> some View {
    let key = "\(s.address):\(s.port)"
    let isSaved = dsuServers.contains { server in
      ((server["address"] as? String) == s.address) && ((server["port"] as? NSNumber)?.intValue == s.port)
    }
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(s.name)
          if recentlyAdded.contains(key) {
            Text(L("New"))
              .font(.caption2)
              .padding(.horizontal, 6).padding(.vertical, 2)
              .background(Color.green.opacity(0.15), in: Capsule())
          }
        }
        Text(key).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if isSaved {
        Text(L("Saved"))
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8).padding(.vertical, 4)
          .background(Color.blue.opacity(0.1), in: Capsule())
      } else {
        Button(L("Add")) {
          let trimmed = s.address.trimmingCharacters(in: .whitespacesAndNewlines)
          let addr = (trimmed.firstIndex(of: "@").map { String(trimmed[..<$0]) }) ?? trimmed
          DOLConfigBridge.addDsuServer(s.name, address: addr, port: s.port)
          refreshServers()
          recentlyAdded.insert(key)
          NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Added DSU server: %@"), key)])
        }
        .buttonStyle(.bordered)
      }
    }
  }

  private func refreshServers() {
    dsuServers = DOLConfigBridge.dsuServersParsed()
  }

  private func serverTitle(_ idx: Int) -> String {
    if idx < 0 || idx >= dsuServers.count { return "Server \(idx + 1)" }
    let desc = (dsuServers[idx]["description"] as? String) ?? ""
    let addrPort = serverAddressPort(idx)
    if desc.isEmpty {
      return addrPort.isEmpty ? "Server \(idx + 1)" : addrPort
    }
    return addrPort.isEmpty ? desc : "\(desc) — \(addrPort)"
  }

  private func serverAddressPort(_ idx: Int) -> String {
    if idx < 0 || idx >= dsuServers.count { return "" }
    let addr = (dsuServers[idx]["address"] as? String) ?? ""
    let port = (dsuServers[idx]["port"] as? NSNumber)?.intValue ?? 0
    return port > 0 ? "\(addr):\(port)" : addr
  }
}

/// Add a DSU server by address. Pushed from `DSUSettingsView`; Back cancels.
private struct AddDSUServerView: View {
  let onAdd: (_ name: String, _ address: String, _ port: Int) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var serverName = "DS4"
  @State private var address = ""
  @State private var port = "26760"

  var body: some View {
    Form {
      Section(header: Text(L("Description"))) {
        TextField("DS4", text: $serverName)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled(true)
      }
      Section(header: Text(L("Server Address"))) {
        TextField("192.168.1.100", text: $address)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled(true)
          .keyboardType(.numbersAndPunctuation)
      }
      Section(header: Text(L("Port"))) {
        TextField("26760", text: $port)
          .keyboardType(.numberPad)
      }
    }
    .navigationTitle(L("Add DSU Server"))
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button(L("Add")) {
          onAdd(serverName, address, Int(port) ?? 26760)
          dismiss()
        }
        .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }
}
