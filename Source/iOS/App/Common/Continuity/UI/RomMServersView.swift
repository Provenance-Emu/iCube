// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import RomMClient
import SwiftUI

/// Saved RomM servers and the form that adds one. A saved server shows in the library's source list, where
/// its games are browsed; RomM does not announce itself on the network, so this is the only way in.
struct RomMServersView: View {
  @ObservedObject var model: NearbyLibrariesModel
  /// The server that was just connected, so the library can open it.
  var onConnect: (RomMServer) -> Void = { _ in }

  var body: some View {
    List {
      if !model.rommServers.isEmpty {
        Section(L("Connected Servers")) {
          ForEach(model.rommServers) { server in
            HStack {
              Label(server.name, systemImage: NearbyLibrariesModel.glyph(for: "romm"))
              Spacer()
              Button(L("Remove"), role: .destructive) { model.removeRomMServer(server) }
                .buttonStyle(.borderless)
            }
          }
        }
      }
      Section {
        RomMConnectionFields(model: model, onConnect: onConnect)
      } header: {
        Text(L("Add a RomM Server"))
      } footer: {
        Text(L("Enter the address you open RomM at. GameCube and Wii games from it appear in your library's sources."))
      }
    }
    .navigationTitle("RomM")
  }
}

/// Address and login for a RomM server: a new one, or a saved one whose login stopped working.
struct RomMConnectionFields: View {
  @ObservedObject var model: NearbyLibrariesModel
  /// A saved server to sign in to again; nil asks for the address.
  var server: RomMServer?
  var initialFocus: FocusState<Bool>.Binding?
  var onConnect: (RomMServer) -> Void = { _ in }

  @State private var address = ""
  @State private var token = ""
  @State private var username = ""
  @State private var password = ""
  @State private var usePassword = false
  @State private var allowHTTP = false
  @State private var errorMessage: String?
  @State private var connection: Task<Void, Never>?

  private var target: RomMAddress? {
    if let server { return try? server.address() }
    return try? RomMAddress(address)
  }

  private var busy: Bool { connection != nil }

  var body: some View {
    Group {
      if let server {
        Text(server.baseURL.absoluteString).foregroundStyle(.secondary)
      } else {
        TextField(L("Server Address"), text: $address, prompt: Text("romm.local"))
          .textContentType(.URL)
          .autocorrectionDisabled()
          #if !os(tvOS)
          .keyboardType(.URL)
          .textInputAutocapitalization(.never)
          #endif
          .onChange(of: address) { _, _ in allowHTTP = false }
      }
      Toggle(L("Use username and password"), isOn: $usePassword)
      if usePassword {
        TextField(L("Username"), text: $username)
          .autocorrectionDisabled()
          #if !os(tvOS)
          .textInputAutocapitalization(.never)
          #endif
        SecureField(L("Password"), text: $password)
      } else if let initialFocus {
        tokenField.focused(initialFocus)
      } else {
        tokenField
      }
      if target?.isHTTPS == false {
        Toggle(L("Allow credentials over HTTP"), isOn: $allowHTTP)
      }
      Button(L("Connect")) { connect() }
        .disabled(target == nil || (usePassword && (username.isEmpty || password.isEmpty)))
      if busy { ProgressView() }
      if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
    }
    .disabled(busy)
    .onDisappear { connection?.cancel() }
  }

  private var tokenField: some View {
    SecureField(L("Client API token (optional)"), text: $token)
      .autocorrectionDisabled()
      #if !os(tvOS)
      .textInputAutocapitalization(.never)
      #endif
  }

  private func connect() {
    guard connection == nil, let target else { return }
    errorMessage = nil
    connection = Task {
      defer { connection = nil }
      do {
        let entered = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential: RomMCredential
        if usePassword {
          credential = .basic(username: username, password: password)
        } else if !entered.isEmpty {
          credential = .token(entered)
        } else {
          credential = .none
        }
        let login = RomMSavedLogin(credential: credential, allowHTTP: allowHTTP)
        // Reading the platforms proves the address is a RomM server and the login works.
        _ = try await RomMClient(address: target, credential: credential, allowHTTP: allowHTTP).platforms()
        try Task.checkCancellation()
        let connected = RomMServer(address: target)
        try model.addRomMServer(connected, login: login)
        token = ""
        password = ""
        onConnect(connected)
      } catch {
        if !Task.isCancelled { errorMessage = error.localizedDescription }
      }
    }
  }
}
