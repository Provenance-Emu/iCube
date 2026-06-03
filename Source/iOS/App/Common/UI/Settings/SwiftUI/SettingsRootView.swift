// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit
import CoreHaptics
import QuartzCore
import PVWebServer
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
    // iOS has no app-root start site (tvOS starts the server at TVRootView). Start the
    // upload/WebDAV server when Settings — which displays the URL the user uploads to —
    // appears. startServers() binds asynchronously (NWListener in a Task), so the URL is
    // nil until it's .ready; poll briefly and refresh the displayed URL once it resolves.
    if !PVWebServer.shared.isWWWUploadServerRunning {
      PVWebServer.shared.startServers()
    }
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
                Text("WebDAV")
                  .font(.system(size: 16, weight: .medium))
                  .foregroundColor(.white.opacity(0.8))
                Spacer()
                Text(webDavDisplay.isEmpty ? L("Not Running") : webDavDisplay)
                  .font(.system(size: 16, weight: .medium))
                  .foregroundColor(.white.opacity(0.6))
                  .lineLimit(1)
                  .truncationMode(.middle)
              }
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
#if os(tvOS)
          NavigationLink(destination: HelpPlaceholderView()) {
            Label(L("Help"), systemImage: "questionmark.circle")
          }
#else
          Button(L("Help")) {
            if let url = URL(string: "https://icube-emu.com/support") {
              openURL(url)
            }
          }
#endif
        }

        // Network
        Section(header: Text(L("Network"))) {
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
            Text(L("WebDAV"))
            Spacer()
            let s = webDavDisplay
            Text(s.isEmpty ? L("Not Running") : s)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
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

// MARK: - Motion Settings (DSU)

private struct MotionSettingsView: View {
  @State private var gain: Double = UserDefaults.standard.object(forKey: "dsu_gyro_gain") as? Double ?? 1.0
  @State private var deadzone: Double = UserDefaults.standard.object(forKey: "dsu_deadzone") as? Double ?? 0.05
  @State private var smoothing: Double = UserDefaults.standard.object(forKey: "dsu_smoothing") as? Double ?? 0.0
  var body: some View {
    Form {
      Section(header: Text(L("Gyro Gain"))) {
        settingsCaption(
          Group {
#if os(tvOS)
            TVFloatStepper(
              value: Binding(
                get: { CGFloat(gain) },
                set: { gain = Double($0) }
              ),
              range: 0.1...3.0,
              step: 0.05
            )
#else
            HStack {
              Slider(value: $gain, in: 0.1...3.0, step: 0.05)
              Text(String(format: "%.2f", gain)).frame(width: 50).monospacedDigit()
            }
#endif
          },
          L("Scales motion intensity. Higher values increase sensitivity."))
      }
      Section(header: Text(L("Deadzone"))) {
        settingsCaption(
          Group {
#if os(tvOS)
            TVFloatStepper(
              value: Binding(
                get: { CGFloat(deadzone) },
                set: { deadzone = Double($0) }
              ),
              range: 0.0...0.49,
              step: 0.01
            )
#else
            HStack {
              Slider(value: $deadzone, in: 0.0...0.49, step: 0.01)
              Text(String(format: "%.2f", deadzone)).frame(width: 50).monospacedDigit()
            }
#endif
          },
          L("Ignores small movements to reduce jitter."))
      }
      Section(header: Text(L("Smoothing"))) {
        settingsCaption(
          Group {
#if os(tvOS)
            TVFloatStepper(
              value: Binding(
                get: { CGFloat(smoothing) },
                set: { smoothing = Double($0) }
              ),
              range: 0.0...0.9,
              step: 0.05
            )
#else
            HStack {
              Slider(value: $smoothing, in: 0.0...0.9, step: 0.05)
              Text(String(format: "%.2f", smoothing)).frame(width: 50).monospacedDigit()
            }
#endif
          },
          L("Applies exponential smoothing. 0 disables smoothing."))
      }
    }
    .navigationTitle(L("Advanced Motion Settings"))
    .onChange(of: gain) { UserDefaults.standard.set($0, forKey: "dsu_gyro_gain") }
    .onChange(of: deadzone) { UserDefaults.standard.set($0, forKey: "dsu_deadzone") }
    .onChange(of: smoothing) { UserDefaults.standard.set($0, forKey: "dsu_smoothing") }
  }
}

// Convenience initializer for no background
extension SettingsRootView where Background == EmptyView {
  init() {
    self.backgroundView = nil
    self.isPauseMenuStyle = false
    self.game = nil
  }
}

/// Settings page types
internal enum SettingsPage {
  case config, graphics, controllers, debug, about
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
    case .graphics: return "Graphics"
    case .controllers: return "Controllers"
    case .debug: return "Debug"
    case .about: return "About"
    }
  }

  private func subtitleForPage(_ page: SettingsPage) -> String {
    switch page {
    case .config: return "General configuration"
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
struct ConfigRootView: View {
  var body: some View {
    List {
      NavigationLink(destination: ConfigGeneralView()) {
        Label(L("General"), systemImage: "gear")
      }
      NavigationLink(destination: ConfigInterfaceView()) {
        Label(L("Interface"), systemImage: "menubar.rectangle")
      }
      NavigationLink(destination: ConfigAudioView()) {
        Label(L("Audio"), systemImage: "speaker.wave.3")
      }
      NavigationLink(destination: ConfigGameCubeView()) {
        Label(L("GameCube"), systemImage: "cube")
      }
      NavigationLink(destination: ConfigWiiView()) {
        Label(L("Wii"), systemImage: "tv.and.hifispeaker.fill")
      }
      NavigationLink(destination: ConfigAdvancedView()) {
        Label(L("Advanced"), systemImage: "cpu")
      }
      #if USE_RETRO_ACHIEVEMENTS
      NavigationLink(destination: ConfigAchievementsView()) {
        Label(L("Achievements"), systemImage: "trophy")
      }
      #endif
    }
    .navigationTitle(L("Config"))
  }
}

/// Graphics top-level menu with easily re-orderable items
struct GraphicsRootView: View {
  var body: some View {
    List {
      NavigationLink(destination: GraphicsGeneralView()) {
        Label(L("General"), systemImage: "display")
      }
      NavigationLink(destination: GraphicsEnhancementsView()) {
        Label(L("Enhancements"), systemImage: "sparkles")
      }
      NavigationLink(destination: GraphicsHacksView()) {
        Label(L("Hacks"), systemImage: "wrench.and.screwdriver")
      }
      NavigationLink(destination: GraphicsAdvancedView()) {
        Label(L("Advanced"), systemImage: "slider.horizontal.3")
      }
      NavigationLink(destination: ShaderSettingsView()) {
        Label(L("Shaders"), systemImage: "paintbrush")
      }
    }
    .navigationTitle(L("Graphics"))
  }
}

// MARK: - Controllers (single page)

struct ControllersRootView: View {
  @State private var backgroundInput: Bool = false
  @State private var wiimoteScan: Bool = false
  @State private var wiimoteSpeaker: Bool = false
  @State private var connectWiimotes: Bool = false
  @State private var autoSelectOnScreenBySystem: Bool = true
  // DSU client
  @State private var dsuEnabled: Bool = false
  @State private var dsuServers: [[String: Any]] = [] // keys: description, address, port
  @State private var showAddDsuServer: Bool = false
  @State private var newDsuDesc: String = "DS4"
  @State private var newDsuAddr: String = ""
  @State private var newDsuPort: String = "26760"
  @StateObject private var dsuBrowser = DSUDiscoveryBrowser()
  @State private var recentlyAdded: Set<String> = [] // address:port keys
  @AppStorage("dsu_role") private var dsuRole: String = "receiver" // "receiver" or "sender"
  @State private var pingingServerKey: String? = nil

  // Touchscreen
#if os(iOS)
  @State private var touchOpacity: Float = 0.5
#endif
  @State private var touchIRMode: TouchIRMode = .drag
  @State private var gcPortDevices: [Int] = [0, 0, 0, 0]   // 0 None, 1 Standard Controller, etc.
  @State private var wiiSources: [Int] = [0, 0, 0, 0]      // 0 None, 1 Emulated, 2 Real

  var body: some View {
    List {
      Section(header: Text(L("GameCube Controllers"))) {
        ForEach(1...4, id: \.self) { port in
          NavigationLink {
            ControllersPortView(isGC: true, portOneBased: port)
          } label: {
            HStack {
              Text("\(L("Port")) \(port)")
              Spacer()
              Text(localizedSIDevice(gcPortDevices[port - 1]))
                .foregroundStyle(.secondary)
            }
          }
        }
      }

      Section(header: Text(L("Wii Remotes"))) {
        ForEach(1...4, id: \.self) { port in
          NavigationLink {
            ControllersPortView(isGC: false, portOneBased: port)
          } label: {
            HStack {
              Text("\(L("Wii Remote")) \(port)")
              Spacer()
              Text(localizedWiimoteSource(wiiSources[port - 1]))
                .foregroundStyle(.secondary)
            }
          }
        }
      }

      // DSU Client
      Section(
        header: HStack {
          Text("DSU Client")
          if !dsuBrowser.servers.isEmpty {
            Text("\(dsuBrowser.servers.count) \(dsuBrowser.servers.count == 1 ? L("found") : L("found"))")
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
            Text(L("Receiver")).tag("receiver")
            Text(L("Sender")).tag("sender")
          }
          .onChange(of: dsuRole) { role in
            if role == "sender" {
              dsuEnabled = false
              DOLConfigBridge.setDsuClientEnabled(false)
            }
          },
          L("Receiver pulls motion/input from a DSU server; Sender shares this device's input instead."))
        #endif
        settingsCaption(
          Toggle(L("Enable DSU Client"), isOn: $dsuEnabled)
            .onChange(of: dsuEnabled) { DOLConfigBridge.setDsuClientEnabled($0) }
            .disabled(dsuRole == "sender"),
          L("Receives input from a Cemuhook DSU server on your network (e.g. a phone's gyro). Add servers below as IP:Port."))
        Toggle(L("Show DSU Debug HUD"), isOn: Binding(get: {
#if DEBUG
          true
#else
          UserDefaults.standard.bool(forKey: "ui_show_dsu_debug_hud")
#endif
        }, set: { v in
#if DEBUG
          // Always on in DEBUG; ignore writes
#else
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
          ForEach(0..<dsuServers.count, id: \.self) { idx in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(dsuServerTitle(idx))
                Text(dsuServerAddressPort(idx)).font(.caption).foregroundStyle(.secondary)
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
                  // Enlarge hit target and give quick feedback
                  pingingServerKey = key
                  NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Pinging %@…"), key)])
                  #if DEBUG
                  print("[DSU-PING] tapping Test for \(key)")
                  #endif
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
                refreshDsuServers()
              } label: { Label(L("Delete"), systemImage: "trash") }
            }
            #else
            // TODO: TVOS Deletion @JoeMatt
            #endif // !os(tvOS)
          }
        }
        Button(action: { newDsuDesc = "DS4"; newDsuAddr = ""; newDsuPort = "26760"; showAddDsuServer = true }) {
          Label(L("Add Server"), systemImage: "plus")
        }

        NavigationLink(destination: MotionSettingsView()) {
          Label(L("Advanced Motion Settings"), systemImage: "gyroscope")
        }
      }

      if !dsuBrowser.servers.isEmpty {
        Section(header: Text(L("Discovered on Network"))) {
          ForEach(dsuBrowser.servers) { s in
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
                  let addr = (trimmed.firstIndex(of: "@").map { String(trimmed[..<$0]) } ) ?? trimmed
                  DOLConfigBridge.addDsuServer(s.name, address: addr, port: s.port)
                  refreshDsuServers()
                  recentlyAdded.insert(key)
                  NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Added DSU server: %@"), key)])
                }
                .buttonStyle(.bordered)
              }
            }
          }
        }
      }

      Section(header: Text(L("General"))) {
        settingsCaption(
          Toggle(L("Background Input"), isOn: $backgroundInput)
            .onChange(of: backgroundInput) { newValue in DOLConfigBridge.setMainBackgroundInput(newValue) },
          L("Keeps accepting controller input while iCube is in the background."))
        settingsCaption(
          Toggle(L("Auto‑select On‑Screen Controller by System"), isOn: $autoSelectOnScreenBySystem)
            .onChange(of: autoSelectOnScreenBySystem) { newValue in UserDefaults.standard.set(newValue, forKey: "auto_touchpad_by_system") },
          L("Automatically shows the GameCube or Wii on-screen layout based on the game being played."))

#if os(iOS)
        Button(action: { testRumble() }) {
          Label(L("Test Rumble"), systemImage: "waveform")
        }
#endif
      }

      Section(header: Text(L("Wii Remotes"))) {
        settingsCaption(
          Toggle(L("Continuous Scanning"), isOn: $wiimoteScan)
            .onChange(of: wiimoteScan) { newValue in DOLConfigBridge.setWiimoteContinuousScanning(newValue) },
          L("Keeps looking for new Wii Remotes to connect."))
        settingsCaption(
          Toggle(L("Enable Speaker"), isOn: $wiimoteSpeaker)
            .onChange(of: wiimoteSpeaker) { newValue in DOLConfigBridge.setWiimoteEnableSpeaker(newValue) },
          L("Plays audio through a real Wii Remote's speaker."))
        settingsCaption(
          Toggle(L("Connect Wiimotes for Controller Interface"), isOn: $connectWiimotes)
            .onChange(of: connectWiimotes) { newValue in DOLConfigBridge.setConnectWiimotesForControllerInterface(newValue) },
          L("Automatically pairs Wii Remotes when the controller interface is in use."))
      }

      Section(header: Text(L("Alternate Input Sources"))) {
#if os(iOS)
        settingsCaption(
          HStack {
            Text(L("Opacity"))
            Spacer()
            Slider(value: Binding(get: { Double(touchOpacity) }, set: { touchOpacity = Float($0) }), in: 0...1)
              .frame(width: 220)
              .onChange(of: touchOpacity) { DOLConfigBridge.setMainTouchPadOpacity($0) }
          },
          L("Transparency of the on-screen touch controls."))
#endif
        settingsNavCaption(
          destination: TouchIRModePicker(selected: $touchIRMode),
          L("How the Wii Remote pointer is driven. Gyro uses device motion; Follow/Drag use touch gestures.")
        ) {
          Text("\(L("Touch IR Pointer")): \(touchIRMode.label)")
        }
        .onChange(of: touchIRMode) { DOLConfigBridge.setMainTouchPadIRMode($0.rawValue) }

        NavigationLink(destination: EnhancedMotionControlsView()) {
          Label(L("Advanced Motion Settings"), systemImage: "gyroscope")
        }
      }
    }
    .navigationTitle(L("Controllers"))
    .onAppear {
      syncFromConfig()
      syncPortTypes()
      ensureDefaultGCPlayer1()
      if UserDefaults.standard.object(forKey: "auto_touchpad_by_system") == nil {
        UserDefaults.standard.set(true, forKey: "auto_touchpad_by_system")
      }
      autoSelectOnScreenBySystem = UserDefaults.standard.bool(forKey: "auto_touchpad_by_system")
      dsuBrowser.start()
    }
    .onDisappear { dsuBrowser.stop() }
    .sheet(isPresented: $showAddDsuServer) {
      NavigationStack {
        Form {
          Section(header: Text(L("Description"))) {
            TextField("DS4", text: $newDsuDesc)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled(true)
          }
          Section(header: Text(L("Server Address"))) {
            TextField("192.168.1.100", text: $newDsuAddr)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled(true)
              .keyboardType(.numbersAndPunctuation)
          }
          Section(header: Text(L("Port"))) {
            TextField("26760", text: $newDsuPort)
              .keyboardType(.numberPad)
          }
        }
        .navigationTitle("Add DSU Server")
        .toolbar {
          ToolbarItem(placement: .topBarLeading) { Button(L("Cancel")) { showAddDsuServer = false } }
          ToolbarItem(placement: .topBarTrailing) {
            Button(L("Add")) {
              let port = Int(newDsuPort) ?? 26760
              DOLConfigBridge.addDsuServer(newDsuDesc, address: newDsuAddr, port: port)
              refreshDsuServers()
              showAddDsuServer = false
            }.disabled(newDsuAddr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
      }
    }
  }

  private func syncFromConfig() {
    backgroundInput = DOLConfigBridge.mainBackgroundInput()
    wiimoteScan = DOLConfigBridge.wiimoteContinuousScanning()
    wiimoteSpeaker = DOLConfigBridge.wiimoteEnableSpeaker()
    connectWiimotes = DOLConfigBridge.connectWiimotesForControllerInterface()
#if os(iOS)
    touchOpacity = DOLConfigBridge.mainTouchPadOpacity()
#endif
    touchIRMode = TouchIRMode.from(raw: DOLConfigBridge.mainTouchPadIRMode())
    // DSU
    dsuEnabled = DOLConfigBridge.dsuClientEnabled()
    refreshDsuServers()
  }

  private func refreshDsuServers() {
    let arr = DOLConfigBridge.dsuServersParsed() as? [[String: Any]] ?? []
    dsuServers = arr
  }

  private func dsuServerTitle(_ idx: Int) -> String {
    if idx < 0 || idx >= dsuServers.count { return "Server \(idx+1)" }
    let desc = (dsuServers[idx]["description"] as? String) ?? ""
    let addrPort = dsuServerAddressPort(idx)
    if desc.isEmpty {
      return addrPort.isEmpty ? "Server \(idx+1)" : addrPort
    } else {
      return addrPort.isEmpty ? desc : "\(desc) — \(addrPort)"
    }
  }

  private func dsuServerAddressPort(_ idx: Int) -> String {
    if idx < 0 || idx >= dsuServers.count { return "" }
    let addr = (dsuServers[idx]["address"] as? String) ?? ""
    let port = (dsuServers[idx]["port"] as? NSNumber)?.intValue ?? 0
    return port > 0 ? "\(addr):\(port)" : addr
  }

  private func syncPortTypes() {
    for i in 0..<4 {
      gcPortDevices[i] = DOLConfigBridge.gcPortDevice(forPort: i + 1)
      wiiSources[i] = DOLConfigBridge.wiimoteSource(for: i + 1)
    }
  }

  // If all GC ports are None, default Player 1 to Standard Controller
  private func ensureDefaultGCPlayer1() {
    if gcPortDevices.allSatisfy({ $0 == 0 }) {
      DOLConfigBridge.setGCPortDeviceForPort(1, device: 1)
      gcPortDevices[0] = 1
    }
  }

  private func localizedSIDevice(_ device: Int) -> String {
    switch device {
    case 0: return L("<Nothing>")
    case 1: return L("GameCube Controller")
    default: return L("Unknown")
    }
  }

  private func localizedWiimoteSource(_ source: Int) -> String {
    switch source {
    case 0: return L("<Nothing>")
    case 1: return L("Emulated Wii Remote")
    default: return L("Unknown")
    }
  }

#if os(iOS)
  /// Test rumble/haptic feedback on device and connected controllers
  func testRumble() {
    var controllersTestedCount = 0
    var deviceTested = false
    #if canImport(GameController)
    // Test ALL connected external controller haptics
    let controllers = GCController.controllers()
    if #available(iOS 14.0, tvOS 14.0, * ) {
      for controller in controllers {
        if let haptics = controller.haptics {
          do {
            let engine = try haptics.createEngine(withLocality: .default)
            try engine?.start()
            // Simple transient pulse
            let pattern = try CHHapticPattern(events: [
              CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.9),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.8)
              ], relativeTime: 0)
            ], parameters: [])
            if let engine = engine {
              let player = try engine.makePlayer(with: pattern)
              try player.start(atTime: 0)
              controllersTestedCount += 1
            }
          } catch {
          }
        }
      }
    }
    #endif
    #if canImport(CoreHaptics)
    if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
      do {
        let engine = try CHHapticEngine()
        try engine.start()
        let pattern = try CHHapticPattern(events: [
          CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
          ], relativeTime: 0)
        ], parameters: [])
        let player = try engine.makePlayer(with: pattern)
        try player.start(atTime: 0)
        deviceTested = true
      } catch {
      }
    }
    #endif
    let message: String
    if controllersTestedCount > 0 && deviceTested {
      message = String(format: L("Tested %d controller(s) + device rumble"), controllersTestedCount)
    } else if controllersTestedCount > 0 {
      message = String(format: L("Tested %d controller(s) rumble"), controllersTestedCount)
    } else if deviceTested {
      message = L("Tested device rumble")
    } else {
      message = L("No haptic feedback available")
    }
    NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": message])
  }

  private func mfiControllerTitle(_ controller: GCController, index: Int) -> String {
    // Prefer the product category (e.g., "Gamepad", "DualSense") when available
    let category = controller.productCategory
    if !category.isEmpty { return category }
    if let vendor = controller.vendorName, !vendor.isEmpty { return vendor }
    return "Controller"
  }

  private func mfiControllerDetail(_ controller: GCController) -> String {
    // Compose a stable short identifier to disambiguate same-model controllers
    let ptr = Unmanaged.passUnretained(controller).toOpaque()
    let hex = String(format: "%p", Int(bitPattern: ptr))
    let shortId = hex.count > 4 ? String(hex.suffix(4)) : hex
    let vendor = controller.vendorName ?? ""
    let category = controller.productCategory
    var parts: [String] = []
    if !vendor.isEmpty { parts.append(vendor) }
    if !category.isEmpty { parts.append(category) }
    parts.append(shortId)
    return parts.joined(separator: " · ")
  }
#endif
}

private enum TouchIRMode: Int, CaseIterable { case gyro = 0, follow = 1, drag = 2
  var label: String { switch self { case .gyro: return L("Gyro"); case .follow: return L("Follow"); case .drag: return L("Drag") } }
  static func from(raw: Int) -> TouchIRMode { TouchIRMode(rawValue: raw) ?? .drag }
}

private struct TouchIRModePicker: View {
  @Binding var selected: TouchIRMode
  var body: some View {
    List {
      ForEach(Array(TouchIRMode.allCases.enumerated()), id: \.offset) { _, value in
        SelectRow(label: value.label, checked: value == selected) { selected = value; DOLConfigBridge.setMainTouchPadIRMode(value.rawValue) }
      }
    }
    .navigationTitle(L("Touch IR Pointer"))
  }
}

struct DebugRootView: View {
  @State private var fastmem: Bool = false
  @State private var mfiConnect: Bool = false
  @State private var userFolder: String = ""
  @State private var jitAcquired: Bool = false
  @State private var jitError: String = ""
  @State private var fastmemAvailable: Bool = false
  @State private var launchTimes: Int = 0
  @State private var loggingEnabled: Bool = false
  @State private var loggingVerbosity: Int = 4
  @State private var inputDebug: Bool = false
  @State private var instantReplay: Bool = false
  @State private var hydrated: Bool = false
  @AppStorage("library_disable_artwork") private var disableArtwork: Bool = false

  var body: some View {
    List {
      Section(header: Text(L("CPU / Memory"))) {
        settingsCaption(
          Toggle(L("Fastmem"), isOn: $fastmem)
            .onChange(of: fastmem) { DOLConfigBridge.setMainFastmem($0) }
            .disabled(!fastmemAvailable),
          L("Fast memory-access path for the CPU emulator. A large speedup where supported; disabled if the device can't provide it."))
      }

      Section(header: Text(L("Controllers"))) {
        settingsCaption(
          Toggle(L("Connect MFi Controllers"), isOn: $mfiConnect)
            .onChange(of: mfiConnect) { _ in
              UserDefaults.standard.set(mfiConnect, forKey: "virtual_mfi_connect")
            },
          L("Routes connected MFi/Bluetooth game controllers into the emulator."))
      }

      Section(header: Text(L("Recording"))) {
#if os(iOS)
        settingsCaption(
          Toggle(L("Enable ReplayKit Instant Replay"), isOn: $instantReplay)
            .onChange(of: instantReplay) { UserDefaults.standard.set($0, forKey: "replaykit_instant_replay_enabled") },
          L("Continuously buffers gameplay for instant replay. May reduce performance on older devices."))
#endif
      }

      Section(header: Text(L("Environment"))) {
        HStack { Text(L("User Folder")); Spacer(); Text(userFolder).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
        HStack { Text(L("JIT")); Spacer(); Text(jitAcquired ? L("Acquired") : L("Not Acquired")).foregroundStyle(.secondary) }
        HStack { Text(L("JIT Error")); Spacer(); Text(jitError.isEmpty ? "(none)" : jitError).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
        HStack { Text(L("Fastmem")); Spacer(); Text(fastmemAvailable ? L("Available") : L("Not Available")).foregroundStyle(.secondary) }
      }

      Section(header: Text(L("Diagnostics"))) {
        HStack { Text(L("Launch Times")); Spacer(); Text("\(launchTimes)").foregroundStyle(.secondary) }
        Button(L("Reset Launch Times")) { launchTimes = 0; UserDefaults.standard.set(0, forKey: "launch_times") }
        #if canImport(CoreMotion)
        NavigationLink(destination: MotionDebugView()) {
          Label(L("Motion Debug"), systemImage: "sensor.tag.radiowaves.forward")
        }
        #endif // canImport(CoreMotion)
      }

      Section(header: Text(L("Logging"))) {
        settingsCaption(
          Toggle(L("Enable Console Logging"), isOn: $loggingEnabled)
            .onChange(of: loggingEnabled) { UserDefaults.standard.set($0, forKey: "logger_console_enabled") },
          L("Writes core log messages to the device console. For diagnostics; leave off for normal use."))
        settingsCaption(
          HStack {
            Text(L("Verbosity"))
            Spacer()
            Button("\(loggingVerbosity)") {
              var v = UserDefaults.standard.integer(forKey: "logger_console_verbosity"); if v <= 0 { v = 4 }
              v = (v % 5) + 1
              UserDefaults.standard.set(v, forKey: "logger_console_verbosity")
              loggingVerbosity = v
            }
            .buttonStyle(.bordered)
          },
          L("How much detail the log captures (1 = errors only, 5 = everything)."))
        settingsCaption(
          Toggle(L("Input Event Debug"), isOn: $inputDebug)
            .onChange(of: inputDebug) { UserDefaults.standard.set($0, forKey: "input_debug") },
          L("Logs every controller/touch input event. Noisy; for input troubleshooting only."))
      }

      Section(header: Text(L("Screenshots / Artwork"))) {
        settingsCaption(
          Toggle(L("Use Template Covers (Disable Artwork)"), isOn: $disableArtwork),
          L("Hides downloaded box art and shows platform templates (GameCube/Wii) instead. Handy for App Store screenshots."))
      }
    }
    .navigationTitle(L("Debug"))
    .task {
      if !hydrated {
        hydrated = true
        await withTaskGroup(of: Void.self) { group in
          group.addTask { await syncDebugAsync() }
        }
      }
    }
  }

  private func syncDebug() {
    // Kept for potential call-sites; now delegates to async variant
    Task { await syncDebugAsync() }
  }

  private func syncDebugChunk1() async {
    await MainActor.run {
      fastmem = DOLConfigBridge.mainFastmem()
      mfiConnect = UserDefaults.standard.bool(forKey: "virtual_mfi_connect")
      fastmemAvailable = (FastmemManager.shared().fastmemAvailable)
      launchTimes = UserDefaults.standard.integer(forKey: "launch_times")
    }
  }

  private func syncDebugChunk2() async {
    let folder = UserFolderUtil.getUserFolder()
    await MainActor.run { userFolder = folder }
  }

  private func syncDebugChunk3() async {
    let acquired = JitManager.shared().acquiredJit
    let error = JitManager.shared().acquisitionError ?? ""
    await MainActor.run {
      jitAcquired = acquired
      jitError = error
    }
  }

  private func syncDebugChunk4() async {
    let logEnabled = UserDefaults.standard.bool(forKey: "logger_console_enabled")
    var v = UserDefaults.standard.integer(forKey: "logger_console_verbosity"); if v <= 0 { v = 4 }
    let inputDbg = UserDefaults.standard.bool(forKey: "input_debug")
    let ir = UserDefaults.standard.bool(forKey: "replaykit_instant_replay_enabled")
    await MainActor.run {
      loggingEnabled = logEnabled
      loggingVerbosity = v
      inputDebug = inputDbg
      instantReplay = ir
    }
  }

  private func syncDebugAsync() async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await syncDebugChunk1() }
      group.addTask { await syncDebugChunk2() }
      group.addTask { await syncDebugChunk3() }
      group.addTask { await syncDebugChunk4() }
    }
  }
}

struct AboutView: View {
  @Environment(\.openURL) private var openURL
  @State private var logoScale: CGFloat = 1.0
  @State private var logoRotation: Double = 0.0
  @State private var sparkleOpacity: Double = 0.3

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        // Top spacer to mimic storyboard padding
        Color.clear.frame(height: 0)
        // Animated dolphin with sparkle effects
        ZStack {
          // Subtle sparkles around the dolphin
          ForEach(0..<6, id: \.self) { index in
            Image(systemName: "sparkle")
              .font(.system(size: 12))
              .foregroundColor(.blue.opacity(0.6))
              .offset(
                x: cos(Double(index) * .pi / 3) * 80,
                y: sin(Double(index) * .pi / 3) * 80
              )
              .opacity(sparkleOpacity)
              .animation(.easeInOut(duration: 2.0).delay(Double(index) * 0.2).repeatForever(autoreverses: true), value: sparkleOpacity)
          }

          // Main dolphin logo with gentle animation
          Image("iCube-Logo-Square-NoText")
            .resizable()
            .scaledToFit()
            .frame(height: 128)
            .scaleEffect(logoScale)
            .rotationEffect(.degrees(logoRotation))
            .animation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true), value: logoScale)
            .animation(.easeInOut(duration: 4.0).repeatForever(autoreverses: true), value: logoRotation)
            .tint(Color("DolphinTint"))
        }
        .frame(height: 160)
        .onAppear {
          startAboutAnimation()
        }

        Text("iCube")
          .font(.system(size: 28, weight: .semibold))
          .foregroundColor(.blue)

        Text("© 2003-2015+ Dolphin Team.\n© 2025+ iCube Project.")
          .multilineTextAlignment(.center)

        Text("SwiftUI version by Joe Mattiello")
          .multilineTextAlignment(.center)

        Button("github.com/JoeMatt") {
          if let url = URL(string: "https://github.com/JoeMatt") {
            openURL(url)
          }
        }

        Text("iCube is an unofficial and separately maintained port of Dolphin to iOS. The iCube Project has no relation to Dolphin Team.")
          .multilineTextAlignment(.center)

        Text("\"GameCube\" and \"Wii\" are trademarks of Nintendo. iCube is not affiliated with Nintendo in any way.")
          .multilineTextAlignment(.center)

        Text("This software should not be used to play games you do not legally own.")
          .multilineTextAlignment(.center)

        Button(L("Source Code")) {
          if let url = URL(string: "https://github.com/provenance-Emu/icube") {
            openURL(url)
          }
        }

        Color.clear.frame(height: 0)
      }
      .padding(.horizontal, 20)
      .frame(maxWidth: .infinity)
    }
    .navigationTitle(L("About Dolphin"))
  }

  private func startAboutAnimation() {
    logoScale = 1.05
    logoRotation = 3.0
    sparkleOpacity = 0.8
  }
}

#if os(tvOS)
struct HelpPlaceholderView: View {
  var body: some View {
    List { Text(L("TODO: Help content for tvOS")) }
      .navigationTitle(L("Help"))
  }
}
#endif

// MARK: - Config General (wired)

struct ConfigGeneralView: View {
  @State private var dualCore: Bool = false
  @State private var cheats: Bool = false
  @State private var mismatchedRegion: Bool = false
  @State private var autoDiscChange: Bool = false
  @State private var fastDiscSpeed: Bool = false
  @State private var dspThread: Bool = false
  @State private var speedLimitPercent: Int = 0
  @State private var fastForwardSpeedPercent: Int = 300
  @State private var fallbackRegion: Region = .ntscU

  var body: some View {
    List {
      Section(header: Text(L("Basic Settings"))) {
        settingsCaption(
          Toggle(L("Enable Dual Core (speedup)"), isOn: $dualCore)
            .onChange(of: dualCore) { DOLConfigBridge.setMainCpuThread($0) },
          L("Runs the emulated GPU on a separate thread from the emulated CPU (can deadlock some games on this interpreter)."))
        settingsCaption(
          Toggle(L("DSP Thread (speedup)"), isOn: $dspThread)
            .onChange(of: dspThread) { DOLConfigBridge.setMainDSPThread($0) },
          L("Runs audio emulation on its own thread. Small speedup; safe to leave ON."))
        settingsCaption(
          Toggle(L("Enable Cheats"), isOn: $cheats)
            .onChange(of: cheats) { DOLConfigBridge.setMainEnableCheats($0) },
          L("Activates AR/Gecko cheat codes for the running game."))
        settingsCaption(
          Toggle(L("Override Region Mismatch"), isOn: $mismatchedRegion)
            .onChange(of: mismatchedRegion) { DOLConfigBridge.setMainOverrideRegionSettings($0) },
          L("Lets a game boot under a different region's settings. Can cause issues; leave OFF unless a game needs it."))
        settingsCaption(
          Toggle(L("Auto Disc Change"), isOn: $autoDiscChange)
            .onChange(of: autoDiscChange) { DOLConfigBridge.setMainAutoDiscChange($0) },
          L("Automatically swaps to the next disc for multi-disc games."))
        settingsCaption(
          Toggle(L("Fast Disc Speed (speedup)"), isOn: $fastDiscSpeed)
            .onChange(of: fastDiscSpeed) { DOLConfigBridge.setMainFastDiscSpeed($0) },
          L("Removes emulated disc-read delays. Speeds up loading in most games but breaks a few that depend on real timing."))
      }

      Section(header: Text(L("Speed"))) {
        settingsNavCaption(
          destination: SpeedLimitPicker(selectedPercent: $speedLimitPercent),
          L("Caps emulation speed as a percentage of real hardware. 100% is full speed; Unlimited runs as fast as the device allows. Lower it only to slow a game down deliberately.")
        ) {
          HStack {
            Label(L("Speed Limit"), systemImage: "speedometer")
            Spacer()
            Text(speedLimitLabel(percent: speedLimitPercent))
              .foregroundStyle(.secondary)
          }
        }
        .onChange(of: speedLimitPercent) { DOLConfigBridge.setMainEmulationSpeedPercent($0) }

        settingsNavCaption(
          destination: FastForwardSpeedPicker(selectedPercent: $fastForwardSpeedPercent),
          L("Speed used while the fast-forward button is held. Unlimited runs as fast as possible; the CPU-bound interpreter may not reach high multiples.")
        ) {
          HStack {
            Label(L("Fast Forward Speed"), systemImage: "forward.fill")
            Spacer()
            Text(fastForwardSpeedLabel(percent: fastForwardSpeedPercent))
              .foregroundStyle(.secondary)
          }
        }
        .onChange(of: fastForwardSpeedPercent) { UserDefaults.standard.set($0, forKey: "fast_forward_speed_percent") }
      }

      Section(header: Text(L("Fallback Region"))) {
        settingsNavCaption(
          destination: FallbackRegionPicker(selected: $fallbackRegion),
          L("Region used for titles whose region can't be detected automatically.")
        ) {
          Text("\(L("Fallback Region")): \(fallbackRegion.label)")
        }
        .onChange(of: fallbackRegion) { DOLConfigBridge.setMainFallbackRegion($0.rawValue) }
      }
    }
    .navigationTitle(L("General"))
    .onAppear { syncFromConfig() }
  }

  private func syncFromConfig() {
    dualCore = DOLConfigBridge.mainCpuThread()
    cheats = DOLConfigBridge.mainEnableCheats()
    mismatchedRegion = DOLConfigBridge.mainOverrideRegionSettings()
    autoDiscChange = DOLConfigBridge.mainAutoDiscChange()
    fastDiscSpeed = DOLConfigBridge.mainFastDiscSpeed()
    dspThread = DOLConfigBridge.mainDSPThread()
    speedLimitPercent = DOLConfigBridge.mainEmulationSpeedPercent()
    let ffSpeed = UserDefaults.standard.integer(forKey: "fast_forward_speed_percent")
    fastForwardSpeedPercent = (ffSpeed > 0) ? ffSpeed : 300 // Default to 3x speed
    let regionRaw = DOLConfigBridge.mainFallbackRegion()
    let regionVal = Region.from(raw: regionRaw)
    if regionVal == .unknown {
      fallbackRegion = .ntscU
      DOLConfigBridge.setMainFallbackRegion(Region.ntscU.rawValue)
    } else {
      fallbackRegion = regionVal
    }
  }

  private func speedLimitLabel(percent: Int) -> String {
    if percent == 0 { return L("Unlimited") }
    if percent == 100 { return String(format: "%d%% (%@)", percent, L("Normal Speed")) }
    return "\(percent)%"
  }

  private func fastForwardSpeedLabel(percent: Int) -> String {
    if percent == 0 { return L("Unlimited") }
    if percent == 100 { return String(format: "%d%% (%@)", percent, L("Normal Speed")) }
    return "\(percent)%"
  }
}

private enum Region: Int, CaseIterable { case ntscJ = 0, ntscU = 1, pal = 2, unknown = 3, ntscK = 4
  var label: String { switch self { case .ntscJ: return "NTSC-J"; case .ntscU: return "NTSC-U"; case .pal: return "PAL"; case .ntscK: return "NTSC-K"; case .unknown: return "Error" } }
  static func from(raw: Int) -> Region { Region(rawValue: raw) ?? .unknown }
}

private struct SpeedLimitPicker: View {
  @Binding var selectedPercent: Int
  @State private var showHelp = false
  var body: some View {
    List {
      SelectRow(label: L("Unlimited"), checked: selectedPercent == 0) { selectedPercent = 0 }
      ForEach(1..<21) { idx in
        let value = idx * 10
        let text = value == 100 ? String(format: "%d%% (%@)", value, L("Normal Speed")) : "\(value)%"
        SelectRow(label: text, checked: selectedPercent == value) { selectedPercent = value }
      }
    }
    .navigationTitle(L("Speed Limit"))
    .toolbar { HelpButton(helpKey:
                            "Controls how fast emulation runs relative to the original hardware.<br><br>Values higher than 100% will emulate faster than the original hardware can run, if your hardware is able to keep up. Values lower than 100% will slow emulation instead. Unlimited will emulate as fast as your hardware is able to.<br><br><dolphin_emphasis>If unsure, select 100%.</dolphin_emphasis>") }
  }
}

private struct FastForwardSpeedPicker: View {
  @Binding var selectedPercent: Int
  @State private var showHelp = false
  var body: some View {
    List {
      SelectRow(label: L("Unlimited"), checked: selectedPercent == 0) { selectedPercent = 0 }
      ForEach([200, 300, 400, 500, 600, 800, 1000], id: \.self) { value in
        let text = "\(value)% (\(value/100)x)"
        SelectRow(label: text, checked: selectedPercent == value) { selectedPercent = value }
      }
    }
    .navigationTitle(L("Fast Forward Speed"))
    .toolbar { HelpButton(helpKey:
                            "Controls the speed multiplier when fast forward is enabled.<br><br>Higher values will run the game faster, but may impact performance. 300% (3x speed) is recommended for most games.<br><br><dolphin_emphasis>If unsure, select 300% (3x).</dolphin_emphasis>") }
  }
}

private struct FallbackRegionPicker: View {
  @Binding var selected: Region
  var body: some View {
    List {
      ForEach(Region.allCases, id: \.rawValue) { r in
        SelectRow(label: r.label, checked: r == selected) { selected = r }
      }
    }
    .navigationTitle(L("Fallback Region"))
    .toolbar { HelpButton(helpKey:
                            "Sets the region used for titles whose region cannot be determined automatically.<br><br>This setting cannot be changed while emulation is active.") }
  }
}

// MARK: tvOS-friendly selectable row
private struct SelectRow: View {
  let label: String
  let checked: Bool
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      HStack {
        Text(label)
        Spacer()
        if checked { Image(systemName: "checkmark") }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
#if os(tvOS)
    .buttonStyle(.automatic)
#else
    .buttonStyle(.plain)
#endif
#if os(tvOS)
    .focusable(true)
#endif
  }
}

// MARK: tvOS fallback for sliders
internal struct TVIntStepper: View {
  @Binding var value: Int
  let range: ClosedRange<Int>
  let step: Int
#if os(tvOS)
  @FocusState private var isFocused: Bool
#endif
  var body: some View {
#if os(tvOS)
    HStack(spacing: 16) {
      Image(systemName: "minus.circle")
      Text("\(value)")
      Image(systemName: "plus.circle")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .focusable(true)
    .focused($isFocused)
    .padding(8)
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: 4)
    )
    .animation(.easeInOut(duration: 0.12), value: isFocused)
    .onMoveCommand { direction in
      switch direction {
      case .left:
        value = max(range.lowerBound, value - step)
      case .right:
        value = min(range.upperBound, value + step)
      default:
        break
      }
    }
#else
    HStack(spacing: 16) {
      Button("−") { value = max(range.lowerBound, value - step) }
      Text("\(value)")
      Button("+") { value = min(range.upperBound, value + step) }
    }
#endif
  }
}

// MARK: Tooltip helper
private struct HelpButton: ToolbarContent {
  let helpKey: String
  func helpText() -> String {
    let raw = L(helpKey)
    return raw
      .replacingOccurrences(of: "<br><br>", with: "\n\n")
      .replacingOccurrences(of: "<br>", with: "\n")
      .replacingOccurrences(of: "<dolphin_emphasis>", with: "")
      .replacingOccurrences(of: "</dolphin_emphasis>", with: "")
  }
  var body: some ToolbarContent {
    ToolbarItem(placement: .navigationBarTrailing) {
      HelpSheetButton(text: helpText())
    }
  }
}

private struct HelpSheetButton: View {
  let text: String
  @State private var showing = false
  var body: some View {
    Button { showing = true } label: { Image(systemName: "info.circle") }
      .sheet(isPresented: $showing) {
        NavigationStack {
          ScrollView { Text(text).padding() }
            .navigationTitle(L("Help"))
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button(L("Close")) { showing = false } } }
        }
      }
  }
}

// MARK: - Config Advanced (wired)

struct ConfigAdvancedView: View {
  @State private var cpuEngine: CpuEngine = .jitARM64
  /// True when the runtime acquired a JIT entitlement. On the App Store (jitless)
  /// build this is always false, so JIT engine choices are hidden and the core
  /// silently runs the Cached Interpreter (see EmulationViewController fallback).
  @State private var jitAvailable: Bool = false
  @State private var mmu: Bool = false
  // iCube perf settings — @AppStorage (same keys the ObjC++ EmulationCoordinator reads).
  @AppStorage("adaptive_clock_enable") private var adaptiveClock: Bool = false
  @AppStorage("icube_vertex_loader_mode") private var vertexLoaderMode: Int = 1 // TEMP default NEON (testing); 0=Software,1=NEON,2=Compare; applied on game (re)launch
  @State private var pauseOnPanic: Bool = false
  @State private var writeBackCache: Bool = false
  @State private var disableICache: Bool = false
  @State private var lowDCBZ: Bool = false
  // iCube perf A/B toggles. Both default ON; apply on next game launch.
  @State private var cachedInterpreterPrefetch: Bool = true
  @State private var neonTextureDecode: Bool = true
  // CIR perf A/B knobs: PIC on by default; fusion + block-linking off (experimental)
  @State private var cirPicLoadStore: Bool = true
  @State private var cirMicroOpFusion: Bool = false
  @State private var cirBlockLinking: Bool = false
  // CPU idle detection toggles
  @State private var relaxedIdleDetection: Bool = false
  @State private var fastForwardCtrIdle: Bool = false
  @State private var syncOnSkipIdle: Bool = true

  @State private var cpuClockEnabled: Bool = false
  @State private var cpuClockPercent: Int = 100

  @State private var vbiEnabled: Bool = false
  @State private var vbiPercent: Int = 100

  @State private var memOverride: Bool = false
  @State private var mem1MB: Int = 24
  @State private var mem2MB: Int = 64

  @State private var rtcEnabled: Bool = false
  @State private var rtcDate: Date = Date(timeIntervalSince1970: 946684800) // 2000-01-01 UTC

  var body: some View {
    List {
      Section(header: Text(L("CPU Options")),
              footer: Text(jitAvailable
                           ? L("These options control the PowerPC CPU emulation. On iCube the emulated CPU is almost always the performance bottleneck, so the CPU options below matter far more than any graphics setting.")
                           : L("This build runs without JIT, so games always use the Cached Interpreter (the JIT engine choices are hidden). The emulated CPU is the performance bottleneck on iCube — these options matter far more than any graphics setting."))) {
        NavigationLink("\(L("CPU Emulation Engine")): \(effectiveCpuEngineLabel)", destination: CpuEnginePicker(selected: $cpuEngine, jitAvailable: jitAvailable))
          .onChange(of: cpuEngine) { DOLConfigBridge.setMainCpuCore($0.rawValue) }
        rowWithCaption(
          Toggle(L("Enable MMU"), isOn: $mmu)
            .onChange(of: mmu) { DOLConfigBridge.setMainMMU($0) },
          L("Emulates the PowerPC memory management unit. Required by a small number of games (e.g. some Star Wars titles) but adds CPU overhead on every memory access, so it hurts the framerate on this already CPU-bound build. Leave OFF unless a specific game needs it."))
        rowWithCaption(
          Toggle(L("Adaptive Clock (auto VI/CPU)"), isOn: $adaptiveClock),
          L("Lets iCube auto-tune the emulated CPU/VI clock to trade accuracy for speed when frames run long. Experimental iCube option. Applies on next game launch."))
        VStack(alignment: .leading, spacing: 4) {
          Picker(L("Vertex Loader"), selection: $vertexLoaderMode) {
            Text(L("Software")).tag(0)
            Text(L("NEON SIMD (default)")).tag(1)
            Text(L("Compare (validate)")).tag(2)
          }
          Text(L("How vertex data is decoded on the CPU. NEON SIMD is the fast default on Apple Silicon; Software is the slow reference path; Compare runs both and asserts they match (debug only — slowest). Leave on NEON SIMD. Applies on next game launch."))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        rowWithCaption(
          Toggle(L("Pause on Panic"), isOn: $pauseOnPanic)
            .onChange(of: pauseOnPanic) { DOLConfigBridge.setMainPauseOnPanic($0) },
          L("Pauses emulation and shows a dialog when the core hits an internal error. Useful for debugging; leave OFF for normal play."))
        rowWithCaption(
          Toggle(L("Accurate CPU Cache (slower)"), isOn: $writeBackCache)
            .onChange(of: writeBackCache) { DOLConfigBridge.setMainAccurateCpuCache($0) },
          L("Emulates the PowerPC data cache more precisely. Fixes a few games that depend on cache timing, but noticeably slows the interpreter. Leave OFF unless a game misbehaves without it."))
        rowWithCaption(
          Toggle(L("Bypass Instruction Cache"), isOn: $disableICache)
            .onChange(of: disableICache) { DOLConfigBridge.setMainDisableICache($0) },
          L("Skips emulation of the PowerPC instruction cache. Can give a small CPU speedup but may cause bugs in games that rely on I-cache behavior. Usually keep OFF."))
        // "Fast FP" (MAIN_FP_FAST) toggle removed: it's vestigial — the config key gates nothing
        // in this interpreter build and can't be wired without a large architecture port. Config key
        // stays defined so the bridge/config layer doesn't break; only the dead UI row is dropped.
        rowWithCaption(
          Toggle(L("CachedInterpreter Prefetch (Apple Silicon)"), isOn: $cachedInterpreterPrefetch)
            .onChange(of: cachedInterpreterPrefetch) { DOLConfigBridge.setMainCachedInterpreterPrefetch($0) },
          L("Adds software-prefetch hints to the Cached Interpreter hot loop on Apple Silicon. ON by default and generally a small win on the CPU-bound path; an A/B knob you can turn off to compare. Applies on next game launch."))
        rowWithCaption(
          Toggle(L("NEON Texture Decoder"), isOn: $neonTextureDecode)
            .onChange(of: neonTextureDecode) { DOLConfigBridge.setGfxHackNeonTextureDecode($0) },
          L("ARM64 NEON SIMD texture decoder. ON by default; turning it off falls back to the slower scalar decoder. A/B knob. Applies on next game launch."))
        rowWithCaption(
          Toggle(L("PIC Load/Store (Cached Interpreter)"), isOn: $cirPicLoadStore)
            .onChange(of: cirPicLoadStore) { DOLConfigBridge.setCirPicLoadStore($0) },
          L("Direct-pointer load/store fast path for the Cached Interpreter — a large CPU win on memory-heavy games. ON by default; falls back safely for MMU / non-fastmem access. Turn off to A/B. Applies on next game launch."))
        rowWithCaption(
          Toggle(L("Micro-Op Fusion (Cached Interpreter, experimental)"), isOn: $cirMicroOpFusion)
            .onChange(of: cirMicroOpFusion) { DOLConfigBridge.setCirMicroOpFusion($0) },
          L("⚠️ Fuses runs of integer ops into one dispatched block on the Cached Interpreter — a meaningful CPU win. Experimental/unvalidated; may cause wrong math, physics, or audio in some games. OFF by default. Applies on next game launch."))
        rowWithCaption(
          Toggle(L("Block Linking (Cached Interpreter, experimental)"), isOn: $cirBlockLinking)
            .onChange(of: cirBlockLinking) { DOLConfigBridge.setCirBlockLinking($0) },
          L("⚠️ Chains hot interpreter blocks directly to cut per-block dispatcher overhead. Experimental; can affect timing-sensitive games. OFF by default. Applies on next game launch."))
        rowWithCaption(
          Toggle(L("DCBZ Hack"), isOn: $lowDCBZ)
            .onChange(of: lowDCBZ) { DOLConfigBridge.setMainLowDCBZHack($0) },
          L("Skips part of the dcbz (data-cache-block-zero) instruction. Can speed up a few games but breaks others (notably some Wii titles). Leave OFF unless you know a game needs it."))
        // CPU Idle Detection / Fast-Forward
        rowWithCaption(
          Toggle(L("Relaxed Idle Loop Detection"), isOn: $relaxedIdleDetection)
            .onChange(of: relaxedIdleDetection) { DOLConfigBridge.setMainRelaxedIdleDetection($0) },
          L("Detects more idle loops so the CPU can skip busy-waiting. ON helps reclaim CPU time on the bottlenecked interpreter; very rarely affects timing. Default ON."))
        rowWithCaption(
          Toggle(L("Fast-Forward CTR Idle Loops"), isOn: $fastForwardCtrIdle)
            .onChange(of: fastForwardCtrIdle) { DOLConfigBridge.setMainFastForwardCtrIdle($0) },
          L("Fast-forwards counter-based idle loops instead of emulating every iteration. Can recover CPU headroom; may slightly affect timing-sensitive games. iCube tuning knob."))
        rowWithCaption(
          Toggle(L("Sync on Skip Idle"), isOn: $syncOnSkipIdle)
            .onChange(of: syncOnSkipIdle) { DOLConfigBridge.setMainSyncOnSkipIdle($0) },
          L("When the CPU fast-forwards through an idle loop, flush the GPU so it stays in sync. ON by default for correctness; turning it off skips the flush for a small CPU win but can cause graphical glitches in some games. A/B knob."))
      }

      Section(header: Text(L("Clock Override"))) {
        rowWithCaption(
          Toggle(L("Enable Emulated CPU Clock Override"), isOn: $cpuClockEnabled)
            .onChange(of: cpuClockEnabled) { DOLConfigBridge.setMainOverclockEnable($0) },
          L("Adjusts the emulated CPU's clock rate. Higher values can raise the framerate of variable-rate games at a performance cost; lower values may trigger a game's internal frameskip. ⚠️ Changing this from 100% can and will break games — use at your own risk."))
        HStack {
#if os(tvOS)
          TVIntStepper(value: $cpuClockPercent, range: 1...400, step: 1)
#else
          Slider(value: Binding(get: { Double(cpuClockPercent) }, set: { cpuClockPercent = Int($0) }), in: 1...400)
            .frame(width: 260)
#endif
          Spacer()
          Text("\(cpuClockPercent)%")
            .foregroundStyle(.secondary)
        }
        .disabled(!cpuClockEnabled)
        .onChange(of: cpuClockPercent) { DOLConfigBridge.setMainOverclockPercent($0) }
      }

      Section(header: Text(L("Override VBI Frequency"))) {
        rowWithCaption(
          Toggle(L("Enable VBI Frequency Override"), isOn: $vbiEnabled)
            .onChange(of: vbiEnabled) { DOLConfigBridge.setMainViOverclockEnable($0) },
          L("Makes games run at a different frame rate. Lowering it makes emulation less demanding; raising it can improve smoothness. May change gameplay speed, since speed is often tied to frame rate."))
        HStack {
#if os(tvOS)
          TVIntStepper(value: $vbiPercent, range: 1...400, step: 1)
#else
          Slider(value: Binding(get: { Double(vbiPercent) }, set: { vbiPercent = Int($0) }), in: 1...400)
            .frame(width: 260)
#endif
          Spacer()
          Text("\(vbiPercent)%")
            .foregroundStyle(.secondary)
        }
        .disabled(!vbiEnabled)
        .onChange(of: vbiPercent) { DOLConfigBridge.setMainViOverclockPercent($0) }
      }

      Section(header: Text(L("Memory Override"))) {
        rowWithCaption(
          Toggle(L("Enable Emulated Memory Size Override"), isOn: $memOverride)
            .onChange(of: memOverride) { DOLConfigBridge.setMainRamOverrideEnable($0) },
          L("Changes the emulated console's RAM. MEM1 is main memory (24–64 MB); MEM2 is Wii extended memory (64–128 MB). ⚠️ Enabling this breaks many games and invalidates save states made at a different size."))
        HStack {
          Text("MEM1")
          Spacer()
#if os(tvOS)
          TVIntStepper(value: $mem1MB, range: 24...64, step: 1)
#else
          Slider(value: Binding(get: { Double(mem1MB) }, set: { mem1MB = Int($0) }), in: 24...64)
            .frame(width: 260)
#endif
        }
        .disabled(!memOverride)
        .onChange(of: mem1MB) { DOLConfigBridge.setMainMem1SizeMB($0) }
        HStack {
          Text("MEM2")
          Spacer()
#if os(tvOS)
          TVIntStepper(value: $mem2MB, range: 64...128, step: 1)
#else
          Slider(value: Binding(get: { Double(mem2MB) }, set: { mem2MB = Int($0) }), in: 64...128)
            .frame(width: 260)
#endif
        }
        .disabled(!memOverride)
        .onChange(of: mem2MB) { DOLConfigBridge.setMainMem2SizeMB($0) }
      }

      Section(header: Text(L("Custom RTC Options"))) {
        rowWithCaption(
          Toggle(L("Enable Custom RTC"), isOn: $rtcEnabled)
            .onChange(of: rtcEnabled) { DOLConfigBridge.setMainCustomRtcEnable($0) },
          L("Sets a custom real-time clock for the emulated console, separate from your device clock. Useful for time-based game events. If unsure, leave off."))
#if !os(tvOS)
        DatePicker("", selection: $rtcDate, displayedComponents: [.date, .hourAndMinute])
          .labelsHidden()
          .disabled(!rtcEnabled)
          .onChange(of: rtcDate) { DOLConfigBridge.setMainCustomRtcValue(Int($0.timeIntervalSince1970)) }
#endif
      }
    }
    .navigationTitle(L("Advanced"))
    .onAppear { syncAdvanced() }
  }

  /// The engine label to display. On jitless builds a stored JIT core actually
  /// runs as Cached Interpreter, so show that truth instead of the misleading
  /// "JIT (recommended)" the raw config would imply.
  private var effectiveCpuEngineLabel: String {
    if !jitAvailable && (cpuEngine == .jit64 || cpuEngine == .jitARM64) {
      return CpuEngine.cachedInterpreter.label
    }
    return cpuEngine.label
  }

  /// Inline secondary-text description under a row. Forwards to the canonical
  /// file-scope `settingsCaption` so there is one description style everywhere.
  @ViewBuilder
  private func rowWithCaption<Content: View>(_ content: Content, _ caption: String) -> some View {
    settingsCaption(content, caption)
  }

  private func syncAdvanced() {
    jitAvailable = JitManager.shared().acquiredJit
    cpuEngine = CpuEngine.from(raw: DOLConfigBridge.mainCpuCore())
    mmu = DOLConfigBridge.mainMMU()
    // adaptiveClock / vertexLoaderMode are @AppStorage now — auto-loaded, no manual sync needed.
    pauseOnPanic = DOLConfigBridge.mainPauseOnPanic()
    writeBackCache = DOLConfigBridge.mainAccurateCpuCache()
    disableICache = DOLConfigBridge.mainDisableICache()
    lowDCBZ = DOLConfigBridge.mainLowDCBZHack()
    cachedInterpreterPrefetch = DOLConfigBridge.mainCachedInterpreterPrefetch()
    neonTextureDecode = DOLConfigBridge.gfxHackNeonTextureDecode()
    cirPicLoadStore = DOLConfigBridge.cirPicLoadStore()
    cirMicroOpFusion = DOLConfigBridge.cirMicroOpFusion()
    cirBlockLinking = DOLConfigBridge.cirBlockLinking()
    // Ensure idle detection toggles persist
    relaxedIdleDetection = DOLConfigBridge.mainRelaxedIdleDetection()
    fastForwardCtrIdle = DOLConfigBridge.mainFastForwardCtrIdle()
    syncOnSkipIdle = DOLConfigBridge.mainSyncOnSkipIdle()
    // CI block linking toggle does not need local state; bound directly
    cpuClockEnabled = DOLConfigBridge.mainOverclockEnable()
    cpuClockPercent = DOLConfigBridge.mainOverclockPercent()
    vbiEnabled = DOLConfigBridge.mainViOverclockEnable()
    vbiPercent = DOLConfigBridge.mainViOverclockPercent()
    memOverride = DOLConfigBridge.mainRamOverrideEnable()
    mem1MB = DOLConfigBridge.mainMem1SizeMB()
    mem2MB = DOLConfigBridge.mainMem2SizeMB()
    rtcEnabled = DOLConfigBridge.mainCustomRtcEnable()
    rtcDate = Date(timeIntervalSince1970: TimeInterval(DOLConfigBridge.mainCustomRtcValue()))
  }
}

/// Shared inline-description helper. Wraps any control with a `.caption` secondary
/// line directly under it. This is the single canonical row style for the whole
/// settings surface — every page uses it instead of section footers or tap-to-open
/// info popovers, so descriptions are always visible inline.
@ViewBuilder
func settingsCaption<Content: View>(_ content: Content, _ caption: String) -> some View {
  VStack(alignment: .leading, spacing: 4) {
    content
    Text(caption)
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// NavigationLink row with an inline caption *inside* the link's label, so the row
/// keeps its disclosure chevron and full-row tap target (wrapping a NavigationLink
/// in an external VStack would strip both). `label` is the normal row content
/// (e.g. an HStack with title + trailing value).
@ViewBuilder
func settingsNavCaption<Destination: View, Label: View>(
  destination: Destination,
  _ caption: String,
  @ViewBuilder label: () -> Label
) -> some View {
  NavigationLink(destination: destination) {
    VStack(alignment: .leading, spacing: 4) {
      label()
      Text(caption)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private enum CpuEngine: Int, CaseIterable {
  case interpreter = 0
  case cachedInterpreter = 1
  case jit64 = 2
  case jitARM64 = 3
  var label: String {
    switch self {
    case .interpreter: return L("Interpreter (slowest)")
    case .cachedInterpreter: return L("Cached Interpreter (slower)")
    case .jit64: return L("JIT Recompiler for x86-64 (recommended)")
    case .jitARM64: return L("JIT Recompiler for ARM64 (recommended)")
    }
  }
  static func from(raw: Int) -> CpuEngine { CpuEngine(rawValue: raw) ?? .jitARM64 }
}

private struct CpuEnginePicker: View {
  @Binding var selected: CpuEngine
  /// When false (App Store / jitless build), JIT engine choices are hidden
  /// because the core cannot run them and silently falls back to the Cached
  /// Interpreter at launch.
  var jitAvailable: Bool = true
  private var choices: [CpuEngine] {
    jitAvailable ? CpuEngine.allCases : [.interpreter, .cachedInterpreter]
  }
  var body: some View {
    List {
      Section(footer: Text(jitAvailable
                           ? L("Cached Interpreter and the JIT recompilers are faster; the plain Interpreter is the most accurate but far too slow for full-speed play.")
                           : L("This build runs without a JIT entitlement, so only interpreter engines are available. Cached Interpreter is the recommended (and default) choice. Selecting a JIT engine on other builds would silently fall back to Cached Interpreter here."))) {
        ForEach(Array(choices.enumerated()), id: \.offset) { _, value in
          SelectRow(label: value.label, checked: value == selected) { selected = value; DOLConfigBridge.setMainCpuCore(value.rawValue) }
        }
      }
    }
    .navigationTitle(L("CPU Emulation Engine"))
  }
}

// MARK: - Config placeholders

/// Interface config placeholder
struct ConfigInterfaceView: View {
  @State private var useNamesDB: Bool = false
  @State private var useCovers: Bool = false
  @State private var confirmOnStop: Bool = true
  @State private var usePanicHandlers: Bool = true
  @State private var osdMessages: Bool = true

  // Library UI Settings
  @AppStorage("library_background_style") private var backgroundStyle: LibraryBackgroundStyle = .gradient
  @AppStorage("library_show_subtitles") private var showSubtitles: Bool = true

  enum LibraryBackgroundStyle: String, CaseIterable {
    case clean = "clean"
    case gradient = "gradient"
    case animated = "animated"

    var displayName: String {
      switch self {
      case .clean: return "Clean"
      case .gradient: return "GameCube Gradient"
      case .animated: return "Animated (Full Effects)"
      }
    }
  }

  /// Picker style that works across tvOS versions
  private var pickerStyleForPlatform: some PickerStyle {
    #if os(tvOS)
      if #available(tvOS 17.0, *) {
        return .menu
      } else {
        return .automatic
      }
    #else
      return .menu
    #endif
  }

  var body: some View {
    List {
      Section(header: Text(L("Game List"))) {
        settingsCaption(
          Toggle(L("Use Built-In Database of Game Names"), isOn: $useNamesDB)
            .onChange(of: useNamesDB) { DOLConfigBridge.setMainUseBuiltInTitleDatabase($0) },
          L("Replaces raw disc IDs with proper game titles from the built-in database."))
        settingsCaption(
          Toggle(L("Download Game Covers from GameTDB.com for Use in Grid Mode"), isOn: $useCovers)
            .onChange(of: useCovers) { DOLConfigBridge.setMainUseGameCovers($0) },
          L("Fetches box art from GameTDB.com over the network (once per game) for grid view. Turn off to stay fully offline."))
      }

      Section(header: Text(L("Library UI"))) {
        settingsCaption(
          HStack {
            Label("Background Style", systemImage: "paintbrush.fill")
            Spacer()
            Picker("Background Style", selection: $backgroundStyle) {
              ForEach(LibraryBackgroundStyle.allCases, id: \.self) { style in
                Text(style.displayName).tag(style)
              }
            }
            .pickerStyle(pickerStyleForPlatform)
            .labelsHidden()
          },
          L("Backdrop behind the game library. Animated adds full effects; Clean is the lightest."))
        settingsCaption(
          Toggle(isOn: $showSubtitles) {
            Label("Show Game ID Subtitles", systemImage: "textformat.123")
          },
          L("Shows each game's disc ID under its title in the library."))
      }

      Section(header: Text(L("General"))) {
        settingsCaption(
          Toggle(L("Confirm on Stop"), isOn: $confirmOnStop)
            .onChange(of: confirmOnStop) { DOLConfigBridge.setMainConfirmOnStop($0) },
          L("Asks before quitting a running game so you don't lose unsaved progress."))
        settingsCaption(
          Toggle(L("Use Panic Handlers"), isOn: $usePanicHandlers)
            .onChange(of: usePanicHandlers) { DOLConfigBridge.setMainUsePanicHandlers($0) },
          L("Shows a dialog when the core hits an internal error instead of failing silently."))
        settingsCaption(
          Toggle(L("Show On-Screen Display Messages"), isOn: $osdMessages)
            .onChange(of: osdMessages) { DOLConfigBridge.setMainOSDMessages($0) },
          L("Transient status overlays drawn over the game (save-state notices, performance toggles)."))
      }
    }
    .navigationTitle(L("Interface"))
    .onAppear { sync() }
  }

  private func sync() {
    useNamesDB = DOLConfigBridge.mainUseBuiltInTitleDatabase()
    useCovers = DOLConfigBridge.mainUseGameCovers()
    confirmOnStop = DOLConfigBridge.mainConfirmOnStop()
    usePanicHandlers = DOLConfigBridge.mainUsePanicHandlers()
    osdMessages = DOLConfigBridge.mainOSDMessages()
  }
}
/// Audio config placeholder
struct ConfigAudioView: View {
  @State private var backend: String = ""
  @State private var availableBackends: [String] = []
  @State private var volume: Int = 100
  @State private var stretch: Bool = false
  @State private var stretchLatency: Int = 30
  @State private var muteOnNoSpeedLimit: Bool = false
  @State private var obeyMuteSwitch: Bool = true

  var body: some View {
    List {
      Section(header: Text(L("Audio Backend"))) {
        NavigationLink(backend.isEmpty ? L("Default Device") : (backend == "AVAudioEngine" ? "AVAudioEngine" : (backend == "CoreAudio" ? "CoreAudio (Speakers/HDMI)" : backend)), destination: BackendPickerView(selected: $backend, options: availableBackends))
          .onChange(of: backend) { DOLConfigBridge.setAudioBackend($0) }
        Text(L("CoreAudio: Best for TV/HDMI speakers. AVAudioEngine: Enables AUv3 FXs."))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

#if os(iOS)
      if backend.contains("AVAudioEngine") {
        Section(header: Text(L("Master Effects Chain")), footer: Text(L("Effects apply post‑environment. Requires AVAudioEngine backend."))) {
          VStack { FXChainEditor() }
        }
      } else if backend.contains("CoreAudio") {
        Section(header: Text(L("CoreAudio Effects")), footer: Text(L("Built‑in echo, EQ, and bitcrush. Does not support AUv3 plugins."))) {
          CoreAudioDSPEditor(embedded: true)
        }
      }
#endif

      Section(header: Text(L("Volume"))) {
        HStack {
#if os(tvOS)
          TVIntStepper(value: $volume, range: 0...100, step: 1)
#else
          Slider(value: Binding(get: { Double(volume) }, set: { volume = Int($0) }), in: 0...100)
            .frame(width: 260)
#endif
          Spacer()
          Text("\(volume)%").foregroundStyle(.secondary)
        }
        .onChange(of: volume) { DOLConfigBridge.setAudioVolume($0) }
      }

      Section(header: Text(L("Audio Stretching Settings"))) {
        Toggle(L("Enable Audio Stretching"), isOn: $stretch)
          .onChange(of: stretch) { DOLConfigBridge.setAudioStretch($0) }
        HStack {
#if os(tvOS)
          TVIntStepper(value: $stretchLatency, range: 5...200, step: 1)
#else
          Slider(value: Binding(get: { Double(stretchLatency) }, set: { stretchLatency = Int($0) }), in: 5...200)
            .frame(width: 260)
#endif
          Spacer()
          Text(String(format: L("%1 ms"), stretchLatency)).foregroundStyle(.secondary)
        }
        .disabled(!stretch)
        .onChange(of: stretchLatency) { DOLConfigBridge.setAudioStretchLatencyMs($0) }
      }

      Section(header: Text(L("Misc. Controls"))) {
        Toggle(L("Mute When Disabling Speed Limit"), isOn: $muteOnNoSpeedLimit)
          .onChange(of: muteOnNoSpeedLimit) { DOLConfigBridge.setAudioMuteOnDisabledSpeedLimit($0) }
        Toggle(L("Use Mute Hardware Switch"), isOn: $obeyMuteSwitch)
          .onChange(of: obeyMuteSwitch) { DOLConfigBridge.setAudioMuteSwitchObey($0) }
      }
    }
    .navigationTitle(L("Audio"))
    .onAppear { syncAudio() }
  }

  private func syncAudio() {
    availableBackends = DOLConfigBridge.audioBackends()
    // Annotate entries to surface capabilities
    availableBackends = availableBackends.map { b in
      if b == "AVAudioEngine" { return "AVAudioEngine" }
      if b == "CoreAudio" { return "CoreAudio (Speakers/HDMI)" }
      return b
    }
    backend = DOLConfigBridge.audioBackend()
    // keep raw key for logic; present annotated in UI rows only
    volume = DOLConfigBridge.audioVolume()
    stretch = DOLConfigBridge.audioStretch()
    stretchLatency = DOLConfigBridge.audioStretchLatencyMs()
    muteOnNoSpeedLimit = DOLConfigBridge.audioMuteOnDisabledSpeedLimit()
    obeyMuteSwitch = DOLConfigBridge.audioMuteSwitchObey()
  }
}

private struct BackendPickerView: View {
  @Binding var selected: String
  let options: [String]
  @State private var pendingSelection: String? = nil
  @State private var showConfirm: Bool = false
  var body: some View {
    List {
      ForEach(options, id: \.self) { opt in
        SelectRow(label: opt, checked: opt == selected) {
          // Strip annotation before passing to bridge
          var raw = opt.replacingOccurrences(of: " (Supports Spatial Audio)", with: "")
          raw = raw.replacingOccurrences(of: " (Speakers/HDMI)", with: "")
          if raw == "AVAudioEngine" {
            pendingSelection = opt
            showConfirm = true
          } else {
            selected = opt
            DOLConfigBridge.setAudioBackend(raw)
          }
        }
      }
    }
    .navigationTitle(L("Audio Backend"))
    .alert(L("Enable AVAudioEngine?"), isPresented: $showConfirm) {
      Button(L("Enable")) {
        if let opt = pendingSelection {
          selected = opt
          var raw = opt.replacingOccurrences(of: " (Supports Spatial Audio)", with: "")
          raw = raw.replacingOccurrences(of: " (Speakers/HDMI)", with: "")
          DOLConfigBridge.setAudioBackend(raw)
        }
        pendingSelection = nil
      }
      Button(L("Cancel"), role: .cancel) { pendingSelection = nil }
    } message: {
      Text(L("AVAudioEngine is in development and not recommended for general usage yet. Are you sure?"))
    }
  }
}
/// GameCube config placeholder
struct ConfigGameCubeView: View {
  @State private var skipIPL: Bool = false
  @State private var gcLanguage: Int = 0 // English; real value set in syncGC() from config/locale
  var body: some View {
    List {
      Section(header: Text(L("General"))) {
        settingsCaption(
          Toggle(L("Load GameCube Main Menu"), isOn: Binding(get: { !skipIPL }, set: { skipIPL = !$0 }))
            .onChange(of: skipIPL) { DOLConfigBridge.setMainSkipIPL($0) },
          L("Boots through the console's startup menu (IPL/BIOS animation) instead of straight into the game. Needs a matching-region GameCube IPL dump; without one, games boot directly anyway. Turn off to start games faster."))
      }

      Section(header: Text(L("System Language"))) {
        settingsNavCaption(
          destination: GCLanguagePicker(selected: $gcLanguage),
          L("Language the emulated GameCube reports to games. The GameCube supports English, German, French, Spanish, Italian, and Dutch only. Defaults to your device language where supported, otherwise English.")
        ) {
          Text(languageLabel(for: gcLanguage))
        }
        .onChange(of: gcLanguage) { DOLConfigBridge.setMainGCLanguage($0) }
      }
    }
    .navigationTitle(L("GameCube"))
    .onAppear { syncGC() }
  }

  private func syncGC() {
    skipIPL = DOLConfigBridge.mainSkipIPL()
    // Bug 6: MAIN_GC_LANGUAGE ("SelectedLanguage") is a 0-based GameCube index:
    // 0=English, 1=German, 2=French, 3=Spanish, 4=Italian, 5=Dutch (DiscIO::FromGameCubeLanguage
    // maps index N -> Language(N+1), so 0 == English; the GameCube IPL has no Japanese option).
    // The picker previously mislabeled this as the Wii order (0=Japanese, 1=English, ...), which
    // made the stored default 0 display as "Japanese" and made selecting "English" store 1 (German).
    if DOLConfigBridge.mainGCLanguageIsSet() {
      // User has an explicit value persisted: trust it, but clamp to the valid GC range in case
      // it was written by the old buggy 0...6 picker.
      let lang = DOLConfigBridge.mainGCLanguage()
      gcLanguage = (0...5).contains(lang) ? lang : 0
    } else {
      // First run / never chosen: derive a sensible default from the device locale,
      // falling back to English, and persist it so the picker reflects it.
      let derived = ConfigGameCubeView.gcLanguageFromLocale()
      gcLanguage = derived
      DOLConfigBridge.setMainGCLanguage(derived)
    }
  }

  /// Maps the user's preferred language to the nearest GameCube IPL language index.
  /// GameCube supports only English/German/French/Spanish/Italian/Dutch; everything
  /// else (incl. Japanese, which the GC IPL menu has no entry for) falls back to English.
  static func gcLanguageFromLocale() -> Int {
    let code = (Locale.preferredLanguages.first
                ?? Locale.current.identifier).lowercased()
    // Match on the leading ISO-639 language subtag.
    if code.hasPrefix("de") { return 1 } // German
    if code.hasPrefix("fr") { return 2 } // French
    if code.hasPrefix("es") { return 3 } // Spanish
    if code.hasPrefix("it") { return 4 } // Italian
    if code.hasPrefix("nl") { return 5 } // Dutch
    return 0 // English (also the fallback for en/ja/zh/ko/etc.)
  }

  private func languageLabel(for value: Int) -> String {
    switch value { case 0: return L("English"); case 1: return L("German"); case 2: return L("French"); case 3: return L("Spanish"); case 4: return L("Italian"); case 5: return L("Dutch"); default: return L("Error") }
  }
}

private struct GCLanguagePicker: View {
  @Binding var selected: Int
  private let options: [Int] = [0, 1, 2, 3, 4, 5]
  var body: some View {
    List {
      ForEach(options, id: \.self) { v in
        SelectRow(label: label(v), checked: v == selected) { selected = v; DOLConfigBridge.setMainGCLanguage(v) }
      }
    }
    .navigationTitle(L("System Language"))
  }
  private func label(_ v: Int) -> String {
    switch v { case 0: return L("English"); case 1: return L("German"); case 2: return L("French"); case 3: return L("Spanish"); case 4: return L("Italian"); case 5: return L("Dutch"); default: return L("Error") }
  }
}
/// Wii config placeholder
struct ConfigWiiView: View {
  @State private var pal60: Bool = false
  @State private var screensaver: Bool = false
  @State private var keyboard: Bool = false
  @State private var wiilink: Bool = false
  @State private var sdCard: Bool = false
  @State private var sdWrites: Bool = false
  @State private var sdFolderSync: Bool = false
  @State private var widescreen: Bool = false
  @State private var language: Int = 1
  @State private var soundMode: Int = 1
  @State private var sensorBarPos: Int = 0
  @State private var sensorBarSens: Int = 2
  @State private var speakerVol: Int = 4
  @State private var wiimoteRumble: Bool = true
  @State private var touchpadIRFollowWithoutClick: Bool = false

  var body: some View {
    List {
      Section(header: Text(L("Video")), footer: Text(L("These write to the emulated Wii's SYSCONF, so they affect Wii titles only and persist like a real Wii would."))) {
        settingsCaption(
          Toggle(L("Use PAL60 Mode (EuRGB60)"), isOn: $pal60).onChange(of: pal60) { DOLConfigBridge.setSysconfPAL60($0) },
          L("Lets PAL games output 60 Hz (EuRGB60) when supported."))
        /// Wii System Aspect Ratio (4:3 vs 16:9)
        settingsNavCaption(
          destination: WiiAspectRatioPicker(selectedWide: $widescreen),
          L("Sets the console's 4:3 vs 16:9 flag, which many Wii games read to choose their own widescreen rendering.")
        ) {
          HStack { Text(L("Aspect Ratio")); Spacer(); Text(widescreen ? "16:9" : "4:3").foregroundStyle(.secondary) }
        }
        .onChange(of: widescreen) { DOLConfigBridge.setSysconfWidescreen($0) }
      }

      Section(header: Text(L("General"))) {
        settingsCaption(
          Toggle(L("Enable Screen Saver"), isOn: $screensaver).onChange(of: screensaver) { DOLConfigBridge.setSysconfScreensaver($0) },
          L("Controls the emulated Wii's idle dimming only. No effect on this device's battery or performance."))
        settingsNavCaption(
          destination: WiiLanguagePicker(selected: $language),
          L("The Wii's own menu language; games read it to pick their in-game language.")
        ) {
          HStack { Text(L("System Language")); Spacer(); Text(languageLabel(language)).foregroundStyle(.secondary) }
        }
        .onChange(of: language) { DOLConfigBridge.setSysconfLanguage($0) }
        settingsNavCaption(
          destination: WiiAudioModePicker(selected: $soundMode),
          L("The Wii's audio output mode (Mono/Stereo/Surround); games read it to choose their output.")
        ) {
          HStack { Text(L("Audio Settings")); Spacer(); Text(audioModeLabel(soundMode)).foregroundStyle(.secondary) }
        }
        .onChange(of: soundMode) { DOLConfigBridge.setSysconfSoundMode($0) }
      }

      Section(header: Text(L("Wii Remotes"))) {
        settingsNavCaption(
          destination: WiiSensorBarPosPicker(selected: $sensorBarPos),
          L("Must match where the game thinks the sensor bar sits (Top/Bottom) or the pointer inverts. On iCube the pointer is touch-driven, so set it to the game's expectation.")
        ) {
          HStack { Text(L("Sensor Bar Position")); Spacer(); Text(posLabel(sensorBarPos)).foregroundStyle(.secondary) }
        }
        .onChange(of: sensorBarPos) { DOLConfigBridge.setSysconfSensorBarPosition($0) }
        settingsCaption(
          HStack {
            Text(L("IR Sensitivity")); Spacer()
#if os(tvOS)
            TVIntStepper(value: $sensorBarSens, range: 1...5, step: 1)
#else
            Slider(value: Binding(get: { Double(sensorBarSens) }, set: { sensorBarSens = Int($0) }), in: 1...5)
              .frame(width: 260)
#endif
          }
          .onChange(of: sensorBarSens) { DOLConfigBridge.setSysconfSensorBarSensitivity($0) },
          L("Mirrors the real Wii's IR sensitivity slider."))
        settingsCaption(
          HStack {
            Text(L("Speaker Volume")); Spacer()
#if os(tvOS)
            TVIntStepper(value: $speakerVol, range: 0...7, step: 1)
#else
            Slider(value: Binding(get: { Double(speakerVol) }, set: { speakerVol = Int($0) }), in: 0...7)
              .frame(width: 260)
#endif
          }
          .onChange(of: speakerVol) { DOLConfigBridge.setSysconfSpeakerVolume($0) },
          L("Mirrors the real Wii's Wii Remote speaker volume slider."))
        settingsCaption(
          Toggle(L("Rumble"), isOn: $wiimoteRumble).onChange(of: wiimoteRumble) { DOLConfigBridge.setSysconfWiimoteMotor($0) },
          L("No physical effect on this device, but some games gate behavior on rumble being enabled."))
        settingsCaption(
          Toggle(L("Allow Touchpad IR Follow Without Click"), isOn: $touchpadIRFollowWithoutClick)
            .onChange(of: touchpadIRFollowWithoutClick) { UserDefaults.standard.set($0, forKey: "touchpad_ir_follow_without_click") },
          L("Moves the IR pointer as your finger hovers/drags without needing a tap. Helps aiming in some games."))
      }

      Section(header: Text(L("USB / SD")), footer: Text(L("Emulated Wii peripherals. None of these affect emulation speed."))) {
        settingsCaption(
          Toggle(L("Emulate Skylander Portal"), isOn: Binding(get: { DOLConfigBridge.mainEmulateSkylanderPortal() }, set: { DOLConfigBridge.setMainEmulateSkylanderPortal($0) })),
          L("Exposes a virtual Skylanders portal to games that support it."))
        settingsCaption(
          Toggle(L("Connect USB Keyboard"), isOn: $keyboard).onChange(of: keyboard) { DOLConfigBridge.setMainWiiKeyboard($0) },
          L("Presents a USB keyboard to games and the System Menu."))
        settingsCaption(
          Toggle(L("Enable WiiConnect24 via WiiLink"), isOn: $wiilink).onChange(of: wiilink) { DOLConfigBridge.setMainWiiWiiLinkEnable($0) },
          L("Enables fan-revived WiiConnect24 online channels through WiiLink."))
        settingsCaption(
          Toggle(L("Insert SD Card"), isOn: $sdCard).onChange(of: sdCard) { DOLConfigBridge.setMainWiiSDCard($0) },
          L("Exposes a virtual SD card to games and the System Menu."))
        settingsCaption(
          Toggle(L("Allow Writes to SD Card"), isOn: $sdWrites).onChange(of: sdWrites) { DOLConfigBridge.setMainAllowSDWrites($0) },
          L("Lets titles modify the virtual SD card. Off keeps it read-only."))
        settingsCaption(
          Toggle(L("Synchronize SD Card Folder on Start/Stop"), isOn: $sdFolderSync).onChange(of: sdFolderSync) { DOLConfigBridge.setMainWiiSDCardEnableFolderSync($0) },
          L("Mirrors a host folder to/from the card image when emulation starts and stops."))
      }
    }
    .navigationTitle(L("Wii"))
    .onAppear { syncWii() }
  }

  private func syncWii() {
    pal60 = DOLConfigBridge.sysconfPAL60()
    widescreen = DOLConfigBridge.sysconfWidescreen()
    screensaver = DOLConfigBridge.sysconfScreensaver()
    language = DOLConfigBridge.sysconfLanguage()
    soundMode = DOLConfigBridge.sysconfSoundMode()
    sensorBarPos = DOLConfigBridge.sysconfSensorBarPosition()
    sensorBarSens = DOLConfigBridge.sysconfSensorBarSensitivity()
    speakerVol = DOLConfigBridge.sysconfSpeakerVolume()
    wiimoteRumble = DOLConfigBridge.sysconfWiimoteMotor()
    touchpadIRFollowWithoutClick = UserDefaults.standard.bool(forKey: "touchpad_ir_follow_without_click")
    keyboard = DOLConfigBridge.mainWiiKeyboard()
    wiilink = DOLConfigBridge.mainWiiWiiLinkEnable()
    sdCard = DOLConfigBridge.mainWiiSDCard()
    sdWrites = DOLConfigBridge.mainAllowSDWrites()
    sdFolderSync = DOLConfigBridge.mainWiiSDCardEnableFolderSync()
  }

  private func posLabel(_ v: Int) -> String { v == 0 ? L("Bottom") : L("Top") }

  private func languageLabel(_ v: Int) -> String {
    switch v {
    case 0: return L("Japanese"); case 1: return L("English"); case 2: return L("German"); case 3: return L("French"); case 4: return L("Spanish"); case 5: return L("Italian"); case 6: return L("Dutch"); case 7: return L("Simplified Chinese"); case 8: return L("Traditional Chinese"); case 9: return L("Korean"); default: return L("Error")
    }
  }

  private func audioModeLabel(_ v: Int) -> String {
    switch v {
    case 0: return L("Mono"); case 1: return L("Stereo"); case 2: return L("Surround"); default: return L("Error")
    }
  }
}

private struct WiiLanguagePicker: View {
  @Binding var selected: Int
  private let options: [Int] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
  var body: some View {
    List {
      ForEach(options, id: \.self) { v in SelectRow(label: label(v), checked: v == selected) { selected = v; DOLConfigBridge.setSysconfLanguage(v) } }
    }
    .navigationTitle(L("System Language"))
  }
  private func label(_ v: Int) -> String {
    switch v {
    case 0: return L("Japanese"); case 1: return L("English"); case 2: return L("German"); case 3: return L("French"); case 4: return L("Spanish"); case 5: return L("Italian"); case 6: return L("Dutch"); case 7: return L("Simplified Chinese"); case 8: return L("Traditional Chinese"); case 9: return L("Korean"); default: return L("Error")
    }
  }
}

private struct WiiAudioModePicker: View {
  @Binding var selected: Int
  private let options: [Int] = [0, 1, 2]
  var body: some View {
    List {
      ForEach(options, id: \.self) { v in SelectRow(label: label(v), checked: v == selected) { selected = v; DOLConfigBridge.setSysconfSoundMode(v) } }
    }
    .navigationTitle(L("Audio Settings"))
  }
  private func label(_ v: Int) -> String { switch v { case 0: return L("Mono"); case 1: return L("Stereo"); case 2: return L("Surround"); default: return L("Error") } }
}

private struct WiiSensorBarPosPicker: View {
  @Binding var selected: Int
  var body: some View {
    List {
      SelectRow(label: L("Bottom"), checked: selected == 0) { selected = 0; DOLConfigBridge.setSysconfSensorBarPosition(0) }
      SelectRow(label: L("Top"), checked: selected == 1) { selected = 1; DOLConfigBridge.setSysconfSensorBarPosition(1) }
    }
    .navigationTitle(L("Sensor Bar Position"))
  }
}
/// Achievements config placeholder
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
    .onAppear { sync() }
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

// MARK: - Graphics General (wired)

struct GraphicsGeneralView: View {
  @State private var backend: GraphicsBackend = .metal
  @State private var aspect: AspectRatio = .auto
  @State private var vSync: Bool = false
  @State private var showAutoIrOSD: Bool = false
  @State private var tripleBuffering: Bool = false // NSUserDefaults-backed
  @State private var forceScaleOneNonProMotion: Bool = false // NSUserDefaults-backed
  @State private var asyncPresent: Bool = false
  @State private var autoIR: Bool = false
  @State private var targetFPS: TargetFPS = .fps60
  @State private var minScale: InternalScale = .x1_0
  @State private var maxScale: InternalScale = .x2_0
  @State private var frameCap: Int = 0
#if os(iOS)
  @State private var instantReplay: Bool = false
  @State private var clipSeconds: Int = 15
#endif

  // Shader compilation. Default Specialized(0) — matches the core default and the
  // iCube reset target (DOLConfigBridge.mm resetGameplayConfigKeys).
  @State private var shaderType: ShaderCompileType = .specialized
  @State private var compileBeforeStart: Bool = true

  var body: some View {
    List {
      Section {
        settingsNavCaption(
          destination: GraphicsBackendPickerView(selected: $backend),
          L("Renderer used to draw frames. Metal is the native, fastest path on this device; Vulkan runs via MoltenVK; OpenGL is the slow legacy fallback. Leave on Metal.")
        ) {
          Text("\(L("Backend")): \(backend.label)")
        }
        .onChange(of: backend) { _ in
          DOLConfigBridge.setGfxBackend(backend.backendKey)
          UserDefaults.standard.set(backend.backendKey, forKey: "ui_gfx_backend")
        }
        settingsNavCaption(
          destination: GraphicsAspectRatioView(selected: $aspect),
          L("Shape of the picture. Auto matches the game's native ratio; 4:3 and 16:9 force a fixed shape; Stretch fills the screen and may distort.")
        ) {
          Text("\(L("Aspect Ratio")): \(aspect.label)")
        }
        .onChange(of: aspect) { _ in DOLConfigBridge.setGfxAspectRatio(aspect.aspectRaw) }
        captionRow(
          Toggle(L("V-Sync"), isOn: $vSync)
            .onChange(of: vSync) { newValue in DOLConfigBridge.setGfxVSync(newValue) },
          L("Syncs presentation to the display refresh to remove tearing. On iOS the compositor already syncs, so this has little effect; leave ON."))
        captionRow(
          Toggle(L("Show Auto IR OSD"), isOn: $showAutoIrOSD)
            .onChange(of: showAutoIrOSD) { newValue in DOLConfigBridge.setGfxAutoIRShowOSD(newValue) },
          L("Shows the resolution Auto Internal Resolution picks each frame as an on-screen overlay. Diagnostic only."))
        captionRow(
          Toggle(L("Triple Buffering"), isOn: $tripleBuffering)
            .onChange(of: tripleBuffering) { newValue in UserDefaults.standard.set(newValue, forKey: "gfx_triple_buffering") },
          L("Adds a third frame buffer to smooth pacing at a small latency/memory cost. Default ON; turn off only if you want minimum latency."))
        captionRow(
          Toggle(L("Force scale 1.0 on non‑ProMotion"), isOn: $forceScaleOneNonProMotion)
            .onChange(of: forceScaleOneNonProMotion) { newValue in UserDefaults.standard.set(newValue, forKey: "gfx_force_scale_one_non_promo") },
          L("On non-ProMotion (non-120 Hz) devices, render at a 1.0 backing scale to save GPU/bandwidth. Helps on older devices; leave OFF on ProMotion displays."))
        captionRow(
          Toggle(L("Asynchronous Present"), isOn: $asyncPresent)
            .onChange(of: asyncPresent) { newValue in DOLConfigBridge.setGfxAsyncPresent(newValue) },
          L("Presents finished frames on a background thread so the CPU thread isn't blocked waiting on the display. Helps on the CPU-bound interpreter; default ON."))
        captionRow(
          Toggle(L("Enable Auto Internal Resolution"), isOn: $autoIR)
            .onChange(of: autoIR) { newValue in DOLConfigBridge.setGfxAutoIREnable(newValue) },
          L("Dynamically scales internal resolution between Min and Max to hold the Target FPS. Useful when scenes are GPU-bound; has no benefit when the CPU is the limit (the usual case on iCube)."))
        settingsNavCaption(
          destination: GraphicsTargetFPSView(selected: $targetFPS),
          L("Frame rate Auto Internal Resolution tries to hold by adjusting the render scale. Only used when Auto IR is on.")
        ) {
          Text("\(L("Target FPS")): \(targetFPS.label)")
        }
        .onChange(of: targetFPS) { _ in DOLConfigBridge.setGfxAutoIRTargetFPS(targetFPS.fpsValue) }
        settingsNavCaption(
          destination: GraphicsMinScaleView(selected: $minScale),
          L("Lowest internal resolution Auto IR will drop to when struggling. 1x is native GameCube/Wii resolution.")
        ) {
          Text("\(L("Min Scale")): \(minScale.label)")
        }
        .onChange(of: minScale) { _ in DOLConfigBridge.setGfxAutoIRMinScale(minScale.scaleValue) }
        settingsNavCaption(
          destination: GraphicsMaxScaleView(selected: $maxScale),
          L("Highest internal resolution Auto IR will raise to when there's headroom. Higher looks sharper but costs GPU.")
        ) {
          Text("\(L("Max Scale")): \(maxScale.label)")
        }
        .onChange(of: maxScale) { _ in DOLConfigBridge.setGfxAutoIRMaxScale(maxScale.scaleValue) }
#if os(iOS)
        captionRow(
          Picker(L("Frame Rate Cap"), selection: $frameCap) {
            Text(L("System Default")).tag(0)
            Text("30").tag(30)
            Text("60").tag(60)
            Text("90").tag(90)
            Text("120").tag(120)
          }
          .onChange(of: frameCap) { v in
            UserDefaults.standard.set(v, forKey: "ui_frame_cap")
            // Application is handled by the scene delegate where supported
          },
          L("Caps the display refresh the app requests. System Default lets the OS decide; lower caps can save power on the CPU-bound path."))
#endif
      }

#if os(iOS)
      Section(header: Text(L("Recording"))) {
        captionRow(
          Toggle(L("Enable ReplayKit Instant Replay"), isOn: $instantReplay)
            .onChange(of: instantReplay) { UserDefaults.standard.set($0, forKey: "replaykit_instant_replay_enabled") },
          L("Continuously buffers gameplay so you can save the last few seconds. May reduce performance; keep off on older devices."))
        captionRow(
          Toggle(L("Save Clips to Photos"), isOn: Binding(get: { UserDefaults.standard.bool(forKey: "replaykit_save_to_photos") }, set: { UserDefaults.standard.set($0, forKey: "replaykit_save_to_photos") })),
          L("Also copy saved replay clips into your Photos library."))
        captionRow(
          Toggle(L("Save Only to Photos"), isOn: Binding(get: { UserDefaults.standard.bool(forKey: "replaykit_save_only_photos") }, set: { UserDefaults.standard.set($0, forKey: "replaykit_save_only_photos") })),
          L("Save clips to Photos only, skipping the app's own storage."))
        captionRow(
          Picker(L("Clip Length"), selection: $clipSeconds) {
            Text("5s").tag(5)
            Text("10s").tag(10)
            Text("15s").tag(15)
            Text("30s").tag(30)
          }
          .onChange(of: clipSeconds) { v in UserDefaults.standard.set(v, forKey: "replaykit_clip_seconds") },
          L("How many seconds of gameplay each instant-replay clip captures."))
      }
#endif

      Section(header: Text(L("Shader Compilation"))) {
        settingsNavCaption(
          destination: GraphicsShaderTypeView(selected: $shaderType),
          L("Specialized (default) compiles each shader on first use — low GPU cost, may briefly stutter. Ubershader modes trade GPU power for fewer hitches. On the CPU-bound iCube path Specialized is recommended.")
        ) {
          Text("\(L("Type")): \(shaderType.label)")
        }
        .onChange(of: shaderType) { _ in DOLConfigBridge.setGfxShaderCompilationMode(shaderType.modeRaw) }
        captionRow(
          Toggle(L("Compile shaders before starting"), isOn: $compileBeforeStart)
            .onChange(of: compileBeforeStart) { newValue in DOLConfigBridge.setGfxWaitForShadersBeforeStarting(newValue) },
          L("Pre-builds the shader cache before the game starts: longer initial load, smoother first run. Recommended ON."))
      }
    }
    .navigationTitle(L("General"))
    .onAppear { syncFromConfig() }
    .onAppear { frameCap = UserDefaults.standard.integer(forKey: "ui_frame_cap") }
#if os(iOS)
    .onAppear {
      instantReplay = UserDefaults.standard.bool(forKey: "replaykit_instant_replay_enabled")
      let s = UserDefaults.standard.integer(forKey: "replaykit_clip_seconds"); clipSeconds = (s > 0 ? s : 15)
    }
#endif
  }

  /// Inline secondary-text description under a control. Forwards to the canonical
  /// file-scope `settingsCaption`.
  @ViewBuilder
  private func captionRow<Content: View>(_ content: Content, _ caption: String) -> some View {
    settingsCaption(content, caption)
  }

  private func syncFromConfig() {
    let keyFromConfig = DOLConfigBridge.gfxBackend()
    let keyFromDefaults = UserDefaults.standard.string(forKey: "ui_gfx_backend")
    let effectiveKey = (keyFromDefaults?.isEmpty == false) ? keyFromDefaults! : keyFromConfig
    backend = GraphicsBackend.from(key: effectiveKey)
    if effectiveKey != keyFromConfig { DOLConfigBridge.setGfxBackend(effectiveKey) }
    vSync = DOLConfigBridge.gfxVSync()
    aspect = AspectRatio.from(raw: DOLConfigBridge.gfxAspectRatio())
    asyncPresent = DOLConfigBridge.gfxAsyncPresent()
    autoIR = DOLConfigBridge.gfxAutoIREnable()
    showAutoIrOSD = DOLConfigBridge.gfxAutoIRShowOSD()
    targetFPS = TargetFPS.from(value: DOLConfigBridge.gfxAutoIRTargetFPS())
    minScale = InternalScale.from(value: DOLConfigBridge.gfxAutoIRMinScale())
    maxScale = InternalScale.from(value: DOLConfigBridge.gfxAutoIRMaxScale())
    shaderType = ShaderCompileType.from(raw: DOLConfigBridge.gfxShaderCompilationMode())
    compileBeforeStart = DOLConfigBridge.gfxWaitForShadersBeforeStarting()
    // NSUserDefaults-backed toggles
    if UserDefaults.standard.object(forKey: "gfx_triple_buffering") != nil { tripleBuffering = UserDefaults.standard.bool(forKey: "gfx_triple_buffering") } else { tripleBuffering = true }
    forceScaleOneNonProMotion = UserDefaults.standard.bool(forKey: "gfx_force_scale_one_non_promo")
  }
}

// MARK: - Graphics enums and pickers (tvOS-friendly)

enum GraphicsBackend: CaseIterable { case metal, opengl, vulkan
  var label: String { switch self { case .metal: return L("Metal"); case .opengl: return L("OpenGL"); case .vulkan: return L("Vulkan") } }
  var backendKey: String { switch self { case .metal: return "Metal"; case .opengl: return "OGL"; case .vulkan: return "Vulkan" } }
  static func from(key: String) -> GraphicsBackend { switch key.lowercased() { case "ogl", "opengl": return .opengl; case "vulkan": return .vulkan; default: return .metal } }
}

enum AspectRatio: CaseIterable { case auto, stretch, _4_3, _16_9
  var label: String { switch self { case .auto: return L("Auto"); case .stretch: return L("Stretch to Window"); case ._4_3: return "4:3"; case ._16_9: return "16:9" } }
  var aspectRaw: Int { switch self { case .auto: return 0; case .stretch: return 3; case ._4_3: return 2; case ._16_9: return 1 } }
  static func from(raw: Int) -> AspectRatio { switch raw { case 1: return ._16_9; case 2: return ._4_3; case 3: return .stretch; default: return .auto } }
}

enum TargetFPS: CaseIterable { case unlimited, fps30, fps60, fps120
  var label: String { switch self { case .unlimited: return L("Unlimited"); case .fps30: return "30"; case .fps60: return "60"; case .fps120: return "120" } }
  var fpsValue: Int { switch self { case .unlimited: return 0; case .fps30: return 30; case .fps60: return 60; case .fps120: return 120 } }
  static func from(value: Int) -> TargetFPS { switch value { case 30: return .fps30; case 120: return .fps120; case 0: return .unlimited; default: return .fps60 } }
}

// Auto Internal Resolution min/max bounds. The core stores these as an integer EFB
// multiplier and clamps to >= 1 (AutoIRController.cpp), so only whole scales are valid.
// The old fractional options (0.5x/0.75x/1.25x/1.5x) all collapsed to 0 -> read back
// as 1.0x, i.e. they "self-reset"; they are dropped.
enum InternalScale: Int, CaseIterable { case x1_0 = 1, x2_0 = 2, x3_0 = 3, x4_0 = 4
  var label: String { switch self {
  case .x1_0: return "1x"
  case .x2_0: return "2x"
  case .x3_0: return "3x"
  case .x4_0: return "4x"
  }}
  var scaleValue: Int { rawValue }
  static func from(value: Int) -> InternalScale { InternalScale(rawValue: value) ?? .x1_0 }
}

// Mirrors Dolphin's ShaderCompilationMode (VideoConfig.h): Synchronous(0) is the
// "Specialized" mode in Dolphin's own UI; raw values must match the core 1:1 or the
// picker reads back a different option than it stored ("self-reset").
enum ShaderCompileType: CaseIterable { case specialized, exclusiveUber, hybridUber, skipDrawing
  var label: String { switch self {
  case .specialized: return L("Specialized")
  case .exclusiveUber: return L("Exclusive Ubershaders")
  case .hybridUber: return L("Hybrid Ubershaders")
  case .skipDrawing: return L("Skip Drawing")
  } }
  var modeRaw: Int { switch self { case .specialized: return 0; case .exclusiveUber: return 1; case .hybridUber: return 2; case .skipDrawing: return 3 } }
  static func from(raw: Int) -> ShaderCompileType { switch raw { case 1: return .exclusiveUber; case 2: return .hybridUber; case 3: return .skipDrawing; default: return .specialized } }
}

struct GraphicsBackendPickerView: View {
  @Binding var selected: GraphicsBackend
  var body: some View {
    List {
      ForEach(Array(GraphicsBackend.allCases.enumerated()), id: \.offset) { _, value in
        SelectRow(label: value.label, checked: value == selected) { selected = value; DOLConfigBridge.setGfxBackend(value.backendKey) }
      }
    }
    .navigationTitle(L("Backend"))
  }
}

struct GraphicsAspectRatioView: View {
  @Binding var selected: AspectRatio
  var body: some View {
    List {
      ForEach(Array(AspectRatio.allCases.enumerated()), id: \.offset) { _, value in
        SelectRow(label: value.label, checked: value == selected) { selected = value; DOLConfigBridge.setGfxAspectRatio(value.aspectRaw) }
      }
    }
    .navigationTitle(L("Aspect Ratio"))
  }
}

struct GraphicsTargetFPSView: View {
  @Binding var selected: TargetFPS
  var body: some View {
    List {
      ForEach(Array(TargetFPS.allCases.enumerated()), id: \.offset) { _, value in
        SelectRow(label: value.label, checked: value == selected) { selected = value; DOLConfigBridge.setGfxAutoIRTargetFPS(value.fpsValue) }
      }
    }
    .navigationTitle(L("Target FPS"))
    .toolbar { HelpButton(helpKey:
                            "Controls how fast emulation runs relative to the original hardware.<br><br>Values higher than 100% will emulate faster than the original hardware can run, if your hardware is able to keep up. Values lower than 100% will slow emulation instead. Unlimited will emulate as fast as your hardware is able to.<br><br><dolphin_emphasis>If unsure, select 100%.</dolphin_emphasis>") }
  }
}

struct GraphicsMinScaleView: View {
  @Binding var selected: InternalScale
  var body: some View {
    List {
      ForEach(Array(InternalScale.allCases.enumerated()), id: \.offset) { _, value in
        SelectRow(label: value.label, checked: value == selected) { selected = value; DOLConfigBridge.setGfxAutoIRMinScale(value.scaleValue) }
      }
    }
    .navigationTitle(L("Min Scale"))
  }
}

struct GraphicsMaxScaleView: View {
  @Binding var selected: InternalScale
  var body: some View {
    List {
      ForEach(Array(InternalScale.allCases.enumerated()), id: \.offset) { _, value in
        SelectRow(label: value.label, checked: value == selected) { selected = value; DOLConfigBridge.setGfxAutoIRMaxScale(value.scaleValue) }
      }
    }
    .navigationTitle(L("Max Scale"))
  }
}

struct GraphicsShaderTypeView: View {
  @Binding var selected: ShaderCompileType
  var body: some View {
    List {
      ForEach(Array(ShaderCompileType.allCases.enumerated()), id: \.offset) { _, value in
        SelectRow(label: value.label, checked: value == selected) { selected = value; DOLConfigBridge.setGfxShaderCompilationMode(value.modeRaw) }
      }
    }
    .navigationTitle(L("Shader Type"))
  }
}

// MARK: - Graphics placeholders

/// Graphics > General placeholder (replaced above)
/// Graphics > Enhancements placeholder
struct GraphicsEnhancementsView: View {
  @State private var anisotropy: Int = 1
  @State private var trueColor: Bool = true
  @State private var disableCopyFilter: Bool = true
  @State private var efbScale: Int = 1
  @State private var efbMaxScale: Int = 6
  @State private var widescreenHack: Bool = false
  @State private var disableFog: Bool = false
  @State private var arbitraryMipmapDetection: Bool = false
  @State private var arbitraryMipmapThreshold: Double = 0.5
  @State private var hdrOutput: Bool = false
  @State private var gpuTextureDecoding: Bool = false
  @State private var helpMessage: String = ""
  @State private var showHelp: Bool = false
  var body: some View {
    List {
      Section(content: {
        settingsNavCaption(
          destination: EfbScalePicker(selected: $efbScale, maxScale: efbMaxScale),
          L("Renders the game above native resolution for a sharper image. Higher costs more GPU; on the CPU-bound path 1x–2x is usually plenty.")
        ) {
          Text("\(L("Internal Resolution")): \(efbScale == 0 ? L("Auto (fit window)") : "\(efbScale)x")")
        }
        .onChange(of: efbScale) { newScale in
          DOLConfigBridge.setGfxEfbScale(newScale)
          // Picking an explicit (non-fit-window) scale means the user wants that exact IR. The Auto-IR
          // controller also drives GFX_EFB_SCALE, so leave it on and the two fight. Turn Auto-IR off so
          // the manual choice sticks. (The Auto-IR toggle lives on the Graphics > General screen and
          // re-reads its state from the bridge when it next appears.)
          if newScale != 0 {
            DOLConfigBridge.setGfxAutoIREnable(false)
          }
        }
      }, header: { Text(L("Internal Resolution")) })
      Section(content: {
        settingsNavCaption(
          destination: AnisotropyPicker(selected: $anisotropy),
          L("Sharpens textures viewed at steep angles (floors, walls). Cheap on modern GPUs; 4x–16x is a safe quality win.")
        ) {
          Text("\(L("Anisotropic Filtering")): \(anisotropy)x")
        }
        .onChange(of: anisotropy) { DOLConfigBridge.setGfxEnhanceAnisotropySamples($0) }
      }, header: { Text(L("Texture Filtering")) })
      Section(content: {
        settingsCaption(
          Toggle(L("Force 24-bit Color"), isOn: $trueColor)
            .onChange(of: trueColor) { DOLConfigBridge.setGfxEnhanceForceTrueColor($0) },
          L("Forces full 24-bit color instead of the GameCube/Wii's banded 16/18-bit output. Reduces gradient banding at negligible cost. Recommended ON."))
        settingsCaption(
          Toggle(L("Disable Copy Filter"), isOn: $disableCopyFilter)
            .onChange(of: disableCopyFilter) { DOLConfigBridge.setGfxEnhanceDisableCopyFilter($0) },
          L("Disables the deflicker/blur the console applied to copies. Gives a sharper image; may slightly change how a few games look."))
        settingsCaption(
          Toggle(L("Widescreen Hack"), isOn: $widescreenHack)
            .onChange(of: widescreenHack) { DOLConfigBridge.setGfxWidescreenHack($0) },
          L("Forces 16:9 in games that only render 4:3. Can stretch HUDs or break some games; leave off for natively-widescreen titles."))
        settingsCaption(
          Toggle(L("HDR Output"), isOn: $hdrOutput)
            .onChange(of: hdrOutput) { DOLConfigBridge.setGfxEnhanceHDROutput($0) },
          L("Outputs in HDR on capable displays. Most games are SDR, so the effect is subtle; harmless to leave off."))
        settingsCaption(
          Toggle(L("GPU Texture Decoding"), isOn: $gpuTextureDecoding)
            .onChange(of: gpuTextureDecoding) { DOLConfigBridge.setGfxEnableGPUTextureDecoding($0) },
          L("Decodes textures on the GPU instead of the CPU. Moves work off the bottleneck thread, so it can help CPU-bound titles that stream many textures. iCube already ships a NEON CPU decoder (Config ▸ Advanced) as the default fast path."))
      }, header: { Text(L("Enhancements")) })
      Section(content: {
        settingsCaption(
          Toggle(L("Disable Fog"), isOn: $disableFog)
            .onChange(of: disableFog) { DOLConfigBridge.setGfxDisableFog($0) },
          L("Removes distance fog. Can improve visibility but breaks the intended look and a few effects. Leave off normally."))
        settingsCaption(
          Toggle(L("Arbitrary Mipmap Detection"), isOn: $arbitraryMipmapDetection)
            .onChange(of: arbitraryMipmapDetection) { DOLConfigBridge.setGfxEnhanceArbitraryMipmapDetection($0) },
          L("Detects games that abuse mipmaps for special effects and renders them correctly. Leave on unless a game looks wrong."))
        if arbitraryMipmapDetection {
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text(L("Mipmap Detection Threshold"))
              Spacer()
              Text(String(format: "%.2f", arbitraryMipmapThreshold))
            }
            // Threshold is the average per-pixel/per-channel percent diff between an expected
            // blurred mipmap and the received one (default 14.0; ~4.5 is just below clearly-arbitrary).
            // Old 0...1 range couldn't represent the 14 default at all. Span the meaningful 0...30 scale.
#if os(tvOS)
            TVIntStepper(
              value: Binding(
                get: { Int(arbitraryMipmapThreshold * 10) },
                set: { arbitraryMipmapThreshold = Double($0) / 10.0 }
              ),
              range: 0...300,
              step: 1
            )
            .onChange(of: arbitraryMipmapThreshold) { DOLConfigBridge.setGfxEnhanceArbitraryMipmapDetectionThreshold(Float($0)) }
#else
            Slider(value: $arbitraryMipmapThreshold, in: 0.0...30.0, step: 0.1)
              .onChange(of: arbitraryMipmapThreshold) { DOLConfigBridge.setGfxEnhanceArbitraryMipmapDetectionThreshold(Float($0)) }
#endif
            Text(L("Sensitivity of arbitrary-mipmap detection. Leave at the default unless a game's textures look wrong."))
              .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          }
        }
      }, header: { Text(L("Compatibility")) })
    }
    .navigationTitle(L("Enhancements"))
    .onAppear { sync() }
    .sheet(isPresented: $showHelp) {
      NavigationView {
        ScrollView { Text(helpMessage).padding() }
          .navigationTitle(L("Help"))
          .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button(L("Done")) { showHelp = false } } }
      }
    }
  }
  private func sync() {
    efbMaxScale = max(1, DOLConfigBridge.gfxEfbMaxScale())
    efbScale = DOLConfigBridge.gfxEfbScale()
    anisotropy = DOLConfigBridge.gfxEnhanceAnisotropySamples()
    trueColor = DOLConfigBridge.gfxEnhanceForceTrueColor()
    disableCopyFilter = DOLConfigBridge.gfxEnhanceDisableCopyFilter()
    widescreenHack = DOLConfigBridge.gfxWidescreenHack()
    disableFog = DOLConfigBridge.gfxDisableFog()
    gpuTextureDecoding = DOLConfigBridge.gfxEnableGPUTextureDecoding()
    arbitraryMipmapDetection = DOLConfigBridge.gfxEnhanceArbitraryMipmapDetection()
    arbitraryMipmapThreshold = Double(DOLConfigBridge.gfxEnhanceArbitraryMipmapDetectionThreshold())
    hdrOutput = DOLConfigBridge.gfxEnhanceHDROutput()
  }
  private func labelWithInfo(_ title: String, action: @escaping () -> Void) -> some View {
    HStack {
      Text(title)
      Spacer()
      Button(action: action) { Image(systemName: "info.circle") }
        .buttonStyle(.plain)
    }
  }

  // MARK: - Help Text (UIKit parity)
  private func helpTextInternalResolution() -> String {
    L("Controls the rendering resolution.\n\nA high resolution greatly improves visual quality, but also greatly increases GPU load and can cause issues in certain games. Generally speaking, the lower the internal resolution, the better performance will be.\n\niOS note: this is a GPU cost. iCube is usually CPU-bound (the jitless interpreter), so raising resolution often costs little until the GPU becomes the limit; lower it first if a GPU-heavy scene drops frames.\n\nIf unsure, select Native (1x).")
  }
  private func helpTextAnisotropy() -> String {
    L("Adjusts texture filtering. Anisotropic filtering sharpens textures viewed at oblique angles.\n\nAny option above 1x slightly increases GPU load and can alter the look of textures in a few games.\n\niOS note: GPU-side cost only; rarely matters on the CPU-bound interpreter. Safe to raise unless a specific GPU-heavy scene struggles.\n\nIf unsure, select 1x.")
  }
  private func helpTextDisableFog() -> String {
    L("Removes distance fog, making far objects more visible.\n\nDisabling fog breaks games that rely on proper fog emulation (pop-in, wrong visibility).\n\niOS note: tiny GPU saving; almost never helps on iCube because the CPU interpreter is the limit, and it can cause visual glitches. Leave OFF unless you are clearly GPU-bound.\n\nIf unsure, leave this unchecked.")
  }
  private func helpTextDisableCopyFilter() -> String {
    L("Disables the blending of adjacent rows when copying the EFB (some games call this \"deflickering\" or \"smoothing\").\n\nResults in a sharper image with no performance cost; causes few issues.\n\niOS note: image-quality choice only; no effect on the CPU-bound framerate.\n\nIf unsure, leave this checked.")
  }
  private func helpTextWidescreenHack() -> String {
    L("Forces 4:3 games to render at a wider aspect ratio. Use with Aspect Ratio set to 16:9.\n\nOften partially breaks graphics and UIs, and is unnecessary (and harmful) if you use an AR/Gecko widescreen patch instead.\n\niOS note: display/aspect choice only; no framerate impact.\n\nIf unsure, leave this unchecked.")
  }
  private func helpTextForceTrueColor() -> String {
    L("Renders color in 24-bit to reduce banding.\n\nNo performance impact and few graphical issues.\n\niOS note: pure quality win; safe to leave on regardless of the CPU bottleneck.\n\nIf unsure, leave this checked.")
  }
  private func helpTextArbitraryMipmap() -> String {
    L("Detects arbitrary mipmaps that some games use for distance-based effects.\n\nCan cause blurry textures from false positives, and is incompatible with GPU Texture Decoding. Disabling can reduce stutter in games that stream many textures.\n\niOS note: mostly an accuracy/quality tradeoff; little framerate effect on the CPU-bound path.\n\nIf unsure, leave this checked.")
  }
  private func helpTextHDROutput() -> String {
    L("Enables HDR output on supported displays for wider dynamic range and color.\n\niOS note: display feature; negligible performance cost. Only useful on HDR-capable screens.")
  }
}

private struct AnisotropyPicker: View {
  @Binding var selected: Int
  private var options: [Int] { [1, 2, 4, 8, 16] }
  var body: some View {
    List {
      ForEach(options, id: \.self) { v in
        SelectRow(label: "\(v)x", checked: v == selected) { selected = v; DOLConfigBridge.setGfxEnhanceAnisotropySamples(v) }
      }
    }
    .navigationTitle(L("Anisotropic Filtering"))
  }
}

private struct EfbScalePicker: View {
  @Binding var selected: Int
  let maxScale: Int
  private var options: [Int] { [0] + Array(1...max(1, maxScale)) }
  var body: some View {
    List {
      ForEach(options, id: \.self) { v in
        if v == 0 {
          SelectRow(label: L("Auto"), checked: selected == 0) { selected = 0; DOLConfigBridge.setGfxEfbScale(0) }
        } else if v == 1 {
          SelectRow(label: "1x (\(L("Native")))", checked: selected == 1) { selected = 1; DOLConfigBridge.setGfxEfbScale(1) }
        } else {
          SelectRow(label: "\(v)x", checked: selected == v) { selected = v; DOLConfigBridge.setGfxEfbScale(v) }
        }
      }
    }
    .navigationTitle(L("Internal Resolution"))
  }
}

/// Graphics > Hacks placeholder
struct GraphicsHacksView: View {
  @State private var efbAccess: Bool = false
  @State private var skipEfbToRam: Bool = false
  @State private var skipXfbToRam: Bool = false
  @State private var immediateXfb: Bool = false
  @State private var copyEfbScaled: Bool = true
  @State private var efbFormatChanges: Bool = true
  @State private var vertexRounding: Bool = false
  @State private var forceProgressive: Bool = false
  @State private var deferEfbCopies: Bool = false
  @State private var viSkipMode: Int = 0 // TriState
  @State private var fastTextureSampling: Bool = true
  @State private var fastMath: Bool = false
  @State private var useComputeEfbXfb: Bool = false
  @State private var useComputeVertexDecode: Bool = false
  @State private var noMipmapping: Bool = false
  @State private var earlyXfbOutput: Bool = true
  @State private var skipDuplicateXFBs: Bool = true
  @State private var viDecimateInterlace: Bool = false
  @State private var helpMessage: String = ""
  @State private var showHelp: Bool = false
  var body: some View {
    List {
      Section(header: Text(L("General Hacks"))) {
        settingsCaption(
          Toggle(L("Enable EFB Access"), isOn: $efbAccess)
            .onChange(of: efbAccess) { DOLConfigBridge.setGfxHackEfbAccessEnable($0) },
          L("Lets the CPU read back the framebuffer. Required by some effects but costly; many games run fine and faster with it off."))
        settingsCaption(
          Toggle(L("Skip EFB Copy to RAM"), isOn: $skipEfbToRam)
            .onChange(of: skipEfbToRam) { DOLConfigBridge.setGfxHackSkipEfbCopyToRam($0) },
          L("Keeps embedded-framebuffer copies on the GPU instead of system RAM. Faster; breaks a few effects. Recommended on."))
        settingsCaption(
          Toggle(L("Skip XFB Copy to RAM"), isOn: $skipXfbToRam)
            .onChange(of: skipXfbToRam) { DOLConfigBridge.setGfxHackSkipXfbCopyToRam($0) },
          L("Keeps the external framebuffer on the GPU. Faster; can break games that read the final image."))
        settingsCaption(
          Toggle(L("Immediate XFB"), isOn: $immediateXfb)
            .onChange(of: immediateXfb) { DOLConfigBridge.setGfxHackImmediateXfb($0) },
          L("Presents frames the moment they're drawn — lower latency, but can cause flicker or tearing in some games."))
        settingsCaption(
          Toggle(L("Copy EFB Scaled"), isOn: $copyEfbScaled)
            .onChange(of: copyEfbScaled) { DOLConfigBridge.setGfxHackCopyEfbScaled($0) },
          L("Copies the framebuffer at the higher internal resolution rather than native. Keeps upscaled detail; recommended on."))
        settingsCaption(
          Toggle(L("Early XFB Output"), isOn: $earlyXfbOutput)
            .onChange(of: earlyXfbOutput) { DOLConfigBridge.setGfxHackEarlyXfbOutput($0) },
          L("Outputs the frame earlier in the pipeline for lower latency. Recommended on; turn off if a game shows glitches."))
        settingsCaption(
          Toggle(L("Skip Duplicate XFBs"), isOn: $skipDuplicateXFBs)
            .onChange(of: skipDuplicateXFBs) { DOLConfigBridge.setGfxHackSkipDuplicateXFBs($0) },
          L("Avoids re-presenting identical frames, saving GPU work. Recommended on."))
        settingsCaption(
          Toggle(L("Emulate EFB Format Changes"), isOn: $efbFormatChanges)
            .onChange(of: efbFormatChanges) { DOLConfigBridge.setGfxHackEfbEmulateFormatChanges($0) },
          L("Emulates pixel-format changes some games rely on. Needed for correct colors/effects in those games; small cost."))
        settingsCaption(
          Toggle(L("Vertex Rounding"), isOn: $vertexRounding)
            .onChange(of: vertexRounding) { DOLConfigBridge.setGfxHackVertexRounding($0) },
          L("Rounds vertex positions to reduce seams between tiles at higher resolutions. Only helps above 1x; leave off at 1x."))
        settingsCaption(
          Toggle(L("Force Progressive Scan"), isOn: $forceProgressive)
            .onChange(of: forceProgressive) { DOLConfigBridge.setGfxHackForceProgressive($0) },
          L("Forces 480p output where games allow it, for a cleaner image."))
        settingsCaption(
          Toggle(L("Defer EFB Copies"), isOn: $deferEfbCopies)
            .onChange(of: deferEfbCopies) { DOLConfigBridge.setGfxHackDeferEfbCopies($0) },
          L("Batches framebuffer copies to reduce overhead. Faster in most games; recommended on."))
        settingsNavCaption(
          destination: ViSkipModePicker(selected: $viSkipMode),
          L("Skips video-interrupt frames to gain speed. Auto is the safe choice; On is more aggressive but can cause flicker.")
        ) {
          Text("\(L("VI Skip Mode")): \(viSkipLabel(viSkipMode))")
        }
        .onChange(of: viSkipMode) { DOLConfigBridge.setGfxHackViSkipMode($0) }
        settingsCaption(
          Toggle(L("Fast Texture Sampling"), isOn: $fastTextureSampling)
            .onChange(of: fastTextureSampling) { DOLConfigBridge.setGfxHackFastTextureSampling($0) },
          L("Uses faster, less precise texture sampling. Small speed win; rarely causes minor texture artifacts. Recommended on."))
        settingsCaption(
          Toggle(L("Fast Math (Metal Shaders)"), isOn: $fastMath)
            .onChange(of: fastMath) { DOLConfigBridge.setGfxHackFastMath($0) },
          L("Lets Metal shaders use fast, relaxed-precision math. Can speed up the GPU; may cause subtle rendering differences."))
        // iCube native-Metal moat: routes EFB/XFB color/depth resolve, blit, scale and
        // gamma through Metal compute kernels instead of the stock raster path. Wired into
        // the Metal backend (TryCompute* overrides) and gated on GFX_USE_COMPUTE_EFBXFB.
        settingsCaption(
          Toggle(L("Use Compute for EFB/XFB"), isOn: $useComputeEfbXfb)
            .onChange(of: useComputeEfbXfb) { DOLConfigBridge.setGfxUseComputeEfbXfb($0) },
          L("Native-Metal compute acceleration for EFB/XFB. Experimental GPU perf knob; OFF by default. Applies on next launch."))
        settingsCaption(
          Toggle(L("Use Compute for Vertex Decode"), isOn: $useComputeVertexDecode)
            .onChange(of: useComputeVertexDecode) { DOLConfigBridge.setGfxUseComputeVertexDecode($0) },
          L("Offload vertex decoding to a Metal compute shader (CPU→GPU). Experimental — currently only position-only-float formats use the GPU path (others fall back to CPU), so most games see little change yet. OFF by default. Applies on next launch."))
        settingsCaption(
          Toggle(L("No Mipmapping (iOS)"), isOn: $noMipmapping)
            .onChange(of: noMipmapping) { DOLConfigBridge.setGfxHackNoMipmapping($0) },
          L("Disables mipmaps. Saves a little memory/bandwidth but makes distant textures shimmer. Leave off normally."))
      }
      Section {
        settingsCaption(
          Toggle(L("Interlaced Field Decimation"), isOn: $viDecimateInterlace)
            .onChange(of: viDecimateInterlace) { DOLConfigBridge.setGfxHackViDecimateInterlace($0) },
          L("Skips every other interlaced field for higher FPS. May reduce temporal resolution or cause flicker in some games."))
      }
    }
    .navigationTitle(L("Hacks"))
    .onAppear { sync() }
    .sheet(isPresented: $showHelp) {
      NavigationView {
        ScrollView { Text(helpMessage).padding() }
          .navigationTitle(L("Help"))
          .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button(L("Done")) { showHelp = false } } }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DOLEmulationDidStartNotification"))) { _ in sync() }
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DOLEmulationDidEndNotification"))) { _ in sync() }
#if os(iOS)
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in sync() }
#endif
  }
  private func sync() {
    efbAccess = DOLConfigBridge.gfxHackEfbAccessEnable()
    skipEfbToRam = DOLConfigBridge.gfxHackSkipEfbCopyToRam()
    skipXfbToRam = DOLConfigBridge.gfxHackSkipXfbCopyToRam()
    immediateXfb = DOLConfigBridge.gfxHackImmediateXfb()
    copyEfbScaled = DOLConfigBridge.gfxHackCopyEfbScaled()
    efbFormatChanges = DOLConfigBridge.gfxHackEfbEmulateFormatChanges()
    vertexRounding = DOLConfigBridge.gfxHackVertexRounding()
    forceProgressive = DOLConfigBridge.gfxHackForceProgressive()
    deferEfbCopies = DOLConfigBridge.gfxHackDeferEfbCopies()
    viSkipMode = DOLConfigBridge.gfxHackViSkipMode()
    fastTextureSampling = DOLConfigBridge.gfxHackFastTextureSampling()
    fastMath = DOLConfigBridge.gfxHackFastMath()
    useComputeEfbXfb = DOLConfigBridge.gfxUseComputeEfbXfb()
    useComputeVertexDecode = DOLConfigBridge.gfxUseComputeVertexDecode()
    noMipmapping = DOLConfigBridge.gfxHackNoMipmapping()
    viDecimateInterlace = DOLConfigBridge.gfxHackViDecimateInterlace()
  }
  private func viSkipLabel(_ v: Int) -> String { switch v { case 1: return L("On"); case 2: return L("Auto"); default: return L("Off") } }
  // MARK: - Help UI & Text
  private func labelWithInfo(_ title: String, action: @escaping () -> Void) -> some View {
    HStack {
      Text(title)
      Spacer()
      Button(action: action) { Image(systemName: "info.circle") }
        .buttonStyle(.plain)
    }
  }

  private func helpTextEfbAccess() -> String {
    L("Allows the emulated CPU to read the Embedded Framebuffer (EFB).\n\nTurning it off can help performance but breaks effects that read the EFB (heat haze, soft particles, lens flares, some UI).\n\niOS note: when a game does use EFB reads, those reads run on the CPU thread — the bottleneck — so this can matter here; but disabling it breaks visuals. Leave ON unless a game both needs the speed and tolerates the breakage.\n\nIf unsure, leave this enabled.")
  }
  private func helpTextSkipEfbToRam() -> String {
    L("Skips copying EFB contents to emulated RAM.\n\nImproves performance but breaks features that rely on CPU reads of the EFB (post-processing, reflections, heat haze, some UI).\n\niOS note: the skipped copy/readback is CPU-side, so this can recover real time on the bottlenecked interpreter — at the cost of broken effects in affected games.\n\nIf unsure, leave this unchecked.")
  }
  private func helpTextSkipXfbToRam() -> String {
    L("Skips copying the XFB (external framebuffer) to RAM.\n\nCan increase performance but breaks software XFB paths; may cause missing frames, flicker, or broken FMVs.\n\niOS note: CPU-side saving that can help the bottleneck, but the breakage is common — keep off unless a specific title benefits.\n\nIf unsure, leave this unchecked.")
  }
  private func helpTextImmediateXfb() -> String {
    L("Renders directly from the EFB without an emulated XFB buffer.\n\nReduces latency and may raise FPS, but can cause flicker, bad deinterlacing, or timing issues.\n\niOS note: trims some CPU/sync work but is risky on VI-sensitive games. Leave off unless you specifically want lower latency.\n\nIf unsure, leave this unchecked.")
  }
  private func helpTextCopyEfbScaled() -> String {
    L("Scales EFB copies to the current internal resolution.\n\nSharpens post-processing at higher resolutions, but some games assume 1x EFB and show overblown bloom/halos or broken depth effects.\n\niOS note: GPU-side quality choice; little framerate effect on the CPU-bound path. Disable only to fix such glitches.\n\nIf unsure, leave this enabled.")
  }
  private func helpTextEarlyXfbOutput() -> String {
    L("Outputs the XFB earlier in the pipeline.\n\nReduces display latency, but may cause jitter or timing issues in VI-sensitive titles.\n\niOS note: latency/pacing tweak; negligible framerate effect. Default ON.\n\nIf unsure, leave this enabled.")
  }
  private func helpTextSkipDuplicateXFBs() -> String {
    L("Skips presenting duplicate XFB fields/frames.\n\nSaves work and bandwidth when games output identical fields; rarely affects pacing or A/V sync.\n\niOS note: small saving on both CPU and GPU; safe. Default ON.\n\nIf unsure, leave this enabled.")
  }
  private func helpTextEmulateEfbFormatChanges() -> String {
    L("Accurately emulates EFB format/precision changes.\n\nFixes color and post-process issues in many games. Disabling can help speed but may cause wrong colors or missing effects.\n\niOS note: accuracy vs a modest CPU/GPU saving; the breakage usually isn't worth it. Default ON.\n\nIf unsure, leave this enabled.")
  }
  private func helpTextVertexRounding() -> String {
    L("Rounds vertex positions to reduce subpixel jitter.\n\nStabilizes 2D elements and reduces shimmering; can slightly distort 3D geometry.\n\niOS note: minor cost; quality choice rather than a performance one.\n\nIf unsure, leave this enabled.")
  }
  private func helpTextForceProgressive() -> String {
    L("Forces progressive scan instead of interlaced fields.\n\nReduces flicker and may cut latency, but some games expect interlacing.\n\niOS note: presentation choice; no meaningful framerate impact.\n\nIf unsure, leave this unchecked.")
  }
  private func helpTextDeferEfbCopies() -> String {
    L("Queues and defers EFB copies to reduce pipeline stalls.\n\nCan increase performance but reorders copies and may break effects that need immediate results (heat haze, mirrors).\n\niOS note: can reduce CPU-thread stalls on the bottleneck — a real potential win — but verify visuals per game.\n\nIf unsure, leave this unchecked.")
  }
  private func helpTextViSkipMode() -> String {
    L("Skips VI (Video Interface) updates to raise FPS.\n\nOn: always skip (highest FPS, visible artifacts/flicker). Auto: skip when likely safe. Off: most accurate.\n\niOS note: this directly cuts per-frame CPU work, so it can help on the bottlenecked interpreter — at the cost of temporal artifacts. Try Auto if you need frames.\n\nIf unsure, select Auto or Off.")
  }
  private func helpTextFastTextureSampling() -> String {
    L("Uses a faster, less accurate texture-sampling path.\n\nCan help on some GPUs but may cause banding, seams, or vertical lines in FMVs.\n\niOS note: GPU-side; rarely changes the CPU-bound framerate. Disable if you see texture artifacts. Default ON.\n\nIf unsure, leave this enabled.")
  }
  private func helpTextFastMath() -> String {
    L("Enables fast-math optimizations in iCube's Metal shaders.\n\nRelaxes IEEE precision for speed; can cause subtle lighting differences or rare shader bugs.\n\niOS note: GPU-side optimization; helps only when GPU-bound and won't move the CPU bottleneck. Default OFF.\n\nIf unsure, leave this unchecked.")
  }
  private func helpTextUseComputeEfbXfb() -> String {
    L("Native-Metal compute acceleration for EFB/XFB.\n\nRoutes EFB color/depth resolve, RGBA8 blit/scale/gamma, and mipmap generation through Metal compute kernels instead of the stock raster path. This is an experimental GPU performance knob and is OFF by default.\n\nFalls back to the stock path automatically for any case it doesn't handle, so it is safe to leave on, but on untested hardware it can produce visual glitches (shimmer, wrong depth) — benchmark and visually verify GPU-bound titles before relying on it.\n\nApplies on next launch.")
  }
  private func helpTextNoMipmapping() -> String {
    L("Disables texture mipmapping.\n\nA workaround for rare driver bugs; normally increases shimmering/aliasing and can hurt performance via texture-cache inefficiency.\n\niOS note: GPU-side; leave OFF — it usually makes things both uglier and slightly slower.\n\nIf unsure, leave this unchecked.")
  }
}

private struct ViSkipModePicker: View {
  @Binding var selected: Int
  var body: some View {
    List {
      SelectRow(label: L("Off"), checked: selected == 0) { selected = 0; DOLConfigBridge.setGfxHackViSkipMode(0) }
      SelectRow(label: L("On"), checked: selected == 1) { selected = 1; DOLConfigBridge.setGfxHackViSkipMode(1) }
      SelectRow(label: L("Auto"), checked: selected == 2) { selected = 2; DOLConfigBridge.setGfxHackViSkipMode(2) }
    }
    .navigationTitle(L("VI Skip Mode"))
  }
}
/// Graphics > Advanced placeholder
struct GraphicsAdvancedView: View {
  @State private var fastDepth: Bool = true
  @State private var pixelLighting: Bool = false
  @State private var backendMT: Bool = true
  @State private var shaderCache: Bool = true
  @State private var saveTexCache: Bool = false
  @State private var preferVSForLines: Bool = false
  @State private var cpuCull: Bool = false
  // Performance Statistics
  @State private var showFPS: Bool = false
  @State private var showVPS: Bool = false
  @State private var showSpeed: Bool = false
  @State private var showFrameTimes: Bool = false
  @State private var showVBlankTimes: Bool = false
  @State private var showGraphs: Bool = false
  @State private var logRenderTime: Bool = false
  @State private var speedColors: Bool = false
  // Debugging
  @State private var overlayStats: Bool = false
  @State private var validationLayer: Bool = false
  // Utility (Custom Textures / Mods / VRAM copy)
  @State private var hiresTextures: Bool = false
  @State private var prefetchTextures: Bool = false
  @State private var disableEfbToVRAM: Bool = false
  @State private var graphicsMods: Bool = false
  // Misc
  @State private var cropPicture: Bool = false
  @State private var progressiveScan: Bool = false
  // Shader Threads
  @State private var compilerThreads: Int = 1
  @State private var precompilerThreads: Int = 1
  @State private var maxThreads: Int = 2
  // Experimental
  @State private var deferEfbInvalidation: Bool = false
  @State private var manualTexSampling: Bool = false
  var body: some View {
    List {
      Section(header: Text(L("Performance Statistics")), footer: Text(L("These overlays can also be toggled in-game from the pause menu."))) {
        settingsCaption(
          Toggle(L("Show FPS"), isOn: $showFPS).onChange(of: showFPS) { _ in DOLConfigBridge.setGfxShowFPS(showFPS) },
          L("Frames per second actually presented to the display."))
        settingsCaption(
          Toggle(L("Show VPS"), isOn: $showVPS).onChange(of: showVPS) { _ in DOLConfigBridge.setGfxShowVPS(showVPS) },
          L("Emulated video interrupts per second — the game's internal frame rate."))
        settingsCaption(
          Toggle(L("Show Speed"), isOn: $showSpeed).onChange(of: showSpeed) { _ in DOLConfigBridge.setGfxShowSpeed(showSpeed) },
          L("Emulation speed as a percentage of full speed."))
        settingsCaption(
          Toggle(L("Show Frame Times"), isOn: $showFrameTimes).onChange(of: showFrameTimes) { _ in DOLConfigBridge.setGfxShowFTimes(showFrameTimes) },
          L("Per-frame render time in milliseconds. Useful for spotting hitches."))
        settingsCaption(
          Toggle(L("Show VBlank Times"), isOn: $showVBlankTimes).onChange(of: showVBlankTimes) { _ in DOLConfigBridge.setGfxShowVTimes(showVBlankTimes) },
          L("Time between emulated vertical-blank interrupts."))
        settingsCaption(
          Toggle(L("Show Graphs"), isOn: $showGraphs).onChange(of: showGraphs) { _ in DOLConfigBridge.setGfxShowGraphs(showGraphs) },
          L("Draws the timing stats as live graphs instead of numbers."))
        settingsCaption(
          Toggle(L("Log Render Time to File"), isOn: $logRenderTime).onChange(of: logRenderTime) { _ in DOLConfigBridge.setGfxLogRenderTimeToFile(logRenderTime) },
          L("Writes per-frame render times to a log file for offline analysis."))
        settingsCaption(
          Toggle(L("Speed Colors"), isOn: $speedColors).onChange(of: speedColors) { _ in DOLConfigBridge.setGfxShowSpeedColors(speedColors) },
          L("Color-codes the speed readout (green = full speed, red = slow)."))
      }

      Section(header: Text(L("Debugging"))) {
        settingsCaption(
          Toggle(L("Overlay Stats"), isOn: $overlayStats).onChange(of: overlayStats) { _ in DOLConfigBridge.setGfxOverlayStats(overlayStats) },
          L("Detailed rendering statistics overlay for developers."))
        settingsCaption(
          Toggle(L("API Validation Layer"), isOn: $validationLayer).onChange(of: validationLayer) { _ in DOLConfigBridge.setGfxEnableValidationLayer(validationLayer) },
          L("Extra graphics-API error checking. For debugging only — reduces performance. Leave off."))
      }

      Section(header: Text(L("Shader Threads"))) {
        settingsCaption(
          HStack {
            Text(L("Compiler Threads"))
            Spacer()
#if os(tvOS)
            TVIntStepper(value: $compilerThreads, range: 1...maxThreads, step: 1)
#else
            Stepper(value: $compilerThreads, in: 1...maxThreads) { Text("\(compilerThreads)") }
#endif
          }
          .onChange(of: compilerThreads) { v in DOLConfigBridge.setGfxShaderCompilerThreads(v) },
          L("CPU threads used to compile shaders on demand. More can reduce stutter but competes with the emulated CPU. 2–4 is a good range."))
        settingsCaption(
          HStack {
            Text(L("Precompiler Threads"))
            Spacer()
#if os(tvOS)
            TVIntStepper(value: $precompilerThreads, range: 1...maxThreads, step: 1)
#else
            Stepper(value: $precompilerThreads, in: 1...maxThreads) { Text("\(precompilerThreads)") }
#endif
          }
          .onChange(of: precompilerThreads) { v in DOLConfigBridge.setGfxShaderPrecompilerThreads(v) },
          L("Threads used to pre-build shaders before a game starts."))
      }

      Section(header: Text(L("Utility"))) {
        settingsCaption(
          Toggle(L("Load Custom Textures"), isOn: $hiresTextures).onChange(of: hiresTextures) { _ in DOLConfigBridge.setGfxHiresTextures(hiresTextures) },
          L("Loads installed high-resolution texture packs in place of the originals."))
        settingsCaption(
          Toggle(L("Prefetch Custom Textures"), isOn: $prefetchTextures)
            .disabled(!hiresTextures)
            .onChange(of: prefetchTextures) { _ in DOLConfigBridge.setGfxCacheHiresTextures(prefetchTextures) },
          L("Loads all custom textures into memory up front for smoother play, at higher memory use."))
        settingsCaption(
          Toggle(L("Disable EFB Copy to VRAM"), isOn: $disableEfbToVRAM).onChange(of: disableEfbToVRAM) { _ in DOLConfigBridge.setGfxHackDisableCopyToVRAM(disableEfbToVRAM) },
          L("Forces framebuffer copies through RAM instead of VRAM. Slower; only for rare compatibility cases."))
        settingsCaption(
          Toggle(L("Enable Graphics Mods"), isOn: $graphicsMods).onChange(of: graphicsMods) { _ in DOLConfigBridge.setGfxModsEnable(graphicsMods) },
          L("Enables community-created graphics mods for supported games."))
      }

      Section(header: Text(L("Misc"))) {
        settingsCaption(
          Toggle(L("Crop"), isOn: $cropPicture).onChange(of: cropPicture) { _ in DOLConfigBridge.setGfxCrop(cropPicture) },
          L("Crops the black borders some games render around the picture."))
        settingsCaption(
          Toggle(L("Progressive Scan"), isOn: $progressiveScan).onChange(of: progressiveScan) { _ in DOLConfigBridge.setSysconfProgressiveScan(progressiveScan) },
          L("Enables 480p progressive output for games that support it, reducing flicker."))
      }

      Section(header: Text(L("Rendering"))) {
        settingsCaption(
          Toggle(L("Fast Depth Calculation"), isOn: $fastDepth).onChange(of: fastDepth) { DOLConfigBridge.setGfxFastDepthCalc($0) },
          L("Uses a faster, less precise depth formula. Small speed win; can cause depth glitches in a few games. Recommended on."))
        settingsCaption(
          Toggle(L("Per-Pixel Lighting"), isOn: $pixelLighting).onChange(of: pixelLighting) { DOLConfigBridge.setGfxEnablePixelLighting($0) },
          L("Computes lighting per pixel for smoother shading, at a GPU cost. Off matches original hardware."))
        settingsCaption(
          Toggle(L("Backend Multithreading"), isOn: $backendMT).onChange(of: backendMT) { DOLConfigBridge.setGfxBackendMultithreading($0) },
          L("Lets the Metal video backend record/submit draw commands on a worker thread (host-side rendering optimization; unrelated to emulation threading)."))
        settingsCaption(
          Toggle(L("Enable Shader Cache"), isOn: $shaderCache).onChange(of: shaderCache) { DOLConfigBridge.setGfxShaderCache($0) },
          L("Saves compiled shaders to disk so they aren't rebuilt every launch. Recommended on."))
        settingsCaption(
          Toggle(L("Save Texture Cache to State"), isOn: $saveTexCache).onChange(of: saveTexCache) { DOLConfigBridge.setGfxSaveTextureCacheToState($0) },
          L("Includes the texture cache in save states for more accurate restores, at larger state files."))
        settingsCaption(
          Toggle(L("Prefer Vertex Shader for Line/Point Expansion"), isOn: $preferVSForLines).onChange(of: preferVSForLines) { DOLConfigBridge.setGfxPreferVSForLinePointExpansion($0) },
          L("Expands lines and points in a vertex shader instead of a geometry shader. Can be faster on some GPUs."))
        settingsCaption(
          Toggle(L("CPU Culling"), isOn: $cpuCull).onChange(of: cpuCull) { DOLConfigBridge.setGfxCpuCull($0) },
          L("Culls off-screen geometry on the CPU. Usually a net loss on the CPU-bound path; leave off unless GPU-limited."))
      }

      Section(header: Text(L("Experimental")), footer: Text(L("⚠️ Experimental — may cause instability or glitches in some games."))) {
        settingsCaption(
          Toggle(L("Defer EFB Cache Invalidation"), isOn: $deferEfbInvalidation).onChange(of: deferEfbInvalidation) { _ in DOLConfigBridge.setGfxHackEfbDeferInvalidation(deferEfbInvalidation) },
          L("Delays invalidating cached framebuffer copies. Can speed things up but may show stale graphics."))
        // Manual Texture Sampling is the inverse of Fast Texture Sampling
        settingsCaption(
          Toggle(L("Manual Texture Sampling"), isOn: $manualTexSampling).onChange(of: manualTexSampling) { _ in DOLConfigBridge.setGfxHackFastTextureSampling(!manualTexSampling) },
          L("Uses precise, hardware-accurate texture sampling (the inverse of Fast Texture Sampling). More accurate, slightly slower."))
      }
    }
    .navigationTitle(L("Advanced"))
    .onAppear { sync() }
  }
  private func sync() {
    fastDepth = DOLConfigBridge.gfxFastDepthCalc()
    pixelLighting = DOLConfigBridge.gfxEnablePixelLighting()
    backendMT = DOLConfigBridge.gfxBackendMultithreading()
    shaderCache = DOLConfigBridge.gfxShaderCache()
    saveTexCache = DOLConfigBridge.gfxSaveTextureCacheToState()
    preferVSForLines = DOLConfigBridge.gfxPreferVSForLinePointExpansion()
    cpuCull = DOLConfigBridge.gfxCpuCull()
    // Performance Statistics
    showFPS = DOLConfigBridge.gfxShowFPS()
    showVPS = DOLConfigBridge.gfxShowVPS()
    showSpeed = DOLConfigBridge.gfxShowSpeed()
    showFrameTimes = DOLConfigBridge.gfxShowFTimes()
    showVBlankTimes = DOLConfigBridge.gfxShowVTimes()
    showGraphs = DOLConfigBridge.gfxShowGraphs()
    logRenderTime = DOLConfigBridge.gfxLogRenderTimeToFile()
    speedColors = DOLConfigBridge.gfxShowSpeedColors()
    // Debugging
    overlayStats = DOLConfigBridge.gfxOverlayStats()
    validationLayer = DOLConfigBridge.gfxEnableValidationLayer()
    // Utility
    hiresTextures = DOLConfigBridge.gfxHiresTextures()
    prefetchTextures = DOLConfigBridge.gfxCacheHiresTextures()
    disableEfbToVRAM = DOLConfigBridge.gfxHackDisableCopyToVRAM()
    graphicsMods = DOLConfigBridge.gfxModsEnable()
    // Misc
    cropPicture = DOLConfigBridge.gfxCrop()
    progressiveScan = DOLConfigBridge.sysconfProgressiveScan()
    // Shader threads
    let cores = max(2, ProcessInfo.processInfo.processorCount)
    maxThreads = max(1, cores - 1)
    let ct = DOLConfigBridge.gfxShaderCompilerThreads()
    compilerThreads = (ct <= 0) ? min(2, maxThreads) : ct
    let pt = DOLConfigBridge.gfxShaderPrecompilerThreads()
    precompilerThreads = (pt <= 0) ? min(2, maxThreads) : pt
    // Experimental
    deferEfbInvalidation = DOLConfigBridge.gfxHackEfbDeferInvalidation()
    manualTexSampling = !DOLConfigBridge.gfxHackFastTextureSampling()
  }
}

// MARK: - Controllers Port
private struct ControllersPortView: View {
  let isGC: Bool
  let portOneBased: Int
  var title: String { isGC ? "\(L("GameCube Controller")) \(portOneBased)" : "\(L("Wii Remote")) \(portOneBased)" }
  @State private var canConfigure: Bool = false
  var body: some View {
    List {
      NavigationLink(L("Type"), destination: ControllersTypePicker(isGC: isGC, portOneBased: portOneBased))
      NavigationLink(L("Configure"), destination: ControllersMappingView(isGC: isGC, portOneBased: portOneBased))
        .disabled(!canConfigure)
    }
    .navigationTitle(Text(title))
    .onAppear { sync() }
  }
  private func sync() {
    if isGC {
      let device = DOLConfigBridge.gcPortDevice(forPort: portOneBased)
      canConfigure = device != 0
    } else {
      let source = DOLConfigBridge.wiimoteSource(for: portOneBased)
      canConfigure = source != 0
    }
  }
}

private struct ControllersTypePicker: View {
  let isGC: Bool
  let portOneBased: Int
  @State private var selected: Int = 0
  var body: some View {
    List {
      if isGC {
        // 0: None, 1: GC Controller
        SelectRow(label: L("<Nothing>"), checked: selected == 0) { selected = 0; DOLConfigBridge.setGCPortDeviceForPort(portOneBased, device: 0) }
        SelectRow(label: L("GameCube Controller"), checked: selected == 1) {
          selected = 1
          DOLConfigBridge.setGCPortDeviceForPort(portOneBased, device: 1)
          EmulationCoordinator.ensurePad1DefaultsToTouchscreen()
          ControllerManager.shared.reconcile()
        }
      } else {
        // 0: None, 1: Emulated
        SelectRow(label: L("<Nothing>"), checked: selected == 0) { selected = 0; DOLConfigBridge.setWiimoteSourceFor(portOneBased, source: 0) }
        SelectRow(label: L("Emulated Wii Remote"), checked: selected == 1) {
          selected = 1
          DOLConfigBridge.setWiimoteSourceFor(portOneBased, source: 1)
          EmulationCoordinator.ensureWiimoteDefaultsToTouchscreen(forPort: portOneBased)
          ControllerManager.shared.reconcile()
        }
      }
    }
    .navigationTitle(L("Type"))
    .onAppear { sync() }
  }
  private func sync() {
    if isGC {
      selected = DOLConfigBridge.gcPortDevice(forPort: portOneBased)
    } else {
      selected = DOLConfigBridge.wiimoteSource(for: portOneBased)
    }
  }
}

#if os(tvOS)
// UIKit wrapper for the legacy mapping UI (MappingRootViewController in ButtonMapping.storyboard)
private typealias ControllersMappingView = ButtonMappingView
#else
// UIKit wrapper for the legacy mapping UI (MappingRootViewController in ButtonMapping.storyboard)
private struct ControllersMappingView: UIViewControllerRepresentable {
  let isGC: Bool
  let portOneBased: Int

  func makeUIViewController(context: Context) -> UIViewController {
    let storyboard = UIStoryboard(name: "ButtonMapping", bundle: nil)
    let vc = storyboard.instantiateInitialViewController() ?? UIViewController()
    // Pass mapping context via KVC to avoid additional bridging requirements
    // DOLMappingType: 0 = Pad, 1 = Wiimote
    vc.setValue(isGC ? 0 : 1, forKey: "mappingType")
    vc.setValue(max(0, portOneBased - 1), forKey: "mappingPort")
    return vc
  }

  func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
    // No-op; mapping UI manages its own state
  }
}
#endif

// MARK: - Audio FX Chain Editor (iOS)
#if os(iOS)
import AVFoundation

struct FXChainEditor: View {
  @State private var effects: [FXItem] = []
  @State private var showingAU: UIViewController?
  @State private var showAddSheet = false
  @State private var searchText = ""
  @State private var availableCount: Int = 0
  @State private var showEnableEnginePrompt = false

  struct FXItem: Identifiable, Equatable { let id = UUID(); let name: String; var bypass: Bool; let index: Int }

  var body: some View {
    Group {
      HStack {
        Spacer()
        Button(action: {
          NSLog("[FX] Add button tapped")
          showAddSheet = true
        }) { Label(L("Add Effect"), systemImage: "plus").padding(.horizontal, 8).padding(.vertical, 6) }
          .contentShape(Rectangle())
          .allowsHitTesting(true)
      }
      .padding(.top, 4)
      HStack {
        Button(action: { refresh() }) { Label(L("Refresh Effects"), systemImage: "arrow.clockwise") }
          .padding(.vertical, 4)
        Spacer()
      }
      if effects.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text(isEngineActive() ? L("No active effects. Tap Add to insert an AUv3 effect.") : L("Requires AVAudioEngine backend.")).foregroundStyle(.secondary)
          Text(String(format: L("Installed: %d"), availableCount)).foregroundStyle(.secondary)
        }
      } else {
        ForEach(effects) { fx in
          HStack {
            Text(fx.name)
            Spacer()
            Toggle(L("Bypass"), isOn: Binding(get: { fx.bypass }, set: { v in setBypass(fx.index, v) }))
              .labelsHidden()
            Button { showUI(fx.index) } label: { Image(systemName: "slider.horizontal.3") }
              .buttonStyle(.borderless)
          }
        }
        .onMove(perform: move)
        .onDelete(perform: remove)
      }
    }
    .onAppear { refresh() }
    .sheet(isPresented: Binding(get: { showingAU != nil }, set: { if !$0 { showingAU = nil } })) {
      if let vc = showingAU { UIViewControllerWrapper(controller: vc) }
    }
    .sheet(isPresented: $showAddSheet) { AUAddSheet(onPick: { name in add(name) }).onDisappear { refresh() } }
    .alert(L("Enable AVAudioEngine?"), isPresented: $showEnableEnginePrompt) {
      Button(L("Enable")) {
        DOLConfigBridge.setAudioBackend("AVAudioEngine")
        waitUntilEngineActiveThen { showAddSheet = true; refresh() }
      }
      Button(L("Cancel"), role: .cancel) { }
    } message: {
      Text(L("Audio Effects require the AVAudioEngine backend."))
    }
  }

  private func isEngineActive() -> Bool { AudioFXBridge.isEngineActive() }
  private func waitUntilEngineActiveThen(_ action: @escaping () -> Void) {
    func poll(_ attempts: Int) {
      if AudioFXBridge.isEngineActive() {
        action()
      } else if attempts > 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { poll(attempts - 1) }
      }
    }
    poll(20)
  }

  private func refresh() {
    let list = AudioFXBridge.currentEffects()
    effects = list.enumerated().map { (i, d) in FXItem(name: (d["name"] as? String) ?? "Effect", bypass: (d["bypass"] as? Bool) ?? false, index: i) }
    // Log available AUv3 effects from the system for diagnostics
    let available = AudioFXBridge.availableEffects()
    availableCount = available.count
    NSLog("[FX] Available AUv3 effects count: %d", Int32(available.count))
    for (idx, entry) in available.enumerated() {
      if let e = entry as? [AnyHashable: Any], let nm = e["name"] as? String, let ident = e["identifier"] as? String {
        NSLog("[FX] #%d name=%@ ident=%@", Int32(idx), nm, ident)
      }
    }
  }
  private func add(_ name: String) {
    attemptAdd(name, attempts: 8)
  }
  private func attemptAdd(_ name: String, attempts: Int) {
    NSLog("[FX] Request add identifier=%@ attempts=%d", name, Int32(attempts))
    if AudioFXBridge.addEffect(withName: name) {
      NSLog("[FX] Add success for ident=%@", name)
      refresh()
      return
    }
    NSLog("[FX] Add failed for ident=%@ (engineActive=%d)", name, Int32(AudioFXBridge.isEngineActive() ? 1 : 0))
    if attempts > 0 && AudioFXBridge.isEngineActive() {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
        attemptAdd(name, attempts: attempts - 1)
      }
    }
  }
  private func remove(at offsets: IndexSet) {
    for o in offsets { AudioFXBridge.removeEffect(at: UInt(o)) }
    refresh()
  }
  private func move(from src: IndexSet, to dst: Int) {
    guard let from = src.first else { return }
    let to = dst > from ? dst - 1 : dst
    AudioFXBridge.moveEffect(from: UInt(from), to: UInt(to))
    refresh()
  }
  private func setBypass(_ idx: Int, _ v: Bool) { AudioFXBridge.setEffectAt(UInt(idx), bypassed: v); refresh() }
  private func showUI(_ idx: Int) {
    AudioFXBridge.requestEffectViewController(at: UInt(idx)) { vc in
      if let vc = vc {
        showingAU = vc
      }
    }
  }

  private struct UIViewControllerWrapper: UIViewControllerRepresentable {
    let controller: UIViewController
    func makeUIViewController(context: Context) -> UIViewController { controller }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) { }
  }

  private struct AUAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var search: String = ""
    @State private var effects: [[String: Any]] = []
    let onPick: (String) -> Void
    var body: some View {
      NavigationStack {
        VStack(spacing: 0) {
          HStack { TextField(L("Search Effects"), text: $search).textFieldStyle(.roundedBorder) }
            .padding()
          List(filtered()) { item in
            Button(action: { NSLog("[FX] (AddSheet) pick name=%@ ident=%@", item.name, item.identifier); onPick(item.identifier); dismiss() }) {
              VStack(alignment: .leading) {
                Text(item.name)
                Text(item.identifier).font(.footnote).foregroundStyle(.secondary)
              }
            }
          }
        }
        .navigationTitle(L("Add Effect"))
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L("Close")) { dismiss() } } }
        .onAppear { reload() }
      }
    }
    private func reload() {
      let arr = AudioFXBridge.availableEffects()
      NSLog("[FX] (AddSheet) discovered AUv3 effects: %d", Int32(arr.count))
      effects = arr.compactMap { ($0 as? [String: AnyHashable])?.reduce(into: [String: Any]()) { acc, kv in acc[kv.key] = kv.value } }
      for (idx, d) in effects.enumerated() {
        let nm = (d["name"] as? String) ?? "?"
        let id = (d["identifier"] as? String) ?? "?"
        NSLog("[FX] (AddSheet) #%d name=%@ ident=%@", Int32(idx), nm, id)
      }
    }
    private func filtered() -> [FXRow] {
      let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
      let source = effects
        .compactMap { dict -> FXRow? in
          guard let name = dict["name"] as? String, let id = dict["identifier"] as? String else { return nil }
          return FXRow(name: name, identifier: id)
        }
      if q.isEmpty { return source }
      return source.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.identifier.localizedCaseInsensitiveContains(q) }
    }
    struct FXRow: Identifiable { let id = UUID(); let name: String; let identifier: String }
  }
}

struct CoreAudioDSPEditor: View {
  let embedded: Bool
  init(embedded: Bool = false) { self.embedded = embedded }
  @State private var delayEnabled = false
  @State private var delayMs = 200.0
  @State private var delayFeedback = 0.35
  @State private var crushEnabled = false
  @State private var crushBits = 16.0
  @State private var crushDown = 1.0
  @State private var eqEnabled = false
  @State private var low = 0.0
  @State private var mid = 0.0
  @State private var high = 0.0

  private func defaults(_ key: String) -> Any? { UserDefaults.standard.object(forKey: key) }
  private func setDefaults(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: key) }
  private func applyToEngine() {
    AudioFXBridge.setCADelayEnabled(delayEnabled)
    AudioFXBridge.setCADelayMs(Int(delayMs))
    AudioFXBridge.setCADelayFeedback(delayFeedback)
    AudioFXBridge.setCABitcrushEnabled(crushEnabled)
    AudioFXBridge.setCABitcrushBits(Int(crushBits))
    AudioFXBridge.setCABitcrushDownsample(Int(crushDown))
    AudioFXBridge.setCAEQEnabled(eqEnabled)
    AudioFXBridge.setCAEQLowGainDb(low)
    AudioFXBridge.setCAEQMidGainDb(mid)
    AudioFXBridge.setCAEQHighGainDb(high)
  }
  private func syncFromDefaultsOrEngine() {
    // Prefer stored defaults if present; else query engine
    if defaults("ca_fx_delay_enabled") != nil {
      delayEnabled = UserDefaults.standard.bool(forKey: "ca_fx_delay_enabled")
      let dms = UserDefaults.standard.double(forKey: "ca_fx_delay_ms"); if dms > 0 { delayMs = dms }
      let dfb = UserDefaults.standard.double(forKey: "ca_fx_delay_fb"); if dfb > 0 { delayFeedback = dfb }
      crushEnabled = UserDefaults.standard.bool(forKey: "ca_fx_crush_enabled")
      let cb = UserDefaults.standard.integer(forKey: "ca_fx_crush_bits"); if cb > 0 { crushBits = Double(cb) }
      let cd = UserDefaults.standard.integer(forKey: "ca_fx_crush_down"); if cd > 0 { crushDown = Double(cd) }
      eqEnabled = UserDefaults.standard.bool(forKey: "ca_fx_eq_enabled")
      low = UserDefaults.standard.double(forKey: "ca_fx_eq_low")
      mid = UserDefaults.standard.double(forKey: "ca_fx_eq_mid")
      high = UserDefaults.standard.double(forKey: "ca_fx_eq_high")
      applyToEngine()
    } else {
      syncFromEngine()
    }
  }

  private func syncFromEngine() {
    let d = AudioFXBridge.coreAudioDSPState()
    if let v = d["delayEnabled"] as? Bool { delayEnabled = v }
    if let v = d["delayMs"] as? NSNumber { delayMs = v.doubleValue }
    if let v = d["delayFeedback"] as? NSNumber { delayFeedback = v.doubleValue }
    if let v = d["crushEnabled"] as? Bool { crushEnabled = v }
    if let v = d["crushBits"] as? NSNumber { crushBits = v.doubleValue }
    if let v = d["crushDown"] as? NSNumber { crushDown = v.doubleValue }
    if let v = d["eqEnabled"] as? Bool { eqEnabled = v }
    if let v = d["low"] as? NSNumber { low = v.doubleValue }
    if let v = d["mid"] as? NSNumber { mid = v.doubleValue }
    if let v = d["high"] as? NSNumber { high = v.doubleValue }
  }

  @ViewBuilder private var sections: some View {
    Group {
      VStack(alignment: .leading, spacing: 8) {
        Text(L("Delay / Echo")).font(.headline)
        Toggle(L("Enabled"), isOn: Binding(get: { delayEnabled }, set: { v in delayEnabled = v; setDefaults("ca_fx_delay_enabled", v); AudioFXBridge.setCADelayEnabled(v) }))
        HStack { Text(L("Time")); Slider(value: $delayMs, in: 10...2000, step: 10).onChange(of: delayMs) { setDefaults("ca_fx_delay_ms", $0); AudioFXBridge.setCADelayMs(Int($0)) }; Text("\(Int(delayMs)) ms") }
        HStack { Text(L("Feedback")); Slider(value: $delayFeedback, in: 0...0.95, step: 0.01).onChange(of: delayFeedback) { setDefaults("ca_fx_delay_fb", $0); AudioFXBridge.setCADelayFeedback($0) }; Text(String(format: "%.2f", delayFeedback)) }
      }
      VStack(alignment: .leading, spacing: 8) {
        Text(L("Bitcrusher")).font(.headline)
        Toggle(L("Enabled"), isOn: Binding(get: { crushEnabled }, set: { v in crushEnabled = v; setDefaults("ca_fx_crush_enabled", v); AudioFXBridge.setCABitcrushEnabled(v) }))
        HStack { Text(L("Bits")); Slider(value: $crushBits, in: 4...16, step: 1).onChange(of: crushBits) { setDefaults("ca_fx_crush_bits", Int($0)); AudioFXBridge.setCABitcrushBits(Int($0)) }; Text("\(Int(crushBits))") }
        HStack { Text(L("Downsample")); Slider(value: $crushDown, in: 1...16, step: 1).onChange(of: crushDown) { setDefaults("ca_fx_crush_down", Int($0)); AudioFXBridge.setCABitcrushDownsample(Int($0)) }; Text("\(Int(crushDown))x") }
      }
      VStack(alignment: .leading, spacing: 8) {
        Text(L("3‑Band EQ")).font(.headline)
        Toggle(L("Enabled"), isOn: Binding(get: { eqEnabled }, set: { v in eqEnabled = v; setDefaults("ca_fx_eq_enabled", v); AudioFXBridge.setCAEQEnabled(v) }))
        HStack { Text(L("Low")); Slider(value: $low, in: -24...24, step: 0.5).onChange(of: low) { setDefaults("ca_fx_eq_low", $0); AudioFXBridge.setCAEQLowGainDb($0) }; Text(String(format: "%+.1f dB", low)) }
        HStack { Text(L("Mid")); Slider(value: $mid, in: -24...24, step: 0.5).onChange(of: mid) { setDefaults("ca_fx_eq_mid", $0); AudioFXBridge.setCAEQMidGainDb($0) }; Text(String(format: "%+.1f dB", mid)) }
        HStack { Text(L("High")); Slider(value: $high, in: -24...24, step: 0.5).onChange(of: high) { setDefaults("ca_fx_eq_high", $0); AudioFXBridge.setCAEQHighGainDb($0) }; Text(String(format: "%+.1f dB", high)) }
      }
    }
  }

  var body: some View {
    if embedded {
      VStack(alignment: .leading, spacing: 16) { sections }
        .onAppear { syncFromDefaultsOrEngine() }
    } else {
      List { Section { sections } }
        .navigationTitle(L("Audio Effects"))
        .onAppear { syncFromDefaultsOrEngine() }
    }
  }
}
#endif

#if os(iOS)
/// Wrapper for presenting SFSafariViewController in SwiftUI
struct SafariView: UIViewControllerRepresentable {
  let url: URL
  func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
  func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) { }
}
#endif

private struct WiiAspectRatioPicker: View {
  @Binding var selectedWide: Bool
  var body: some View {
    List {
      SelectRow(label: "4:3", checked: selectedWide == false) { selectedWide = false; DOLConfigBridge.setSysconfWidescreen(false) }
      SelectRow(label: "16:9", checked: selectedWide == true) { selectedWide = true; DOLConfigBridge.setSysconfWidescreen(true) }
    }
    .navigationTitle(L("Aspect Ratio"))
  }
}

struct EnhancedMotionControlsView: View {
  // Use @AppStorage for automatic UI updates and better SwiftUI integration
  @AppStorage("motion_use_yaw_for_horizontal") private var useYawForHorizontal: Bool = false
  @AppStorage("motion_invert_roll") private var invertRoll: Bool = false
  @AppStorage("motion_invert_pitch") private var invertPitch: Bool = false
  @AppStorage("motion_enhanced_shake_detection") private var enhancedShakeEnabled: Bool = true
  @AppStorage("motion_enable_full_6dof") private var fullMotionEnabled: Bool = true
  @AppStorage("motion_wiimote_imu_enabled") private var wiimoteIMUEnabled: Bool = true
  @AppStorage("motion_nunchuck_imu_enabled") private var nunchuckIMUEnabled: Bool = false

  @State private var horizontalMotionMode: HorizontalMotionMode = .roll
  @State private var currentIRMode: TouchIRMode = .drag

  enum HorizontalMotionMode: Int, CaseIterable {
    case roll = 0, yaw = 1
    var label: String {
      switch self {
      case .roll: return L("Roll (Tilt Left/Right)")
      case .yaw: return L("Yaw (Turn Left/Right)")
      }
    }
    var description: String {
      switch self {
      case .roll: return L("Tilt device left/right to move cursor")
      case .yaw: return L("Rotate device left/right to move cursor")
      }
    }
  }

  var body: some View {
    List {
      Section(header: Text(L("Motion IR Cursor"))) {
        settingsNavCaption(
          destination: TouchIRModePicker(selected: $currentIRMode),
          L("How the Wii Remote IR pointer is controlled. Gyro uses device motion for added precision and unlocks the motion options below.")
        ) {
          Text(L("IR Control Method"))
        }
        .onChange(of: currentIRMode) { mode in
          DOLConfigBridge.setMainTouchPadIRMode(mode.rawValue)
          notifyMotionSettingsChanged()
        }

        if currentIRMode == .gyro {
          settingsNavCaption(
            destination: HorizontalMotionPicker(selected: $horizontalMotionMode),
            L("Whether tilting (roll) or turning (yaw) the device moves the pointer left/right.")
          ) {
            Text(L("Horizontal Movement"))
          }
          .onAppear { syncHorizontalMode() }
          .onChange(of: horizontalMotionMode) { mode in
            useYawForHorizontal = (mode == .yaw)
          }

          settingsCaption(
            Toggle(L("Invert Horizontal (Left/Right)"), isOn: $invertRoll),
            L("Flips left/right pointer motion."))

          settingsCaption(
            Toggle(L("Invert Vertical (Up/Down)"), isOn: $invertPitch),
            L("Flips up/down pointer motion."))
        }
      }

      Section(header: Text(L("Shake Detection"))) {
        settingsCaption(
          Toggle(L("Enable Advanced Shake Detection"), isOn: $enhancedShakeEnabled),
          L("Uses a motion-pattern algorithm to detect shake gestures more reliably than Dolphin's basic detection."))
      }

      Section(header: Text(L("Full Motion Mapping"))) {
        settingsCaption(
          Toggle(L("Enable 6DOF Motion Controls"), isOn: $fullMotionEnabled),
          L("Maps device motion to all 6 axes (rotation + acceleration) for games like Wii Sports and Mario Kart. Active only when IR control isn't using gyro mode."))

        if fullMotionEnabled {
          VStack(alignment: .leading, spacing: 8) {
            Toggle(L("Wiimote Motion Controls"), isOn: $wiimoteIMUEnabled)
            Text(L("Maps device motion to Wiimote's built-in accelerometer and gyroscope. Required for most motion-controlled Wii games."))
              .font(.caption)
              .foregroundColor(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.leading)

          VStack(alignment: .leading, spacing: 8) {
            Toggle(L("Nunchuck Motion Controls"), isOn: $nunchuckIMUEnabled)
            Text(L("Maps device motion to Nunchuck's accelerometer. Used by fewer games, mainly for secondary motion controls when using Nunchuck + Wiimote."))
              .font(.caption)
              .foregroundColor(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.leading)
        }
      }

      Section(header: Text(L("Quick Setup"))) {
        Button(L("Apply Recommended Settings")) {
          // Set improved defaults based on user feedback
          enhancedShakeEnabled = true
          currentIRMode = .gyro // Use gyro IR mode
          DOLConfigBridge.setMainTouchPadIRMode(TouchIRMode.gyro.rawValue)
          fullMotionEnabled = true
          useYawForHorizontal = false // Use roll by default
          wiimoteIMUEnabled = true
          nunchuckIMUEnabled = false
          invertRoll = false
          invertPitch = false

          // Update local state
          horizontalMotionMode = .roll

          // Show confirmation
          #if os(iOS)
          let generator = UINotificationFeedbackGenerator()
          generator.notificationOccurred(.success)
          #endif
        }
      }
    }
    .navigationTitle(L("Advanced Motion Settings"))
    .onAppear {
      syncHorizontalMode()
      syncIRMode()
    }
    // CRITICAL: Notify running emulator when settings change
    .onChange(of: useYawForHorizontal) { _ in notifyMotionSettingsChanged() }
    .onChange(of: invertRoll) { _ in notifyMotionSettingsChanged() }
    .onChange(of: invertPitch) { _ in notifyMotionSettingsChanged() }
    .onChange(of: enhancedShakeEnabled) { _ in notifyMotionSettingsChanged() }
    .onChange(of: fullMotionEnabled) { _ in notifyMotionSettingsChanged() }
    .onChange(of: wiimoteIMUEnabled) { _ in notifyMotionSettingsChanged() }
    .onChange(of: nunchuckIMUEnabled) { _ in notifyMotionSettingsChanged() }
  }

  private func syncHorizontalMode() {
    horizontalMotionMode = useYawForHorizontal ? .yaw : .roll
  }

  private func syncIRMode() {
    let irModeRaw = DOLConfigBridge.mainTouchPadIRMode()
    currentIRMode = TouchIRMode.from(raw: irModeRaw)
  }

  /// Notify running emulator that motion settings have changed
  private func notifyMotionSettingsChanged() {
    NotificationCenter.default.post(
      name: Notification.Name("DOLMotionSettingsChanged"),
      object: nil
    )
  }
}

private struct HorizontalMotionPicker: View {
  @Binding var selected: EnhancedMotionControlsView.HorizontalMotionMode

  var body: some View {
    List {
      ForEach(EnhancedMotionControlsView.HorizontalMotionMode.allCases, id: \.rawValue) { mode in
        Button(action: { selected = mode }) {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(mode.label)
                .foregroundColor(.primary)
              Text(mode.description)
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer()
            if selected == mode {
              Image(systemName: "checkmark")
                .foregroundColor(.accentColor)
            }
          }
        }
        .buttonStyle(.plain)
      }
    }
    .navigationTitle(L("Horizontal Movement"))
  }
}

#if os(iOS)
private struct HideListBackgroundIfAvailable: ViewModifier {
  func body(content: Content) -> some View {
    content.scrollContentBackground(.hidden)
  }
}
#endif

// MARK: - DSU Bonjour Discovery

struct DSUDiscoveredServer: Identifiable, Equatable {
  let id = UUID()
  let name: String
  let address: String
  let port: Int

  static func == (lhs: DSUDiscoveredServer, rhs: DSUDiscoveredServer) -> Bool {
    return lhs.address == rhs.address && lhs.port == rhs.port
  }
}

@MainActor
final class DSUDiscoveryBrowser: NSObject, ObservableObject {
  @Published var servers: [DSUDiscoveredServer] = []

  private var browser: NetServiceBrowser?
  private var services: [NetService] = []

  func start() {
    stop()
    servers.removeAll()
    services.removeAll()
    let b = NetServiceBrowser()
    b.delegate = self
    browser = b
    b.searchForServices(ofType: "_dolphin-dsu._udp", inDomain: "local.")
  }

  func stop() {
    browser?.stop()
    browser = nil
    services.forEach { $0.stop() }
    services.removeAll()
  }
}

extension DSUDiscoveryBrowser: NetServiceBrowserDelegate {
  func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
    service.delegate = self
    services.append(service)
    service.resolve(withTimeout: 5.0)
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
    services.removeAll { $0 == service }
    // Remove matching server entry if exists
    if let name = service.name as String? {
      servers.removeAll { $0.name == name }
    }
  }
}

extension DSUDiscoveryBrowser: NetServiceDelegate {
  func netServiceDidResolveAddress(_ sender: NetService) {
    guard let addresses = sender.addresses, !addresses.isEmpty else { return }
    var ipv4: String?
    for data in addresses {
      data.withUnsafeBytes { (rawPtr: UnsafeRawBufferPointer) in
        guard let sa = rawPtr.bindMemory(to: sockaddr.self).baseAddress else { return }
        if sa.pointee.sa_family == sa_family_t(AF_INET) {
          let sin = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in.self).pointee
          var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
          var addr = sin.sin_addr
          inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
          ipv4 = String(cString: buf)
        }
      }
      if ipv4 != nil { break }
    }
    guard let ip = ipv4 else { return }
    let port = sender.port
    let name = sender.name
    let item = DSUDiscoveredServer(name: name.isEmpty ? "DSU" : name, address: ip, port: port)
    if !servers.contains(item) {
      servers.append(item)
    }
  }
}
