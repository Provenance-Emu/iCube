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

#if USE_RETRO_ACHIEVEMENTS
struct ConfigAchievementsView: View {
  @State private var enabled: Bool = false
  @State private var username: String = ""
  @State private var hasToken: Bool = false
  @State private var password: String = ""
  @State private var hardcore: Bool = false
  @State private var unofficial: Bool = false
  @State private var encore: Bool = false
  @State private var spectator: Bool = false
  @State private var discordPresence: Bool = false
  @State private var progress: Bool = true
  @State private var hostURL: String = ""

  var body: some View {
    List {
      Section(header: Text(L("RetroAchievements"))) {
        settingsCaption(
          HStack {
            Label(L("Enable Integration"), systemImage: "trophy.fill")
            Spacer()
            Toggle("", isOn: $enabled).onChange(of: enabled) { DOLConfigBridge.setRaEnabled($0) }
          },
          L("Connects to RetroAchievements.org to unlock achievements and track progress across supported games."))

        HStack {
          Label(L("Username"), systemImage: "person.fill")
          Spacer()
          TextField(L("Username"), text: $username)
            .multilineTextAlignment(.trailing)
            .disabled(hasToken || !enabled)
            .onChange(of: username) { DOLConfigBridge.setRaUsername($0) }
        }
        .disabled(!enabled)

        HStack {
          Label(L("Password"), systemImage: "key.fill")
          Spacer()
          SecureField(L("Password"), text: $password)
            .multilineTextAlignment(.trailing)
            .disabled(hasToken || !enabled)
        }
        .disabled(!enabled)

        Button(action: {
          if hasToken {
            DOLConfigBridge.raLogout()
          } else {
            DOLConfigBridge.raInit()
            DOLConfigBridge.raLogin(password)
          }
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { sync() }
        }) {
          Label(hasToken ? L("Log Out") : L("Log In"), systemImage: hasToken ? "person.badge.minus" : "person.badge.plus")
        }
        .disabled(!enabled)
      }

      Section(header: Text(L("Game Mode Options"))) {
        settingsCaption(
          HStack {
            Label(L("Hardcore Mode"), systemImage: "flame.fill")
              .foregroundColor(.orange)
            Spacer()
            Toggle("", isOn: $hardcore).onChange(of: hardcore) { DOLConfigBridge.setRaHardcoreEnabled($0) }
          },
          L("Disables save states, cheats, and speed changes for authentic difficulty and full achievement credit."))
        settingsCaption(
          HStack {
            Label(L("Enable Unofficial"), systemImage: "person.3.sequence.fill")
              .foregroundColor(.purple)
            Spacer()
            Toggle("", isOn: $unofficial).onChange(of: unofficial) { DOLConfigBridge.setRaUnofficialEnabled($0) }
          },
          L("Includes community achievements that haven't been officially promoted yet."))
        settingsCaption(
          HStack {
            Label(L("Encore Mode"), systemImage: "arrow.clockwise.circle.fill")
              .foregroundColor(.green)
            Spacer()
            Toggle("", isOn: $encore).onChange(of: encore) { DOLConfigBridge.setRaEncoreEnabled($0) }
          },
          L("Re-enables achievements you've already earned so you can unlock them again."))
        settingsCaption(
          HStack {
            Label(L("Spectator Mode"), systemImage: "eye.fill")
              .foregroundColor(.blue)
            Spacer()
            Toggle("", isOn: $spectator).onChange(of: spectator) { DOLConfigBridge.setRaSpectatorEnabled($0) }
          },
          L("Tracks achievements without earning them — view progress without affecting your record."))
      }

      Section(header: Text(L("Interface & Sharing"))) {
        settingsCaption(
          HStack {
            Label(L("Discord Presence"), systemImage: "bubble.left.and.bubble.right.fill")
              .foregroundColor(.indigo)
            Spacer()
            Toggle("", isOn: $discordPresence).onChange(of: discordPresence) { DOLConfigBridge.setRaDiscordPresenceEnabled($0) }
          },
          L("Shows your current game and achievements in your Discord status."))
        settingsCaption(
          HStack {
            Label(L("Show Progress Popups"), systemImage: "bell.badge.fill")
              .foregroundColor(.orange)
            Spacer()
            Toggle("", isOn: $progress).onChange(of: progress) { DOLConfigBridge.setRaProgressEnabled($0) }
          },
          L("Displays achievement-progress notifications during gameplay."))
      }

      Section(header: Text(L("Advanced"))) {
        settingsCaption(
          HStack {
            Label(L("Server URL"), systemImage: "server.rack")
            Spacer()
            TextField("https://retroachievements.org", text: $hostURL)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled(true)
              .keyboardType(.URL)
              .multilineTextAlignment(.trailing)
              .onChange(of: hostURL) { DOLConfigBridge.setRaHostURL($0) }
          },
          L("Custom RetroAchievements API server. Only change this for a custom/self-hosted server."))
      }
    }
    .navigationTitle(L("Achievements"))
    .configSynced { sync() }
  }

  private func sync() {
    enabled = DOLConfigBridge.raEnabled()
    username = DOLConfigBridge.raUsername()
    hasToken = DOLConfigBridge.raHasAPIToken()
    hardcore = DOLConfigBridge.raHardcoreEnabled()
    unofficial = DOLConfigBridge.raUnofficialEnabled()
    encore = DOLConfigBridge.raEncoreEnabled()
    spectator = DOLConfigBridge.raSpectatorEnabled()
    discordPresence = DOLConfigBridge.raDiscordPresenceEnabled()
    progress = DOLConfigBridge.raProgressEnabled()
    hostURL = DOLConfigBridge.raHostURL()
  }
}
#endif
