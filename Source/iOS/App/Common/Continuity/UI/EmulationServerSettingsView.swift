// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import EmulatorContentClient
import PVContinuity
import SwiftUI

struct EmulationServerSettingsView: View {
  @ObservedObject var model: NearbyLibrariesModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        if !model.servers.isEmpty {
          Section(L("Connected Servers")) {
            ForEach(model.servers) { server in
              NavigationLink(server.name) {
                EmulationServerBackupSettingsView(server: server, model: model)
              }
            }
          }
        }
        Section {
          EmulationServerConnectionFields(model: model, onConnect: { dismiss() })
        } footer: {
          Text(L("Enter a hostname such as studio.local. Local HTTP uses port 8473 unless you enter a different port."))
        }
        Section { Button(L("Done")) { dismiss() } }
      }
      .navigationTitle(L("Emulation Server"))
    }
  }
}

private struct EmulationServerBackupSettingsView: View {
  let server: EmulationServer
  @ObservedObject var model: NearbyLibrariesModel
  @ObservedObject private var backups = EmulationServerBackups.shared
  @Environment(\.dismiss) private var dismiss
  @State private var itemID = ""
  @State private var token = ""
  @State private var allowsHTTP = false
  @State private var errorMessage: String?
  @State private var libraries: [Library] = []
  @State private var libraryID = ""
  @State private var items: [Item] = []
  @State private var cursor: String?
  @State private var busy = false
  @State private var createKey = UUID().uuidString

  private var enabled: Bool { backups.targets[server.id] != nil }
  private var conflicts: [EmulationServerSaveSyncWorker.Conflict] { backups.conflicts[server.id] ?? [] }
  private var credential: String {
    let entered = token.trimmingCharacters(in: .whitespacesAndNewlines)
    return entered.isEmpty ? KeychainService.getPassword(for: server.id + "/backup") ?? "" : entered
  }

  private var transportAllowed: Bool { server.origin.scheme == "https" || allowsHTTP }

  var body: some View {
    Form {
      Section {
        if let status = backups.status[server.id] { Text(status) }
        SecureField(L("Write access token"), text: $token)
          .autocorrectionDisabled()
          .disabled(busy)
          #if !os(tvOS)
          .textInputAutocapitalization(.never)
          #endif
        if server.origin.scheme == "http" {
          Toggle(L("Allow backups over local HTTP"), isOn: $allowsHTTP)
            .disabled(busy)
          Text(L("HTTP sends your token and saves without encryption. Enable it only on a trusted network."))
            .foregroundStyle(.secondary)
        }
        Button(L("Choose Backup Library")) {
          perform {
            libraries = try await EmulationServerBackupSetup.libraries(server: server, token: credential).items
            items = []
            cursor = nil
            libraryID = ""
          }
        }
        .disabled(busy || credential.isEmpty || !transportAllowed)
        if !libraries.isEmpty {
          Picker(L("Library"), selection: $libraryID) {
            Text(L("Choose a library")).tag("")
            ForEach(libraries, id: \.id) { library in Text(library.name).tag(library.id) }
          }
          .disabled(busy)
          .onChange(of: libraryID) { _, value in
            guard !value.isEmpty else { return }
            itemID = ""
            items = []
            cursor = nil
            loadItems()
          }
        }
        if !items.isEmpty {
          Picker(L("Backup Destination"), selection: $itemID) {
            Text(L("Choose a destination")).tag("")
            ForEach(items, id: \.id) { item in Text(item.title).tag(item.id) }
          }
          .disabled(busy)
        }
        if cursor != nil { Button(L("Load More")) { loadItems() }.disabled(busy) }
        if libraries.first(where: { $0.id == libraryID })?.canCreateItems == true {
          Button(L("Create iCube Backups Destination")) {
            perform {
              let item = try await EmulationServerBackupSetup.createItem(server: server, token: credential,
                                                                         libraryID: libraryID, key: createKey)
              items.removeAll { $0.id == item.id }
              items.append(item)
              itemID = item.id
              createKey = UUID().uuidString
            }
          }
          .disabled(busy || !transportAllowed)
        }
        Button(enabled ? L("Update backup destination") : L("Enable automatic backups")) {
          do {
            try backups.save(.init(server: server, itemID: itemID, allowsHTTP: allowsHTTP), token: credential)
            token = ""
            errorMessage = nil
          } catch {
            errorMessage = error.localizedDescription
          }
        }
        .disabled(busy || !EmulationServerBackupTarget.isValidItemID(itemID) || credential.isEmpty || !transportAllowed)
        if enabled {
          Button(L("Back Up All Servers Now")) { backups.requestBackup() }
          Button(L("Disable Backups"), role: .destructive) { backups.remove(server) }
        }
        if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
      } header: {
        Text(L("Automatic Save Backups"))
      } footer: {
        Text(L("Choose a private library on this server. iCube uploads save files and states when the app becomes active or emulation stops."))
      }
      if enabled {
        Section {
          Toggle(L("Sync Saves Across Devices"), isOn: Binding(
            get: { backups.targets[server.id]?.syncsSaves ?? false },
            set: { backups.setSyncsSaves($0, for: server) }
          ))
        } footer: {
          Text(L("Saves and save states changed on another device that uses this destination are copied here, and yours are sent to it. A save replaced here stays in Recently Deleted for 30 days. A save that changed on both is never replaced without asking, and nothing is deleted. Wii saves are backed up but not synced yet."))
        }
        if !conflicts.isEmpty {
          // One control per row: a row holding two buttons is a single focus target on Apple TV.
          Section {
            ForEach(conflicts, id: \.self) { conflict in
              Text(conflict.path).foregroundStyle(.secondary)
              Button(L("Keep This Device’s")) { backups.resolve([conflict], on: server, .keepLocal) }
              Button(L("Use the Server’s")) { backups.resolve([conflict], on: server, .useServer) }
            }
            if conflicts.count > 1 {
              Button(L("Keep All From This Device")) { backups.resolve(conflicts, on: server, .keepLocal) }
              Button(L("Use All From the Server")) { backups.resolve(conflicts, on: server, .useServer) }
            }
          } header: {
            Text(L("Saves That Differ"))
          } footer: {
            Text(L("These changed on this device and on the server. The one you do not keep is not lost: the server keeps its copy, and this device’s goes to Recently Deleted."))
          }
        }
      }
      Section {
        Button(L("Remove Server"), role: .destructive) {
          model.removeServer(server)
          dismiss()
        }
      }
    }
    .navigationTitle(server.name)
    .onAppear {
      itemID = backups.targets[server.id]?.itemID ?? ""
      allowsHTTP = backups.targets[server.id]?.allowsHTTP ?? false
    }
  }

  private func loadItems() {
    perform {
      let page = try await EmulationServerBackupSetup.items(server: server, token: credential,
                                                            libraryID: libraryID, cursor: cursor)
      let known = Set(items.map(\.id))
      items.append(contentsOf: page.items.filter { !known.contains($0.id) })
      cursor = page.nextCursor
    }
  }

  private func perform(_ work: @escaping @MainActor () async throws -> Void) {
    guard !busy, transportAllowed else { return }
    busy = true
    errorMessage = nil
    Task {
      defer { busy = false }
      do { try await work() }
      catch { errorMessage = L("Could not load the backup destination. Check the token and server connection.") }
    }
  }
}

/// Same token flow for a saved address and for an address resolved over Bonjour.
struct EmulationServerConnectionFields: View {
  @Environment(\.icube) private var icube
  @ObservedObject var model: NearbyLibrariesModel
  var discoveredServer: EmulationServer?
  var initialFocus: FocusState<Bool>.Binding?
  var onConnect: () -> Void = {}
  @State private var address = ""
  @State private var token = ""
  @State private var errorMessage: String?
  @State private var connection: Task<Void, Never>?
  @State private var requiresCredential = false
  @State private var triedLocalAccess = false
  @State private var pairing: PairingDisplay?

  private struct PairingDisplay {
    let pin: String
    let link: URL
  }

  /// The longest device name sent with a pairing request.
  private static let deviceNameLimit = 60

  var body: some View {
    Group {
      addressField
        .onDisappear { connection?.cancel() }
        .task {
          guard discoveredServer != nil, !triedLocalAccess else { return }
          triedLocalAccess = true
          connect()
        }
      if let pairing {
        #if os(tvOS)
        QRCodeImage(string: pairing.link.absoluteString)
          .frame(width: 240, height: 240)
          .padding(16)
          .background(.white)
          .accessibilityHidden(true)
        Text(L("Scan with your phone to approve this Apple TV."))
        Text(L("Or open the server’s Settings → Devices and enter this PIN:"))
        #else
        Text(L("On the server, open Settings → Devices and enter this PIN:"))
        #endif
        Text(pairing.pin).font(icube.font(.title).monospacedDigit())
        #if !os(tvOS)
        Link(L("Approve on the Server"), destination: pairing.link)
        #endif
        Button(L("Cancel"), role: .cancel) { connection?.cancel() }
      } else {
        connectionControls
      }
      if connection != nil { ProgressView() }
      if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
    }
  }

  @ViewBuilder
  private var addressField: some View {
    if let discoveredServer {
      Text(discoveredServer.origin.absoluteString).foregroundStyle(.secondary)
    } else {
      TextField(L("Server Address"), text: $address, prompt: Text("studio.local"))
        .textContentType(.URL)
        .autocorrectionDisabled()
        .disabled(connection != nil)
        #if !os(tvOS)
        .keyboardType(.URL)
        .textInputAutocapitalization(.never)
        #endif
    }
  }

  @ViewBuilder
  private var connectionControls: some View {
    if requiresCredential {
      #if os(tvOS)
      Button(L("Pair Apple TV")) { pair() }
        .disabled(connection != nil)
      #else
      Button(L("Pair This Device")) { pair() }
        .disabled(connection != nil)
      #endif
    }
    if discoveredServer == nil || requiresCredential {
      if let initialFocus {
        tokenField.focused(initialFocus)
      } else {
        tokenField
      }
    }
    Button(L("Connect")) { connect() }
      .disabled((discoveredServer == nil && address.isEmpty) || connection != nil ||
        (requiresCredential && token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
  }

  private var tokenField: some View {
    SecureField(L("Access Token"), text: $token)
      .autocorrectionDisabled()
      .disabled(connection != nil)
      #if !os(tvOS)
      .textInputAutocapitalization(.never)
      #endif
  }

  private func connect() {
    guard connection == nil else { return }
    errorMessage = nil
    connection = Task {
      defer { connection = nil }
      do {
        let server = try discoveredServer ?? EmulationServer(address: address)
        let entered = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = entered.isEmpty ? KeychainService.getPassword(for: server.id) : entered
        if let credential, !EmulationServerLibrary.isValidToken(credential) {
          throw EmulationServerLibrary.ServerError.accessDenied
        }
        try await finish(server, token: credential)
      } catch EmulationServerLibrary.ServerError.accessDenied {
        guard !Task.isCancelled else { return }
        requiresCredential = true
        errorMessage = L("This server requires sign-in.")
      } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
        if !Task.isCancelled {
          errorMessage = L("Use HTTPS, a local IP address, or a .local hostname for this server.")
        }
      } catch {
        if !Task.isCancelled { errorMessage = error.localizedDescription }
      }
    }
  }

  private func finish(_ server: EmulationServer, token: String?) async throws {
    try await EmulationServerLibrary(server: server, token: token).checkAccess()
    try Task.checkCancellation()
    try model.addServer(server, token: token)
    onConnect()
  }

  private func pair() {
    guard connection == nil else { return }
    errorMessage = nil
    connection = Task {
      defer {
        pairing = nil
        connection = nil
      }
      do {
        let server = try discoveredServer ?? EmulationServer(address: address)
        let library = EmulationServerLibrary(server: server, token: nil)
        let name = String(format: L("iCube on %@"), ICubeDeviceName.current())
        let challenge = try await library.startPairing(deviceName: String(name.prefix(Self.deviceNameLimit)))
        guard let link = challenge.verificationURL(on: server) else { throw URLError(.badURL) }
        pairing = .init(pin: challenge.pin, link: link)
        let clock = ContinuousClock()
        let expires = clock.now.advanced(by: .seconds(challenge.expiresInSeconds))
        while clock.now < expires {
          try await Task.sleep(for: .seconds(3))
          if let issuedToken = try await library.redeemPairing(challenge) {
            try await finish(server, token: issuedToken)
            return
          }
        }
        throw EmulationServerLibrary.ServerError.pairingExpired
      } catch ContinuityError.invalidResponse(let status) where status == 404 {
        if !Task.isCancelled { errorMessage = L("Pairing is unavailable. Use a read access token to connect.") }
      } catch {
        if !Task.isCancelled { errorMessage = error.localizedDescription }
      }
    }
  }
}
