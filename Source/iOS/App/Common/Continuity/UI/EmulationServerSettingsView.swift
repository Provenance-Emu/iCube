// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

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
              Button(role: .destructive) { model.removeServer(server) } label: {
                Label(String(format: L("Remove %@"), server.name), systemImage: "minus.circle")
              }
            }
          }
        }
        Section {
          EmulationServerConnectionFields(model: model, onConnect: { dismiss() })
        } footer: {
          Text(L("Enter the Emulation Server address and an access token with library read permission."))
        }
        Section { Button(L("Done")) { dismiss() } }
      }
      .navigationTitle(L("Emulation Server"))
    }
  }
}

/// Same token flow for a saved address and for an address resolved over Bonjour.
struct EmulationServerConnectionFields: View {
  @ObservedObject var model: NearbyLibrariesModel
  var discoveredServer: EmulationServer?
  var initialFocus: FocusState<Bool>.Binding?
  var onConnect: () -> Void = {}
  @State private var address = ""
  @State private var token = ""
  @State private var errorMessage: String?
  @State private var connection: Task<Void, Never>?

  var body: some View {
    Group {
      if let discoveredServer {
        Text(discoveredServer.origin.absoluteString).foregroundStyle(.secondary)
      } else {
        TextField(L("Server Address"), text: $address)
          .textContentType(.URL)
          .autocorrectionDisabled()
          #if !os(tvOS)
          .keyboardType(.URL)
          .textInputAutocapitalization(.never)
          #endif
      }
      if let initialFocus {
        tokenField.focused(initialFocus)
      } else {
        tokenField
      }
      Button(L("Connect")) { connect() }
        .disabled((discoveredServer == nil && address.isEmpty) || token.isEmpty || connection != nil)
      if connection != nil { ProgressView() }
      if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
    }
  }

  private var tokenField: some View {
    SecureField(L("Access Token"), text: $token)
      .onDisappear { connection?.cancel() }
      .autocorrectionDisabled()
      #if !os(tvOS)
      .textInputAutocapitalization(.never)
      #endif
  }

  private func connect() {
    errorMessage = nil
    connection = Task {
      defer { connection = nil }
      do {
        let server = try discoveredServer ?? EmulationServer(address: address)
        let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty, credential.utf8.allSatisfy({ (33 ... 126).contains($0) }) else {
          throw EmulationServerLibrary.ServerError.accessDenied
        }
        try await EmulationServerLibrary(server: server, token: credential).checkAccess()
        try Task.checkCancellation()
        try model.addServer(server, token: credential)
        onConnect()
      } catch {
        if !Task.isCancelled { errorMessage = error.localizedDescription }
      }
    }
  }
}
