// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

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
              Button(role: .destructive) { model.removeServer(server) } label: {
                Label(String(format: L("Remove %@"), server.name), systemImage: "minus.circle")
              }
            }
          }
        }
        Section {
          EmulationServerConnectionFields(model: model, onConnect: { dismiss() })
        } footer: {
          Text(L("Enter the server address. An access token is needed only if the server requires sign-in."))
        }
        Section { Button(L("Done")) { dismiss() } }
      }
      .navigationTitle(L("Emulation Server"))
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
  #if os(tvOS)
  @State private var pairing: PairingDisplay?

  private struct PairingDisplay {
    let pin: String
    let link: URL
  }
  #endif

  var body: some View {
    Group {
      addressField
        .onDisappear { connection?.cancel() }
        .task {
          guard discoveredServer != nil, !triedLocalAccess else { return }
          triedLocalAccess = true
          connect()
        }
      #if os(tvOS)
      if let pairing {
        QRCodeImage(string: pairing.link.absoluteString)
          .frame(width: 240, height: 240)
          .padding(16)
          .background(.white)
          .accessibilityHidden(true)
        Text(L("Scan with your phone to approve this Apple TV."))
        Text(L("Or open the server’s Settings → Devices and enter this PIN:"))
        Text(pairing.pin).font(icube.font(.title).monospacedDigit())
        Button(L("Cancel"), role: .cancel) { connection?.cancel() }
      } else {
        connectionControls
      }
      #else
      connectionControls
      #endif
      if connection != nil { ProgressView() }
      if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
    }
  }

  @ViewBuilder
  private var addressField: some View {
    if let discoveredServer {
      Text(discoveredServer.origin.absoluteString).foregroundStyle(.secondary)
    } else {
      TextField(L("Server Address"), text: $address)
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
    #if os(tvOS)
    if requiresCredential {
      Button(L("Pair Apple TV")) { pair() }
        .disabled(connection != nil)
    }
    #endif
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
        let credential = entered.isEmpty ? nil : entered
        if let credential, !EmulationServerLibrary.isValidToken(credential) {
          throw EmulationServerLibrary.ServerError.accessDenied
        }
        try await finish(server, token: credential)
      } catch EmulationServerLibrary.ServerError.accessDenied {
        guard !Task.isCancelled else { return }
        requiresCredential = true
        errorMessage = L("This server requires sign-in.")
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

  #if os(tvOS)
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
        let challenge = try await library.startPairing()
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
  #endif
}
