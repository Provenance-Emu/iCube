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


/// Root Settings page implemented in SwiftUI for iOS/tvOS
struct SettingsRootView<Background: View>: View {
  @Environment(\.openURL) private var openURL
  @Environment(\.dismiss) private var dismiss
  private let backgroundView: Background?
  private let isPauseMenuStyle: Bool
  private let game: TVGameItem?

  init(backgroundView: Background? = nil, isPauseMenuStyle: Bool = false, game: TVGameItem? = nil) {
    self.backgroundView = backgroundView
    self.isPauseMenuStyle = isPauseMenuStyle
    self.game = game
  }

  private var appVersion: String {
    VersionManager.shared().appVersion.userFacing
  }

  private var coreVersion: String {
    VersionManager.shared().coreVersion
  }

  /// Web UI URL string from PVWebServer; empty if not running
  private var webURLString: String {
    PVWebServer.shared.urlString ?? ""
  }

  /// WebDAV URL string from PVWebServer; empty if not running
  private var webDavURLString: String {
    PVWebServer.shared.webDavURLString ?? ""
  }

  @State private var appVersionLabel: String = ""
  @State private var coreVersionLabel: String = ""
  @State private var webURLDisplay: String = ""
  @State private var webDavDisplay: String = ""

  /// Footer under the Network section: explains web importing and links to the help page. On iOS the
  /// "Learn more" is a tappable link; on tvOS (no browser / no openURL) it's plain text so the row
  /// stays focus-clean and the build doesn't reference an unavailable API.
  @ViewBuilder
  private var webImportFooter: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(L("Drop GameCube and Wii files onto iCube from a computer or phone on the same Wi-Fi. Open the address in a browser, or in Finder choose Go › Connect to Server and enter the same address as Guest."))
#if os(iOS)
      Button(L("Learn more")) {
        if let url = URL(string: "https://icube-emu.com/help/web-import") { openURL(url) }
      }
      .font(.footnote)
#else
      Text(verbatim: "https://icube-emu.com/help/web-import")
        .font(.footnote)
        .foregroundStyle(.secondary)
#endif
    }
  }

  var body: some View {
    ZStack {
      // Optional background
      if let background = backgroundView {
        background
          .ignoresSafeArea()
      }

      if isPauseMenuStyle {
        pauseMenuStyleContent
      } else {
        NavigationStack {
          settingsContent
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DOLSettingsSelectControllers"))) { _ in
      currentSettingsPage = .controllers
    }
    .task {
      await refreshLightweightInfo()
    }
  }

  @State private var currentSettingsPage: SettingsPage? = nil
  @State private var showGlobalResetAlert: Bool = false
#if os(iOS)
  @State private var showSafari: Bool = false
  @State private var safariURL: URL? = nil
#endif

  private func refreshLightweightInfo() async {
    await MainActor.run {
      // Set placeholders immediately to avoid blocking UI
      if appVersionLabel.isEmpty { appVersionLabel = appVersion }
      if coreVersionLabel.isEmpty { coreVersionLabel = coreVersion }
      if webURLDisplay.isEmpty { webURLDisplay = PVWebServer.shared.urlString ?? "" }
      if webDavDisplay.isEmpty { webDavDisplay = PVWebServer.shared.webDavURLString ?? "" }
    }
#if os(iOS)
    // WS-3: WebServerLifecycleService now owns starting the server (at scene
    // become-active, i.e. app launch), so this view no longer starts it itself.
    // startServers() binds asynchronously (NWListener in a Task), so the URL can
    // still be nil the moment Settings appears; poll briefly and refresh once it resolves.
    for _ in 0..<20 {  // up to ~2s for the listener to come up
      if let u = PVWebServer.shared.urlString, !u.isEmpty {
        await MainActor.run {
          webURLDisplay = u
          webDavDisplay = PVWebServer.shared.webDavURLString ?? ""
        }
        break
      }
      try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1s
    }
#endif
  }

  @ViewBuilder
  private var pauseMenuStyleContent: some View {
    if let page = currentSettingsPage {
      // Show submenu directly (no sheet needed)
      SettingsSubMenuView(
        page: page,
        game: game,
        onBack: { currentSettingsPage = nil }
      )
    } else {
      // Main settings menu
      HStack(spacing: 80) {
        // Left side - Game cover (smaller)
        VStack(alignment: .leading, spacing: 16) {
          if let gameItem = game {
            Image(uiImage: gameItem.coverImage)
              .resizable()
              .aspectRatio(2.0/3.0, contentMode: .fit)
              .frame(width: 180, height: 270)
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
              .shadow(color: .black.opacity(0.6), radius: 20, x: 0, y: 10)
          }

          VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
              .font(.system(size: 24, weight: .bold))
              .foregroundColor(.white)

            Text("Game & system options")
              .font(.system(size: 14, weight: .medium))
              .foregroundColor(.white.opacity(0.7))
          }
        }
        .frame(width: 180)

        // Right side - Settings menu
        VStack(alignment: .leading, spacing: 32) {
          // Back button
          Button(action: { dismiss() }) {
            HStack(spacing: 12) {
              Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .semibold))
              Text("Back to Menu")
                .font(.system(size: 18, weight: .semibold))
            }
            .foregroundColor(.white.opacity(0.8))
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          }
          .buttonStyle(.plain)

          // Settings sections
          VStack(spacing: 16) {
            SettingsMenuRow(icon: "gearshape", title: "Config", subtitle: "General configuration") {
              currentSettingsPage = .config
            }

            SettingsMenuRow(icon: "gauge.with.dots.needle.67percent", title: "Performance Tuning", subtitle: "CPU & interpreter speed") {
              currentSettingsPage = .performance
            }

            SettingsMenuRow(icon: "display", title: "Graphics", subtitle: "Video & rendering settings") {
              currentSettingsPage = .graphics
            }

            SettingsMenuRow(icon: "gamecontroller", title: "Controllers", subtitle: "Input & controller setup") {
              currentSettingsPage = .controllers
            }

            SettingsMenuRow(icon: "ladybug", title: "Debug", subtitle: "Developer options") {
              currentSettingsPage = .debug
            }

            Divider()
              .background(.white.opacity(0.3))
              .padding(.vertical, 8)

            // Version info
            VStack(spacing: 12) {
              HStack {
                Text("Version")
                  .font(.system(size: 16, weight: .medium))
                  .foregroundColor(.white.opacity(0.8))
                Spacer()
                Text(appVersionLabel.isEmpty ? appVersion : appVersionLabel)
                  .font(.system(size: 16, weight: .medium))
                  .foregroundColor(.white.opacity(0.6))
              }

              HStack {
                Text("Dolphin Core")
                  .font(.system(size: 16, weight: .medium))
                  .foregroundColor(.white.opacity(0.8))
                Spacer()
                Text(coreVersionLabel.isEmpty ? coreVersion : coreVersionLabel)
                  .font(.system(size: 16, weight: .medium))
                  .foregroundColor(.white.opacity(0.6))
              }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            // Network info
            VStack(spacing: 12) {
              HStack {
                Text("Web UI")
                  .font(.system(size: 16, weight: .medium))
                  .foregroundColor(.white.opacity(0.8))
                Spacer()
#if os(iOS)
                if !(webURLDisplay.isEmpty) {
                  Button(action: {
                    if let u = URL(string: webURLDisplay) {
                      safariURL = u
                      showSafari = true
                    }
                  }) {
                    Text(webURLDisplay)
                      .font(.system(size: 16, weight: .medium))
                      .foregroundColor(.blue)
                      .lineLimit(1)
                      .truncationMode(.middle)
                  }
                  .buttonStyle(.plain)
                  .networkURLContextMenu(webURLDisplay, openURL: openURL)
                } else {
                  Text(L("Not Running"))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                }
#else
                Text(webURLDisplay.isEmpty ? L("Not Running") : webURLDisplay)
                  .font(.system(size: 16, weight: .medium))
                  .foregroundColor(.white.opacity(0.6))
                  .lineLimit(1)
                  .truncationMode(.middle)
#endif
              }
              HStack {
                Text(L("Finder / WebDAV"))
                  .font(.system(size: 16, weight: .medium))
                  .foregroundColor(.white.opacity(0.8))
                Spacer()
#if os(iOS)
                if !webDavDisplay.isEmpty {
                  Text(webDavDisplay)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .networkURLContextMenu(webDavDisplay, openURL: openURL)
                } else {
                  Text(L("Not Running"))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                }
#else
                Text(webDavDisplay.isEmpty ? L("Not Running") : webDavDisplay)
                  .font(.system(size: 16, weight: .medium))
                  .foregroundColor(.white.opacity(0.6))
                  .lineLimit(1)
                  .truncationMode(.middle)
#endif
              }
              // Web-import help: short description + link (plain text on tvOS — no browser).
              VStack(alignment: .leading, spacing: 4) {
                Text(L("Drop GameCube and Wii files onto iCube from a computer or phone on the same Wi-Fi. Open the address in a browser, or in Finder choose Go › Connect to Server and enter the same address as Guest."))
                  .font(.system(size: 12))
                  .foregroundColor(.white.opacity(0.5))
#if os(iOS)
                Button(L("Learn more")) {
                  if let url = URL(string: "https://icube-emu.com/help/web-import") { openURL(url) }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.blue)
#else
                Text(verbatim: "https://icube-emu.com/help/web-import")
                  .font(.system(size: 12))
                  .foregroundColor(.white.opacity(0.5))
#endif
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            SettingsMenuRow(icon: "info.circle", title: "About", subtitle: "App information") {
              currentSettingsPage = .about
            }
          }
        }
        .frame(width: 480)
      }
      .padding(.horizontal, 60)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func titleForPage(_ page: SettingsPage) -> String {
    switch page {
    case .config: return "Config"
    case .performance: return L("Performance Tuning")
    case .graphics: return "Graphics"
    case .controllers: return "Controllers"
    case .debug: return "Debug"
    case .about: return "About"
    }
  }

  @ViewBuilder
  private func contentForPage(_ page: SettingsPage) -> some View {
    switch page {
    case .config:
      ConfigRootView()
    case .performance:
      PerformanceTuningView()
    case .graphics:
      GraphicsRootView()
    case .controllers:
      ControllersRootView()
    case .debug:
      DebugRootView()
    case .about:
      AboutView()
    }
  }

  @ViewBuilder
  private var settingsContent: some View {
    NavigationStack {
      List {
        Section {
          NavigationLink(destination: ConfigRootView()) {
            Label(L("Config"), systemImage: "gear")
              .accessibilityLabel(L("Config Settings"))
          }
          NavigationLink(destination: PerformanceTuningView()) {
            Label(L("Performance Tuning"), systemImage: "gauge.with.dots.needle.67percent")
          }
          NavigationLink(destination: GraphicsRootView()) {
            Label(L("Graphics"), systemImage: "display")
              .accessibilityLabel(L("Graphics Settings"))
          }
          NavigationLink(destination: ControllersRootView()) {
            Label(L("Controllers"), systemImage: "gamecontroller")
          }
          NavigationLink {
            DebugRootView()
          } label: {
            Label(L("Debug"), systemImage: "ladybug")
          }
        }

        Section(footer: EmptyView()) {
          HStack {
            Text(L("Version"))
            Spacer()
            if #available(iOS 17.0, *) {
              Text(appVersionLabel.isEmpty ? appVersion : appVersionLabel).foregroundStyle(.secondary)
            }
          }
          HStack {
            Image("DolphinLogo")
              .resizable()
              .scaledToFit()
              .frame(height: 24)
            Text(L("Core"))
            Spacer()
            Text(coreVersionLabel.isEmpty ? coreVersion : coreVersionLabel).foregroundStyle(.secondary)
          }
          NavigationLink(destination: AboutView()) {
            Label(L("About"), systemImage: "info.circle")
          }
          NavigationLink(destination: DolphinBlogView()) {
            Label(L("Dolphin Blog"), systemImage: "newspaper")
          }
          // In-app documentation browser (bundled + cached, works offline and on tvOS — see
          // WikiHelpView). Was previously a tvOS-only "TODO" stub plus an iOS-only external
          // link to icube-emu.com/support; both platforms now share the same real content.
          NavigationLink(destination: WikiHelpView()) {
            Label(L("Help"), systemImage: "questionmark.circle")
              .accessibilityLabel(L("Help"))
          }
        }

        // Network
        Section(header: Text(L("Network")), footer: webImportFooter) {
          HStack {
            Text(L("Web UI"))
            Spacer()
            let s = webURLDisplay
#if os(iOS)
            if !s.isEmpty {
              Button(action: {
                if let u = URL(string: s) {
                  safariURL = u
                  showSafari = true
                }
              }) {
                Text(s)
                  .foregroundStyle(.blue)
                  .lineLimit(1)
                  .truncationMode(.middle)
              }
              .buttonStyle(.plain)
              .networkURLContextMenu(s, openURL: openURL)
            } else {
              Text(L("Not Running"))
                .foregroundStyle(.secondary)
            }
#else
            Text(s.isEmpty ? L("Not Running") : s)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
#endif
          }
          HStack {
            Text(L("Finder / WebDAV"))
            Spacer()
            let s = webDavDisplay
#if os(iOS)
            if !s.isEmpty {
              Text(s)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .networkURLContextMenu(s, openURL: openURL)
            } else {
              Text(L("Not Running"))
                .foregroundStyle(.secondary)
            }
#else
            Text(s.isEmpty ? L("Not Running") : s)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
#endif
          }
          // WS-5: iCloud sync of everything except ROMs. Everything about it
          // lives in CloudSyncSettingsView; this is only the way in.
          NavigationLink(destination: CloudSyncSettingsView()) {
            HStack {
              Label(L("iCloud Sync"), systemImage: "icloud")
              Spacer()
              SyncStatusIndicator()
            }
          }
        }
      }
      .navigationTitle(L("Settings"))
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button(L("Reset All")) { showGlobalResetAlert = true }
        }
      }
    }
    .alert(L("Reset All Settings"), isPresented: $showGlobalResetAlert) {
      Button(L("Cancel"), role: .cancel) {}
      Button(L("Reset"), role: .destructive) { DOLConfigBridge.resetAllToDefaults() }
    } message: {
      Text(L("This will reset all settings to factory defaults. This may require restarting emulation."))
    }
#if os(iOS)
    .sheet(isPresented: $showSafari) {
      if let u = safariURL { SafariView(url: u) }
    }
#endif
  }
}

extension SettingsRootView where Background == EmptyView {
  init() {
    self.backgroundView = nil
    self.isPauseMenuStyle = false
    self.game = nil
  }
}

/// Settings page types
internal enum SettingsPage {
  case config, performance, graphics, controllers, debug, about
}

// Settings submenu view for pause menu style
private struct SettingsSubMenuView: View {
  let page: SettingsPage
  let game: TVGameItem?
  let onBack: () -> Void
  @State private var showResetAll = false
  @State private var showResetPage = false

  var body: some View {
    HStack(spacing: 80) {
      // Left side - Game cover (smaller)
      VStack(alignment: .leading, spacing: 16) {
        if let gameItem = game {
          Image(uiImage: gameItem.coverImage)
            .resizable()
            .aspectRatio(2.0/3.0, contentMode: .fit)
            .frame(width: 180, height: 270)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.6), radius: 20, x: 0, y: 10)
        }

        VStack(alignment: .leading, spacing: 6) {
          Text(titleForPage(page))
            .font(.system(size: 24, weight: .bold))
            .foregroundColor(.white)

          Text(subtitleForPage(page))
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white.opacity(0.7))
        }
      }
      .frame(width: 180)

      // Right side - Settings content
      VStack(alignment: .leading, spacing: 32) {
        // Back + Reset actions
        HStack(spacing: 12) {
          Button(action: onBack) {
            HStack(spacing: 12) {
              Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .semibold))
              Text("Back to Settings")
                .font(.system(size: 18, weight: .semibold))
            }
            .foregroundColor(.white.opacity(0.8))
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          }
          .buttonStyle(.plain)

          Spacer()

          Button(action: { showResetPage = true }) {
            Text(L("Reset Page"))
              .font(.system(size: 16, weight: .semibold))
              .foregroundColor(.white)
              .padding(.horizontal, 16)
              .padding(.vertical, 10)
              .background(.orange.opacity(0.3))
              .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          }
          .buttonStyle(.plain)

          Button(action: { showResetAll = true }) {
            Text(L("Reset All"))
              .font(.system(size: 16, weight: .semibold))
              .foregroundColor(.white)
              .padding(.horizontal, 16)
              .padding(.vertical, 10)
              .background(.red.opacity(0.3))
              .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          }
          .buttonStyle(.plain)
        }

        // Settings content - ensure NavigationStack for NavigationLink to work, and focus enabled
        NavigationStack { contentForPage(page) }
          .environment(\.colorScheme, .dark)
          .foregroundStyle(.white)
#if !os(tvOS)
          .modifier(HideListBackgroundIfAvailable())
#endif
          .background(Color.clear)
          .frame(maxWidth: 820, maxHeight: 520)
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      }
      .frame(width: 480)
      .frame(maxHeight: .infinity)
    }
    .padding(.horizontal, 60)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
#if os(tvOS)
    .onExitCommand { onBack() }
#endif
    .alert(L("Reset All Settings"), isPresented: $showResetAll) {
      Button(L("Cancel"), role: .cancel) {}
      Button(L("Reset"), role: .destructive) {
        DOLConfigBridge.resetAllToDefaults()
      }
    } message: {
      Text(L("This will reset all settings to factory defaults. This may require restarting emulation."))
    }
    .alert(L("Reset Page"), isPresented: $showResetPage) {
      Button(L("Cancel"), role: .cancel) {}
      Button(L("Reset"), role: .destructive) {
        let index: Int
        switch page {
        case .config: index = 0
        case .performance: index = 0
        case .graphics: index = 1
        case .controllers: index = 2
        case .debug: index = 3
        case .about: index = 4
        }
        DOLConfigBridge.resetPage(toDefaults: index)
      }
    } message: {
      Text(L("This resets only the settings on this page to defaults."))
    }
  }

  private func titleForPage(_ page: SettingsPage) -> String {
    switch page {
    case .config: return "Config"
    case .performance: return L("Performance Tuning")
    case .graphics: return "Graphics"
    case .controllers: return "Controllers"
    case .debug: return "Debug"
    case .about: return "About"
    }
  }

  private func subtitleForPage(_ page: SettingsPage) -> String {
    switch page {
    case .config: return "General configuration"
    case .performance: return "CPU & interpreter speed"
    case .graphics: return "Video & rendering settings"
    case .controllers: return "Input & controller setup"
    case .debug: return "Developer options"
    case .about: return "App information"
    }
  }

  @ViewBuilder
  private func contentForPage(_ page: SettingsPage) -> some View {
    switch page {
    case .config:
      ConfigRootView()
    case .performance:
      PerformanceTuningView()
    case .graphics:
      GraphicsRootView()
    case .controllers:
      ControllersRootView()
    case .debug:
      DebugRootView()
    case .about:
      AboutView()
    }
  }
}

// Settings menu row component for pause menu style
private struct SettingsMenuRow: View {
  let icon: String
  let title: String
  let subtitle: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 20) {
        // Icon with background
        ZStack {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.white.opacity(0.1))
            .frame(width: 48, height: 48)

          Image(systemName: icon)
            .font(.system(size: 20, weight: .medium))
            .foregroundColor(.white)
        }

        // Text content
        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(.white)

          Text(subtitle)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white.opacity(0.7))
        }

        Spacer()

        // Chevron
        Image(systemName: "chevron.right")
          .font(.system(size: 14, weight: .medium))
          .foregroundColor(.white.opacity(0.5))
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 16)
      .background(.white.opacity(0.05))
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    .buttonStyle(.plain)
  }
}



/// Config top-level menu with easily re-orderable items
#if os(iOS)
private struct HideListBackgroundIfAvailable: ViewModifier {
  func body(content: Content) -> some View {
    content.scrollContentBackground(.hidden)
  }
}
#endif

