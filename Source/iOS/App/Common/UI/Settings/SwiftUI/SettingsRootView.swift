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
#if os(iOS)
import NavigationStackBackport
#endif

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
  }

  @State private var currentSettingsPage: SettingsPage? = nil
  @State private var showGlobalResetAlert: Bool = false
#if os(iOS)
  @State private var showSafari: Bool = false
  @State private var safariURL: URL? = nil
#endif

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
                Text(appVersion)
                  .font(.system(size: 16, weight: .medium))
                  .foregroundColor(.white.opacity(0.6))
              }

              HStack {
                Text("Dolphin Core")
                  .font(.system(size: 16, weight: .medium))
                  .foregroundColor(.white.opacity(0.8))
                Spacer()
                Text(coreVersion)
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
                if !webURLString.isEmpty {
                  Button(action: {
                    if let u = URL(string: webURLString) {
                      safariURL = u
                      showSafari = true
                    }
                  }) {
                    Text(webURLString)
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
                Text(webURLString.isEmpty ? L("Not Running") : webURLString)
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
                Text(webDavURLString.isEmpty ? L("Not Running") : webDavURLString)
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
          NavigationLink(destination: DebugRootView()) {
            Label(L("Debug"), systemImage: "ladybug")
          }
        }

        Section(footer: EmptyView()) {
          HStack {
            Text(L("Version"))
            Spacer()
            if #available(iOS 17.0, *) {
              Text(appVersion).foregroundStyle(.secondary)
            }
          }
          HStack {
            Image("DolphinLogo")
              .resizable()
              .scaledToFit()
              .frame(height: 24)
            Text(L("Core"))
            Spacer()
            if #available(iOS 15.0, *) {
              Text(coreVersion).foregroundStyle(.secondary)
            }
          }
          NavigationLink(destination: AboutView()) {
            Label(L("About"), systemImage: "info.circle")
          }
          NavigationLink(destination: DolphinBlogView()) {
            Label("Dolphin Blog", systemImage: "newspaper")
          }
#if os(tvOS)
          NavigationLink(L("Help"), destination: HelpPlaceholderView())
#else
          Button(L("Help")) {
            if let url = URL(string: "https://oatmealdome.me/dolphinios/") {
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
            let s = webURLString
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
            let s = webDavURLString
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
      NavigationLink(destination: ConfigAchievementsView()) {
        Label(L("Achievements"), systemImage: "trophy")
      }
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

      Section(header: Text(L("General")), footer: Text(L("Background Input: Allows controller input when DolphiniOS is in the background.\nAuto-select On-Screen Controller: Automatically chooses GameCube or Wii controller layout based on the game being played."))) {
        Toggle(L("Background Input"), isOn: $backgroundInput)
          .onChange(of: backgroundInput) { newValue in DOLConfigBridge.setMainBackgroundInput(newValue) }
        Toggle(L("Auto‑select On‑Screen Controller by System"), isOn: $autoSelectOnScreenBySystem)
          .onChange(of: autoSelectOnScreenBySystem) { newValue in UserDefaults.standard.set(newValue, forKey: "auto_touchpad_by_system") }

#if os(iOS)
        Button(action: { testRumble() }) {
          Label(L("Test Rumble"), systemImage: "iphone.radiowaves.left.and.right")
        }
#endif
      }

      Section(header: Text(L("Wii Remotes")), footer: Text(L("Continuous Scanning: Keeps looking for new Wiimotes to connect.\nEnable Speaker: Plays audio through the Wiimote speaker (requires real Wiimote).\nConnect Wiimotes for Controller Interface: Automatically pairs Wiimotes when controller interface is used."))) {
        Toggle(L("Continuous Scanning"), isOn: $wiimoteScan)
          .onChange(of: wiimoteScan) { newValue in DOLConfigBridge.setWiimoteContinuousScanning(newValue) }
        Toggle(L("Enable Speaker"), isOn: $wiimoteSpeaker)
          .onChange(of: wiimoteSpeaker) { newValue in DOLConfigBridge.setWiimoteEnableSpeaker(newValue) }
        Toggle(L("Connect Wiimotes for Controller Interface"), isOn: $connectWiimotes)
          .onChange(of: connectWiimotes) { newValue in DOLConfigBridge.setConnectWiimotesForControllerInterface(newValue) }
      }

      Section(header: Text(L("Alternate Input Sources")), footer: Text(L("Opacity: Controls transparency of on-screen touch controls.\nTouch IR Pointer: Choose how the Wiimote pointer is controlled - Gyro uses device motion, Follow/Drag use touch gestures."))) {
#if os(iOS)
        HStack {
          Text(L("Opacity"))
          Spacer()
          Slider(value: Binding(get: { Double(touchOpacity) }, set: { touchOpacity = Float($0) }), in: 0...1)
            .frame(width: 220)
            .onChange(of: touchOpacity) { DOLConfigBridge.setMainTouchPadOpacity($0) }
        }
#endif
        NavigationLink("\(L("Touch IR Pointer")): \(touchIRMode.label)", destination: TouchIRModePicker(selected: $touchIRMode))
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
  private func testRumble() {
    var controllersTestedCount = 0
    var deviceTested = false

    // Test ALL connected external controller haptics
    let controllers = GCController.controllers()
    for controller in controllers {
      if #available(iOS 14.0, *), let haptics = controller.haptics {
        do {
          let engine = try haptics.createEngine(withLocality: .default)
          try engine?.start()
          let pattern = try CHHapticPattern(events: [
            CHHapticEvent(eventType: .hapticTransient, parameters: [
              CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
              CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.8)
            ], relativeTime: 0),
            CHHapticEvent(eventType: .hapticTransient, parameters: [
              CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6),
              CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4)
            ], relativeTime: 0.15)
          ], parameters: [])
          if let engine = engine {
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
            controllersTestedCount += 1
          }
        } catch {
          // Controller haptics failed for this controller, continue to next
        }
      }
    }

    // Test device haptics (iPhone vibration)
    if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
      do {
        let engine = try CHHapticEngine()
        try engine.start()

        // Create a strong rumble pattern
        let pattern = try CHHapticPattern(events: [
          CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
          ], relativeTime: 0),
          CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.8),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
          ], relativeTime: 0.1, duration: 0.3)
        ], parameters: [])

        let player = try engine.makePlayer(with: pattern)
        try player.start(atTime: 0)
        deviceTested = true
      } catch {
        // Device haptics failed, try fallback
      }
    }

    // Fallback: Use legacy UIKit vibration if device CoreHaptics isn't available
    if !deviceTested {
      AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
      deviceTested = true
    }

    // Show appropriate message based on what was tested
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
  @State private var syncOnSkipIdle: Bool = false
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

  var body: some View {
    List {
      Section(header: Text(L("CPU / Memory"))) {
        Toggle(L("Fastmem"), isOn: $fastmem)
          .onChange(of: fastmem) { DOLConfigBridge.setMainFastmem($0) }
          .disabled(!fastmemAvailable)
        Toggle(L("Sync on Skip Idle"), isOn: $syncOnSkipIdle)
          .onChange(of: syncOnSkipIdle) { DOLConfigBridge.setMainSyncOnSkipIdle($0) }
      }

      Section(header: Text(L("Controllers"))) {
        Toggle(L("Connect MFi Controllers"), isOn: $mfiConnect)
          .onChange(of: mfiConnect) { _ in
            UserDefaults.standard.set(mfiConnect, forKey: "virtual_mfi_connect")
          }
      }

      Section(header: Text(L("Recording")), footer: Text(L("Instant Replay may reduce performance; keep disabled on older devices."))) {
#if os(iOS)
        Toggle(L("Enable ReplayKit Instant Replay"), isOn: $instantReplay)
          .onChange(of: instantReplay) { UserDefaults.standard.set($0, forKey: "replaykit_instant_replay_enabled") }
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
        NavigationLink(destination: MotionDebugView()) {
          Label(L("Motion Debug"), systemImage: "sensor.tag.radiowaves.forward")
        }
      }

      Section(header: Text(L("Logging"))) {
        Toggle(L("Enable Console Logging"), isOn: $loggingEnabled)
          .onChange(of: loggingEnabled) { UserDefaults.standard.set($0, forKey: "logger_console_enabled") }
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
        }
        Toggle(L("Input Event Debug"), isOn: $inputDebug)
          .onChange(of: inputDebug) { UserDefaults.standard.set($0, forKey: "input_debug") }
      }
    }
    .navigationTitle(L("Debug"))
    .onAppear { syncDebug() }
  }

  private func syncDebug() {
    fastmem = DOLConfigBridge.mainFastmem()
    syncOnSkipIdle = DOLConfigBridge.mainSyncOnSkipIdle()
    mfiConnect = UserDefaults.standard.bool(forKey: "virtual_mfi_connect")
    userFolder = UserFolderUtil.getUserFolder()
    jitAcquired = (JitManager.shared().acquiredJit)
    jitError = (JitManager.shared().acquisitionError) ?? ""
    fastmemAvailable = (FastmemManager.shared().fastmemAvailable)
    launchTimes = UserDefaults.standard.integer(forKey: "launch_times")
    loggingEnabled = UserDefaults.standard.bool(forKey: "logger_console_enabled")
    var v = UserDefaults.standard.integer(forKey: "logger_console_verbosity"); if v <= 0 { v = 4 }
    loggingVerbosity = v
    inputDebug = UserDefaults.standard.bool(forKey: "input_debug")
    instantReplay = UserDefaults.standard.bool(forKey: "replaykit_instant_replay_enabled")
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
          Image("DolphinLogo")
            .resizable()
            .scaledToFit()
            .frame(height: 128)
            .scaleEffect(logoScale)
            .rotationEffect(.degrees(logoRotation))
            .animation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true), value: logoScale)
            .animation(.easeInOut(duration: 4.0).repeatForever(autoreverses: true), value: logoRotation)
        }
        .frame(height: 160)
        .onAppear {
          startAboutAnimation()
        }

        Text("DolphiniOS")
          .font(.system(size: 28, weight: .semibold))
          .foregroundColor(.blue)

        Text("© 2003-2015+ Dolphin Team.\n© 2019-2025+ DolphiniOS Project.")
          .multilineTextAlignment(.center)

        Text("SwiftUI version by Joe Mattiello")
          .multilineTextAlignment(.center)

        Button("github.com/JoeMatt") {
          if let url = URL(string: "https://github.com/JoeMatt") {
            openURL(url)
          }
        }

        Text("DolphiniOS is an unofficial and separately maintained port of Dolphin to iOS. The DolphiniOS Project has no relation to Dolphin Team.")
          .multilineTextAlignment(.center)

        Text("\"GameCube\" and \"Wii\" are trademarks of Nintendo. DolphiniOS is not affiliated with Nintendo in any way.")
          .multilineTextAlignment(.center)

        Text("This software should not be used to play games you do not legally own.")
          .multilineTextAlignment(.center)

        Button(L("Source Code")) {
          if let url = URL(string: "https://github.com/OatmealDome/dolphinios") {
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
  @State private var fallbackRegion: Region = .unknown

  var body: some View {
    List {
      Section(header: Text(L("Basic Settings")), footer: Text(L("These settings provide performance improvements for most games. Dual Core and DSP Thread offer significant speedups on multi-core devices."))) {
        Toggle(L("Enable Dual Core (speedup)"), isOn: $dualCore)
          .onChange(of: dualCore) { DOLConfigBridge.setMainCpuThread($0) }
        Toggle(L("Enable Cheats"), isOn: $cheats)
          .onChange(of: cheats) { DOLConfigBridge.setMainEnableCheats($0) }
        Toggle(L("Override Region Mismatch"), isOn: $mismatchedRegion)
          .onChange(of: mismatchedRegion) { DOLConfigBridge.setMainOverrideRegionSettings($0) }
        Toggle(L("Auto Disc Change"), isOn: $autoDiscChange)
          .onChange(of: autoDiscChange) { DOLConfigBridge.setMainAutoDiscChange($0) }
        Toggle(L("Fast Disc Speed (speedup)"), isOn: $fastDiscSpeed)
          .onChange(of: fastDiscSpeed) { DOLConfigBridge.setMainFastDiscSpeed($0) }
        Toggle(L("DSP Thread (speedup)"), isOn: $dspThread)
          .onChange(of: dspThread) { DOLConfigBridge.setMainDSPThread($0) }
      }

      Section(header: Text(L("Speed"))) {
        NavigationLink(destination: SpeedLimitPicker(selectedPercent: $speedLimitPercent)) {
          HStack {
            Label(L("Speed Limit"), systemImage: "speedometer")
            Spacer()
            Text(speedLimitLabel(percent: speedLimitPercent))
              .foregroundStyle(.secondary)
          }
        }
        .onChange(of: speedLimitPercent) { DOLConfigBridge.setMainEmulationSpeedPercent($0) }

        NavigationLink(destination: FastForwardSpeedPicker(selectedPercent: $fastForwardSpeedPercent)) {
          HStack {
            Label(L("Fast Forward Speed"), systemImage: "forward.fill")
            Spacer()
            Text(fastForwardSpeedLabel(percent: fastForwardSpeedPercent))
              .foregroundStyle(.secondary)
          }
        }
        .onChange(of: fastForwardSpeedPercent) { UserDefaults.standard.set($0, forKey: "fast_forward_speed_percent") }
      }

      Section(header: Text(L("Fallback Region")), footer: Text(L("Dolphin will use this for titles whose region cannot be determined automatically."))) {
        NavigationLink("\(L("Fallback Region")): \(fallbackRegion.label)", destination: FallbackRegionPicker(selected: $fallbackRegion))
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
  @State private var mmu: Bool = false
  @State private var adaptiveClock: Bool = false // NSUserDefaults-backed
  @State private var pauseOnPanic: Bool = false
  @State private var writeBackCache: Bool = false
  @State private var disableICache: Bool = false
  @State private var lowDCBZ: Bool = false

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
      Section(header: Text(L("CPU Options")), footer: Text(L("CPU Emulation Engine: ARM64 JIT is fastest on modern devices. MMU: Enables memory management (required for some games, reduces performance). Adaptive Clock: Automatically adjusts timing (experimental). Accurate CPU Cache: More precise emulation but slower."))) {
        NavigationLink("\(L("CPU Emulation Engine")): \(cpuEngine.label)", destination: CpuEnginePicker(selected: $cpuEngine))
          .onChange(of: cpuEngine) { DOLConfigBridge.setMainCpuCore($0.rawValue) }
        Toggle(L("Enable MMU"), isOn: $mmu)
          .onChange(of: mmu) { DOLConfigBridge.setMainMMU($0) }
        Toggle(L("Adaptive Clock (auto VI/CPU)"), isOn: $adaptiveClock)
          .onChange(of: adaptiveClock) { UserDefaults.standard.set($0, forKey: "adaptive_clock_enable") }
        Toggle(L("Pause on Panic"), isOn: $pauseOnPanic)
          .onChange(of: pauseOnPanic) { DOLConfigBridge.setMainPauseOnPanic($0) }
        Toggle(L("Accurate CPU Cache (slower)"), isOn: $writeBackCache)
          .onChange(of: writeBackCache) { DOLConfigBridge.setMainAccurateCpuCache($0) }
        Toggle(L("Bypass Instruction Cache"), isOn: $disableICache)
          .onChange(of: disableICache) { DOLConfigBridge.setMainDisableICache($0) }
        Toggle(L("DCBZ Hack"), isOn: $lowDCBZ)
          .onChange(of: lowDCBZ) { DOLConfigBridge.setMainLowDCBZHack($0) }
      }

      Section(header: Text(L("Clock Override")), footer: Text(L("Adjusts the emulated CPU's clock rate. Can also be adjusted during gameplay via the in-game menu.\n\nHigher values may make variable-framerate games run at a higher framerate, at the expense of performance. Lower values may activate a game's internal frameskip, potentially improving performance.\n\nWARNING: Changing this from the default (100%) can and will break games and cause glitches. Do so at your own risk. Please do not report bugs that occur with a non-default clock."))) {
        Toggle(L("Enable Emulated CPU Clock Override"), isOn: $cpuClockEnabled)
          .onChange(of: cpuClockEnabled) { DOLConfigBridge.setMainOverclockEnable($0) }
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

      Section(header: Text(L("Override VBI Frequency")), footer: Text(L("Makes games run at a different frame rate. Can also be adjusted during gameplay via the in-game menu.\n\nMakes emulation less demanding when lowered, or improves smoothness when increased. This may affect gameplay speed, as it is often tied to the frame rate."))) {
        Toggle(L("Enable VBI Frequency Override"), isOn: $vbiEnabled)
          .onChange(of: vbiEnabled) { DOLConfigBridge.setMainViOverclockEnable($0) }
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

      Section(header: Text(L("Memory Override")), footer: Text(L("Adjusts the amount of RAM in the emulated console. MEM1: Main system memory (24-64 MB). MEM2: Extended memory for Wii (64-128 MB).\n\n⚠️ WARNING: Enabling this will completely break many games. Only a small number of games can benefit from this. Save states with different memory sizes will not work."))) {
        Toggle(L("Enable Emulated Memory Size Override"), isOn: $memOverride)
          .onChange(of: memOverride) { DOLConfigBridge.setMainRamOverrideEnable($0) }
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

      Section(header: Text(L("Custom RTC Options")), footer: Text(L("This setting allows you to set a custom real time clock (RTC) separate from your current system time.\n\nIf unsure, leave this unchecked."))) {
        Toggle(L("Enable Custom RTC"), isOn: $rtcEnabled)
          .onChange(of: rtcEnabled) { DOLConfigBridge.setMainCustomRtcEnable($0) }
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

  private func syncAdvanced() {
    cpuEngine = CpuEngine.from(raw: DOLConfigBridge.mainCpuCore())
    mmu = DOLConfigBridge.mainMMU()
    adaptiveClock = UserDefaults.standard.bool(forKey: "adaptive_clock_enable")
    pauseOnPanic = DOLConfigBridge.mainPauseOnPanic()
    writeBackCache = DOLConfigBridge.mainAccurateCpuCache()
    disableICache = DOLConfigBridge.mainDisableICache()
    lowDCBZ = DOLConfigBridge.mainLowDCBZHack()

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
  var body: some View {
    List {
      ForEach(Array(CpuEngine.allCases.enumerated()), id: \.offset) { _, value in
        SelectRow(label: value.label, checked: value == selected) { selected = value; DOLConfigBridge.setMainCpuCore(value.rawValue) }
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

  var body: some View {
    List {
      Section(header: Text(L("Game List"))) {
        Toggle(L("Use Built-In Database of Game Names"), isOn: $useNamesDB)
          .onChange(of: useNamesDB) { DOLConfigBridge.setMainUseBuiltInTitleDatabase($0) }
        Toggle(L("Download Game Covers from GameTDB.com for Use in Grid Mode"), isOn: $useCovers)
          .onChange(of: useCovers) { DOLConfigBridge.setMainUseGameCovers($0) }
      }

      Section(header: Text(L("General"))) {
        Toggle(L("Confirm on Stop"), isOn: $confirmOnStop)
          .onChange(of: confirmOnStop) { DOLConfigBridge.setMainConfirmOnStop($0) }
        Toggle(L("Use Panic Handlers"), isOn: $usePanicHandlers)
          .onChange(of: usePanicHandlers) { DOLConfigBridge.setMainUsePanicHandlers($0) }
        Toggle(L("Show On-Screen Display Messages"), isOn: $osdMessages)
          .onChange(of: osdMessages) { DOLConfigBridge.setMainOSDMessages($0) }
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
        NavigationLink(backend.isEmpty ? L("Default Device") : (backend == "AVAudioEngine" ? "AVAudioEngine (Supports AUv3 FXs)" : (backend == "CoreAudio" ? "CoreAudio (Speakers/HDMI)" : backend)), destination: BackendPickerView(selected: $backend, options: availableBackends))
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
      if b == "AVAudioEngine" { return "AVAudioEngine (Supports AUv3 FXs)" }
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
  @State private var gcLanguage: Int = 1
  var body: some View {
    List {
      Section(header: Text(L("General"))) {
        Toggle(L("Load GameCube Main Menu"), isOn: Binding(get: { !skipIPL }, set: { skipIPL = !$0 }))
          .onChange(of: skipIPL) { DOLConfigBridge.setMainSkipIPL($0) }
      }

      Section(header: Text(L("System Language"))) {
        NavigationLink(languageLabel(for: gcLanguage), destination: GCLanguagePicker(selected: $gcLanguage))
          .onChange(of: gcLanguage) { DOLConfigBridge.setMainGCLanguage($0) }
      }
    }
    .navigationTitle(L("GameCube"))
    .onAppear { syncGC() }
  }

  private func syncGC() {
    skipIPL = DOLConfigBridge.mainSkipIPL()
    let lang = DOLConfigBridge.mainGCLanguage()
    if (0...6).contains(lang) {
      gcLanguage = lang
    } else {
      gcLanguage = 1
      DOLConfigBridge.setMainGCLanguage(1)
    }
  }

  private func languageLabel(for value: Int) -> String {
    switch value { case 0: return L("Japanese"); case 1: return L("English"); case 2: return L("German"); case 3: return L("French"); case 4: return L("Spanish"); case 5: return L("Italian"); case 6: return L("Dutch"); default: return L("Error") }
  }
}

private struct GCLanguagePicker: View {
  @Binding var selected: Int
  private let options: [Int] = [0, 1, 2, 3, 4, 5, 6]
  var body: some View {
    List {
      ForEach(options, id: \.self) { v in
        SelectRow(label: label(v), checked: v == selected) { selected = v; DOLConfigBridge.setMainGCLanguage(v) }
      }
    }
    .navigationTitle(L("System Language"))
  }
  private func label(_ v: Int) -> String {
    switch v { case 0: return L("Japanese"); case 1: return L("English"); case 2: return L("German"); case 3: return L("French"); case 4: return L("Spanish"); case 5: return L("Italian"); case 6: return L("Dutch"); default: return L("Error") }
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
      Section(header: Text(L("Video"))) {
        Toggle(L("Use PAL60 Mode (EuRGB60)"), isOn: $pal60).onChange(of: pal60) { DOLConfigBridge.setSysconfPAL60($0) }
        /// Wii System Aspect Ratio (4:3 vs 16:9)
        HStack {
          Text(L("Aspect Ratio"))
          Spacer()
          NavigationLink(widescreen ? "16:9" : "4:3", destination: WiiAspectRatioPicker(selectedWide: $widescreen))
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .onChange(of: widescreen) { DOLConfigBridge.setSysconfWidescreen($0) }
      }

      Section(header: Text(L("General"))) {
        Toggle(L("Enable Screen Saver"), isOn: $screensaver).onChange(of: screensaver) { DOLConfigBridge.setSysconfScreensaver($0) }
        HStack {
          Text(L("System Language"))
          Spacer()
          NavigationLink(languageLabel(language), destination: WiiLanguagePicker(selected: $language))
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .onChange(of: language) { DOLConfigBridge.setSysconfLanguage($0) }
        HStack {
          Text(L("Audio Settings"))
          Spacer()
          NavigationLink(audioModeLabel(soundMode), destination: WiiAudioModePicker(selected: $soundMode))
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .onChange(of: soundMode) { DOLConfigBridge.setSysconfSoundMode($0) }
      }

      Section(header: Text(L("Wii Remotes"))) {
        HStack {
          Text(L("Sensor Bar Position")); Spacer(); NavigationLink(posLabel(sensorBarPos), destination: WiiSensorBarPosPicker(selected: $sensorBarPos)).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .onChange(of: sensorBarPos) { DOLConfigBridge.setSysconfSensorBarPosition($0) }
        HStack {
          Text(L("IR Sensitivity")); Spacer()
#if os(tvOS)
          TVIntStepper(value: $sensorBarSens, range: 1...5, step: 1)
#else
          Slider(value: Binding(get: { Double(sensorBarSens) }, set: { sensorBarSens = Int($0) }), in: 1...5)
            .frame(width: 260)
#endif
        }
        .onChange(of: sensorBarSens) { DOLConfigBridge.setSysconfSensorBarSensitivity($0) }
        HStack {
          Text(L("Speaker Volume")); Spacer()
#if os(tvOS)
          TVIntStepper(value: $speakerVol, range: 0...7, step: 1)
#else
          Slider(value: Binding(get: { Double(speakerVol) }, set: { speakerVol = Int($0) }), in: 0...7)
            .frame(width: 260)
#endif
        }
        .onChange(of: speakerVol) { DOLConfigBridge.setSysconfSpeakerVolume($0) }
        Toggle(L("Rumble"), isOn: $wiimoteRumble).onChange(of: wiimoteRumble) { DOLConfigBridge.setSysconfWiimoteMotor($0) }
        Toggle(L("Allow Touchpad IR Follow Without Click"), isOn: $touchpadIRFollowWithoutClick)
          .onChange(of: touchpadIRFollowWithoutClick) { UserDefaults.standard.set($0, forKey: "touchpad_ir_follow_without_click") }
      }

      Section(header: Text(L("USB / SD"))) {
        Toggle(L("Emulate Skylander Portal"), isOn: Binding(get: { DOLConfigBridge.mainEmulateSkylanderPortal() }, set: { DOLConfigBridge.setMainEmulateSkylanderPortal($0) }))
        Toggle(L("Connect USB Keyboard"), isOn: $keyboard).onChange(of: keyboard) { DOLConfigBridge.setMainWiiKeyboard($0) }
        Toggle(L("Enable WiiConnect24 via WiiLink"), isOn: $wiilink).onChange(of: wiilink) { DOLConfigBridge.setMainWiiWiiLinkEnable($0) }
        Toggle(L("Insert SD Card"), isOn: $sdCard).onChange(of: sdCard) { DOLConfigBridge.setMainWiiSDCard($0) }
        Toggle(L("Allow Writes to SD Card"), isOn: $sdWrites).onChange(of: sdWrites) { DOLConfigBridge.setMainAllowSDWrites($0) }
        Toggle(L("Synchronize SD Card Folder on Start/Stop"), isOn: $sdFolderSync).onChange(of: sdFolderSync) { DOLConfigBridge.setMainWiiSDCardEnableFolderSync($0) }
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
      Section(header: Text(L("RetroAchievements")), footer: Text(L("Connect to RetroAchievements.org to unlock achievements, compete with friends, and track your gaming progress across all supported games."))) {
        HStack {
          Label(L("Enable Integration"), systemImage: "trophy.fill")
          Spacer()
          Toggle("", isOn: $enabled).onChange(of: enabled) { DOLConfigBridge.setRaEnabled($0) }
        }

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

      Section(header: Text(L("Game Mode Options")), footer: Text(L("Hardcore Mode: Disables save states, cheats, and other emulator features for authentic difficulty. Encore Mode: Re-enables completed achievements. Spectator Mode: View achievements without earning them."))) {
        HStack {
          Label(L("Hardcore Mode"), systemImage: "flame.fill")
            .foregroundColor(.orange)
          Spacer()
          Toggle("", isOn: $hardcore).onChange(of: hardcore) { DOLConfigBridge.setRaHardcoreEnabled($0) }
        }

        HStack {
          Label(L("Enable Unofficial"), systemImage: "person.3.sequence.fill")
            .foregroundColor(.purple)
          Spacer()
          Toggle("", isOn: $unofficial).onChange(of: unofficial) { DOLConfigBridge.setRaUnofficialEnabled($0) }
        }

        HStack {
          Label(L("Encore Mode"), systemImage: "arrow.clockwise.circle.fill")
            .foregroundColor(.green)
          Spacer()
          Toggle("", isOn: $encore).onChange(of: encore) { DOLConfigBridge.setRaEncoreEnabled($0) }
        }

        HStack {
          Label(L("Spectator Mode"), systemImage: "eye.fill")
            .foregroundColor(.blue)
          Spacer()
          Toggle("", isOn: $spectator).onChange(of: spectator) { DOLConfigBridge.setRaSpectatorEnabled($0) }
        }
      }

      Section(header: Text(L("Interface & Sharing")), footer: Text(L("Discord Presence: Shows your current achievements in Discord status. Progress Popups: Display achievement progress notifications during gameplay."))) {
        HStack {
          Label(L("Discord Presence"), systemImage: "bubble.left.and.bubble.right.fill")
            .foregroundColor(.indigo)
          Spacer()
          Toggle("", isOn: $discordPresence).onChange(of: discordPresence) { DOLConfigBridge.setRaDiscordPresenceEnabled($0) }
        }

        HStack {
          Label(L("Show Progress Popups"), systemImage: "bell.badge.fill")
            .foregroundColor(.orange)
          Spacer()
          Toggle("", isOn: $progress).onChange(of: progress) { DOLConfigBridge.setRaProgressEnabled($0) }
        }
      }

      Section(header: Text(L("Advanced")), footer: Text(L("Custom server URL for RetroAchievements API. Only change this if you know what you're doing or are using a custom server."))) {
        HStack {
          Label(L("Server URL"), systemImage: "server.rack")
          Spacer()
          TextField("https://retroachievements.org", text: $hostURL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .keyboardType(.URL)
            .multilineTextAlignment(.trailing)
            .onChange(of: hostURL) { DOLConfigBridge.setRaHostURL($0) }
        }
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

  // Shader compilation
  @State private var shaderType: ShaderCompileType = .asynchronousUber
  @State private var compileBeforeStart: Bool = false

  var body: some View {
    List {
      Section {
        NavigationLink(destination: GraphicsBackendPickerView(selected: $backend)) {
          Text("\(L("Backend")): \(backend.label)")
        }
        .onChange(of: backend) { _ in
          DOLConfigBridge.setGfxBackend(backend.backendKey)
          UserDefaults.standard.set(backend.backendKey, forKey: "ui_gfx_backend")
        }
        NavigationLink(destination: GraphicsAspectRatioView(selected: $aspect)) {
          Text("\(L("Aspect Ratio")): \(aspect.label)")
        }
        .onChange(of: aspect) { _ in DOLConfigBridge.setGfxAspectRatio(aspect.aspectRaw) }
        Toggle(L("V-Sync"), isOn: $vSync)
          .onChange(of: vSync) { newValue in DOLConfigBridge.setGfxVSync(newValue) }
        Toggle(L("Show Auto IR OSD"), isOn: $showAutoIrOSD)
          .onChange(of: showAutoIrOSD) { newValue in DOLConfigBridge.setGfxAutoIRShowOSD(newValue) }
        Toggle(L("Triple Buffering"), isOn: $tripleBuffering)
          .onChange(of: tripleBuffering) { newValue in UserDefaults.standard.set(newValue, forKey: "gfx_triple_buffering") }
        Toggle(L("Force scale 1.0 on non‑ProMotion"), isOn: $forceScaleOneNonProMotion)
          .onChange(of: forceScaleOneNonProMotion) { newValue in UserDefaults.standard.set(newValue, forKey: "gfx_force_scale_one_non_promo") }
        Toggle(L("Asynchronous Present"), isOn: $asyncPresent)
          .onChange(of: asyncPresent) { newValue in DOLConfigBridge.setGfxAsyncPresent(newValue) }
        Toggle(L("Enable Auto Internal Resolution"), isOn: $autoIR)
          .onChange(of: autoIR) { newValue in DOLConfigBridge.setGfxAutoIREnable(newValue) }
        NavigationLink(destination: GraphicsTargetFPSView(selected: $targetFPS)) {
          Text("\(L("Target FPS")): \(targetFPS.label)")
        }
        .onChange(of: targetFPS) { _ in DOLConfigBridge.setGfxAutoIRTargetFPS(targetFPS.fpsValue) }
        NavigationLink(destination: GraphicsMinScaleView(selected: $minScale)) {
          Text("\(L("Min Scale")): \(minScale.label)")
        }
        .onChange(of: minScale) { _ in DOLConfigBridge.setGfxAutoIRMinScale(minScale.scaleValue) }
        NavigationLink(destination: GraphicsMaxScaleView(selected: $maxScale)) {
          Text("\(L("Max Scale")): \(maxScale.label)")
        }
        .onChange(of: maxScale) { _ in DOLConfigBridge.setGfxAutoIRMaxScale(maxScale.scaleValue) }
#if os(iOS)
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
        }
#endif
      }

#if os(iOS)
      Section(header: Text(L("Recording")), footer: Text(L("Instant Replay may reduce performance; keep disabled on older devices."))) {
        Toggle(L("Enable ReplayKit Instant Replay"), isOn: $instantReplay)
          .onChange(of: instantReplay) { UserDefaults.standard.set($0, forKey: "replaykit_instant_replay_enabled") }
        Toggle(L("Save Clips to Photos"), isOn: Binding(get: { UserDefaults.standard.bool(forKey: "replaykit_save_to_photos") }, set: { UserDefaults.standard.set($0, forKey: "replaykit_save_to_photos") }))
        Toggle(L("Save Only to Photos"), isOn: Binding(get: { UserDefaults.standard.bool(forKey: "replaykit_save_only_photos") }, set: { UserDefaults.standard.set($0, forKey: "replaykit_save_only_photos") }))
        Picker(L("Clip Length"), selection: $clipSeconds) {
          Text("5s").tag(5)
          Text("10s").tag(10)
          Text("15s").tag(15)
          Text("30s").tag(30)
        }
        .onChange(of: clipSeconds) { v in UserDefaults.standard.set(v, forKey: "replaykit_clip_seconds") }
      }
#endif

      Section(header: Text(L("Shader Compilation"))) {
        NavigationLink(destination: GraphicsShaderTypeView(selected: $shaderType)) {
          Text("\(L("Type")): \(shaderType.label)")
        }
        .onChange(of: shaderType) { _ in DOLConfigBridge.setGfxShaderCompilationMode(shaderType.modeRaw) }
        Toggle(L("Compile shaders before starting"), isOn: $compileBeforeStart)
          .onChange(of: compileBeforeStart) { newValue in DOLConfigBridge.setGfxWaitForShadersBeforeStarting(newValue) }
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

enum InternalScale: CaseIterable { case x0_5, x0_75, x1_0, x1_25, x1_5, x2_0, x3_0
  var label: String { switch self {
  case .x0_5: return "0.5x"
  case .x0_75: return "0.75x"
  case .x1_0: return "1.0x"
  case .x1_25: return "1.25x"
  case .x1_5: return "1.5x"
  case .x2_0: return "2.0x"
  case .x3_0: return "3.0x"
  }}
  var scaleValue: Int { switch self { case .x0_5: return 0; case .x0_75: return 0; case .x1_0: return 1; case .x1_25: return 0; case .x1_5: return 0; case .x2_0: return 2; case .x3_0: return 3 } }
  static func from(value: Int) -> InternalScale { switch value { case 2: return .x2_0; case 3: return .x3_0; case 1: return .x1_0; default: return .x1_0 } }
}

enum ShaderCompileType: CaseIterable { case synchronous, asynchronousUber, specialized
  var label: String { switch self { case .synchronous: return L("Synchronous"); case .asynchronousUber: return L("Asynchronous (Uber)"); case .specialized: return L("Specialized") } }
  var modeRaw: Int { switch self { case .synchronous: return 0; case .asynchronousUber: return 1; case .specialized: return 2 } }
  static func from(raw: Int) -> ShaderCompileType { switch raw { case 2: return .specialized; case 1: return .asynchronousUber; default: return .synchronous } }
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
        NavigationLink(destination: EfbScalePicker(selected: $efbScale, maxScale: efbMaxScale)) {
          Text("\(L("Internal Resolution")): \(efbScale == 0 ? L("Auto") : "\(efbScale)x")")
            .overlay(alignment: .trailing) {
              Button { helpMessage = helpTextInternalResolution(); showHelp = true } label: { Image(systemName: "info.circle") }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: efbScale) { DOLConfigBridge.setGfxEfbScale($0) }
      }, header: { Text(L("Internal Resolution")) })
      Section(content: {
        NavigationLink(destination: AnisotropyPicker(selected: $anisotropy)) {
          Text("\(L("Anisotropic Filtering")): \(anisotropy)x")
            .overlay(alignment: .trailing) {
              Button { helpMessage = helpTextAnisotropy(); showHelp = true } label: { Image(systemName: "info.circle") }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: anisotropy) { DOLConfigBridge.setGfxEnhanceAnisotropySamples($0) }
      }, header: { Text(L("Texture Filtering")) })
      Section(content: {
        Toggle(isOn: $trueColor) { labelWithInfo(L("Force 24-bit Color")) { helpMessage = helpTextForceTrueColor(); showHelp = true } }
          .onChange(of: trueColor) { DOLConfigBridge.setGfxEnhanceForceTrueColor($0) }
        Toggle(isOn: $disableCopyFilter) { labelWithInfo(L("Disable Copy Filter")) { helpMessage = helpTextDisableCopyFilter(); showHelp = true } }
          .onChange(of: disableCopyFilter) { DOLConfigBridge.setGfxEnhanceDisableCopyFilter($0) }
        Toggle(isOn: $widescreenHack) { labelWithInfo(L("Widescreen Hack")) { helpMessage = helpTextWidescreenHack(); showHelp = true } }
          .onChange(of: widescreenHack) { DOLConfigBridge.setGfxWidescreenHack($0) }
        Toggle(isOn: $hdrOutput) { labelWithInfo(L("HDR Output")) { helpMessage = helpTextHDROutput(); showHelp = true } }
          .onChange(of: hdrOutput) { DOLConfigBridge.setGfxEnhanceHDROutput($0) }
        Toggle(isOn: $gpuTextureDecoding) { labelWithInfo(L("GPU Texture Decoding")) { helpMessage = L("Decodes textures on the GPU to reduce CPU load. May cause issues with some features such as Arbitrary Mipmap Detection."); showHelp = true } }
          .onChange(of: gpuTextureDecoding) { DOLConfigBridge.setGfxEnableGPUTextureDecoding($0) }
      }, header: { Text(L("Enhancements")) })
      Section(content: {
        Toggle(isOn: $disableFog) { labelWithInfo(L("Disable Fog")) { helpMessage = helpTextDisableFog(); showHelp = true } }
          .onChange(of: disableFog) { DOLConfigBridge.setGfxDisableFog($0) }
        Toggle(isOn: $arbitraryMipmapDetection) { labelWithInfo(L("Arbitrary Mipmap Detection")) { helpMessage = helpTextArbitraryMipmap(); showHelp = true } }
          .onChange(of: arbitraryMipmapDetection) { DOLConfigBridge.setGfxEnhanceArbitraryMipmapDetection($0) }
        if arbitraryMipmapDetection {
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text(L("Mipmap Detection Threshold"))
              Spacer()
              Text(String(format: "%.2f", arbitraryMipmapThreshold))
            }
#if os(tvOS)
            TVIntStepper(
              value: Binding(
                get: { Int(arbitraryMipmapThreshold * 100) },
                set: { arbitraryMipmapThreshold = Double($0) / 100.0 }
              ),
              range: 0...100,
              step: 1
            )
            .onChange(of: arbitraryMipmapThreshold) { DOLConfigBridge.setGfxEnhanceArbitraryMipmapDetectionThreshold(Float($0)) }
#else
            Slider(value: $arbitraryMipmapThreshold, in: 0.0...1.0, step: 0.01)
              .onChange(of: arbitraryMipmapThreshold) { DOLConfigBridge.setGfxEnhanceArbitraryMipmapDetectionThreshold(Float($0)) }
#endif
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
    L("Controls the rendering resolution.\n\nA high resolution greatly improves visual quality, but also greatly increases GPU load and can cause issues in certain games. Generally speaking, the lower the internal resolution, the better performance will be.\n\nIf unsure, select Native.")
  }
  private func helpTextAnisotropy() -> String {
    L("Adjust the texture filtering. Anisotropic filtering enhances the visual quality of textures that are at oblique viewing angles. Force Nearest and Force Linear override the texture scaling filter selected by the game.\n\nAny option except 'Default' will alter the look of the game's textures and might cause issues in a small number of games.\n\nIf unsure, select 'Default'.")
  }
  private func helpTextDisableFog() -> String {
    L("Makes distant objects more visible by removing fog, thus increasing the overall detail.\n\nDisabling fog will break some games which rely on proper fog emulation.\n\nIf unsure, leave this unchecked.")
  }
  private func helpTextDisableCopyFilter() -> String {
    L("Disables the blending of adjacent rows when copying the EFB. This is known in some games as \"deflickering\" or \"smoothing\".\n\nDisabling the filter has no effect on performance, but may result in a sharper image. Causes few graphical issues.\n\nIf unsure, leave this checked.")
  }
  private func helpTextWidescreenHack() -> String {
    L("Forces the game to output graphics for any aspect ratio. Use with \"Aspect Ratio\" set to \"Force 16:9\" to force 4:3-only games to run at 16:9.\n\nRarely produces good results and often partially breaks graphics and game UIs. Unnecessary (and detrimental) if using any AR/Gecko-code widescreen patches.\n\nIf unsure, leave this unchecked.")
  }
  private func helpTextForceTrueColor() -> String {
    L("Forces the game to render the RGB color channels in 24-bit, thereby increasing quality by reducing color banding.\n\nHas no impact on performance and causes few graphical issues.\n\nIf unsure, leave this checked.")
  }
  private func helpTextArbitraryMipmap() -> String {
    L("Enables detection of arbitrary mipmaps, which some games use for special distance-based effects.\n\nMay have false positives that result in blurry textures at increased internal resolution, such as in games that use very low resolution mipmaps. Disabling this can also reduce stutter in games that frequently load new textures. This feature is not compatible with GPU Texture Decoding.\n\nIf unsure, leave this checked.")
  }
  private func helpTextHDROutput() -> String {
    L("Enables HDR output on supported displays. May improve perceived dynamic range and color on HDR-capable devices.")
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
  @State private var noMipmapping: Bool = false
  @State private var earlyXfbOutput: Bool = true
  @State private var skipDuplicateXFBs: Bool = true
  var body: some View {
    List {
      Section(header: Text(L("General Hacks"))) {
        Toggle(L("Enable EFB Access"), isOn: $efbAccess).onChange(of: efbAccess) { DOLConfigBridge.setGfxHackEfbAccessEnable($0) }
        Toggle(L("Skip EFB Copy to RAM"), isOn: $skipEfbToRam).onChange(of: skipEfbToRam) { DOLConfigBridge.setGfxHackSkipEfbCopyToRam($0) }
        Toggle(L("Skip XFB Copy to RAM"), isOn: $skipXfbToRam).onChange(of: skipXfbToRam) { DOLConfigBridge.setGfxHackSkipXfbCopyToRam($0) }
        Toggle(L("Immediate XFB"), isOn: $immediateXfb).onChange(of: immediateXfb) { DOLConfigBridge.setGfxHackImmediateXfb($0) }
        Toggle(L("Copy EFB Scaled"), isOn: $copyEfbScaled).onChange(of: copyEfbScaled) { DOLConfigBridge.setGfxHackCopyEfbScaled($0) }
        Toggle(L("Early XFB Output"), isOn: $earlyXfbOutput).onChange(of: earlyXfbOutput) { DOLConfigBridge.setGfxHackEarlyXfbOutput($0) }
        Toggle(L("Skip Duplicate XFBs"), isOn: $skipDuplicateXFBs).onChange(of: skipDuplicateXFBs) { DOLConfigBridge.setGfxHackSkipDuplicateXFBs($0) }
        Toggle(L("Emulate EFB Format Changes"), isOn: $efbFormatChanges).onChange(of: efbFormatChanges) { DOLConfigBridge.setGfxHackEfbEmulateFormatChanges($0) }
        Toggle(L("Vertex Rounding"), isOn: $vertexRounding).onChange(of: vertexRounding) { DOLConfigBridge.setGfxHackVertexRounding($0) }
        Toggle(L("Force Progressive Scan"), isOn: $forceProgressive).onChange(of: forceProgressive) { DOLConfigBridge.setGfxHackForceProgressive($0) }
        Toggle(L("Defer EFB Copies"), isOn: $deferEfbCopies).onChange(of: deferEfbCopies) { DOLConfigBridge.setGfxHackDeferEfbCopies($0) }
        NavigationLink("\(L("VI Skip Mode")): \(viSkipLabel(viSkipMode))", destination: ViSkipModePicker(selected: $viSkipMode))
          .onChange(of: viSkipMode) { DOLConfigBridge.setGfxHackViSkipMode($0) }
        Toggle(L("Fast Texture Sampling"), isOn: $fastTextureSampling).onChange(of: fastTextureSampling) { DOLConfigBridge.setGfxHackFastTextureSampling($0) }
        Toggle(L("Fast Math (Metal Shaders)"), isOn: $fastMath).onChange(of: fastMath) { DOLConfigBridge.setGfxHackFastMath($0) }
        /// Compute path for EFB/XFB; may improve performance but can break some games
        Toggle(L("Use Compute for EFB/XFB"), isOn: $useComputeEfbXfb).onChange(of: useComputeEfbXfb) { DOLConfigBridge.setGfxUseComputeEfbXfb($0) }
        Toggle(L("No Mipmapping (iOS)"), isOn: $noMipmapping).onChange(of: noMipmapping) { DOLConfigBridge.setGfxHackNoMipmapping($0) }
      }
    }
    .navigationTitle(L("Hacks"))
    .onAppear { sync() }
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
    noMipmapping = DOLConfigBridge.gfxHackNoMipmapping()
  }
  private func viSkipLabel(_ v: Int) -> String { switch v { case 1: return L("On"); case 2: return L("Auto"); default: return L("Off") } }
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
      Section(header: Text(L("Performance Statistics")), footer: Text(L("Performance overlays can also be toggled during gameplay using the in-game menu (pause during emulation). These overlays help monitor performance and identify bottlenecks."))) {
        Toggle(L("Show FPS"), isOn: $showFPS).onChange(of: showFPS) { _ in DOLConfigBridge.setGfxShowFPS(showFPS) }
        Toggle(L("Show VPS"), isOn: $showVPS).onChange(of: showVPS) { _ in DOLConfigBridge.setGfxShowVPS(showVPS) }
        Toggle(L("Show Speed"), isOn: $showSpeed).onChange(of: showSpeed) { _ in DOLConfigBridge.setGfxShowSpeed(showSpeed) }
        Toggle(L("Show Frame Times"), isOn: $showFrameTimes).onChange(of: showFrameTimes) { _ in DOLConfigBridge.setGfxShowFTimes(showFrameTimes) }
        Toggle(L("Show VBlank Times"), isOn: $showVBlankTimes).onChange(of: showVBlankTimes) { _ in DOLConfigBridge.setGfxShowVTimes(showVBlankTimes) }
        Toggle(L("Show Graphs"), isOn: $showGraphs).onChange(of: showGraphs) { _ in DOLConfigBridge.setGfxShowGraphs(showGraphs) }
        Toggle(L("Log Render Time to File"), isOn: $logRenderTime).onChange(of: logRenderTime) { _ in DOLConfigBridge.setGfxLogRenderTimeToFile(logRenderTime) }
        Toggle(L("Speed Colors"), isOn: $speedColors).onChange(of: speedColors) { _ in DOLConfigBridge.setGfxShowSpeedColors(speedColors) }
      }

      Section(header: Text(L("Debugging")), footer: Text(L("Developer tools for troubleshooting graphics issues. Overlay Stats shows detailed rendering information. API Validation Layer enables extra error checking (reduces performance)."))) {
        Toggle(L("Overlay Stats"), isOn: $overlayStats).onChange(of: overlayStats) { _ in DOLConfigBridge.setGfxOverlayStats(overlayStats) }
        Toggle(L("API Validation Layer"), isOn: $validationLayer).onChange(of: validationLayer) { _ in DOLConfigBridge.setGfxEnableValidationLayer(validationLayer) }
      }

      Section(header: Text(L("Shader Threads")), footer: Text(L("Adjust how many CPU threads are used for compiling shaders. More threads can reduce stuttering but may increase CPU usage. Recommended: 2-4 threads on most devices."))) {
        HStack {
          Text(L("Compiler Threads"))
          Spacer()
#if os(tvOS)
          TVIntStepper(value: $compilerThreads, range: 1...maxThreads, step: 1)
#else
          Stepper(value: $compilerThreads, in: 1...maxThreads) { Text("\(compilerThreads)") }
#endif
        }
        .onChange(of: compilerThreads) { v in DOLConfigBridge.setGfxShaderCompilerThreads(v) }
        HStack {
          Text(L("Precompiler Threads"))
          Spacer()
#if os(tvOS)
          TVIntStepper(value: $precompilerThreads, range: 1...maxThreads, step: 1)
#else
          Stepper(value: $precompilerThreads, in: 1...maxThreads) { Text("\(precompilerThreads)") }
#endif
        }
        .onChange(of: precompilerThreads) { v in DOLConfigBridge.setGfxShaderPrecompilerThreads(v) }
      }

      Section(header: Text(L("Utility")), footer: Text(L("Custom Textures: Load high-resolution texture packs for enhanced visuals. Prefetch loads them into memory for better performance. Graphics Mods enable community-created visual enhancements."))) {
        Toggle(L("Load Custom Textures"), isOn: $hiresTextures).onChange(of: hiresTextures) { _ in DOLConfigBridge.setGfxHiresTextures(hiresTextures) }
        Toggle(L("Prefetch Custom Textures"), isOn: $prefetchTextures)
          .disabled(!hiresTextures)
          .onChange(of: prefetchTextures) { _ in DOLConfigBridge.setGfxCacheHiresTextures(prefetchTextures) }
        Toggle(L("Disable EFB Copy to VRAM"), isOn: $disableEfbToVRAM).onChange(of: disableEfbToVRAM) { _ in DOLConfigBridge.setGfxHackDisableCopyToVRAM(disableEfbToVRAM) }
        Toggle(L("Enable Graphics Mods"), isOn: $graphicsMods).onChange(of: graphicsMods) { _ in DOLConfigBridge.setGfxModsEnable(graphicsMods) }
      }

      Section(header: Text(L("Misc")), footer: Text(L("Crop: Removes black borders from some games. Progressive Scan: Enables progressive scan mode for supported games (reduces flickering)."))) {
        Toggle(L("Crop"), isOn: $cropPicture).onChange(of: cropPicture) { _ in DOLConfigBridge.setGfxCrop(cropPicture) }
        Toggle(L("Progressive Scan"), isOn: $progressiveScan).onChange(of: progressiveScan) { _ in DOLConfigBridge.setSysconfProgressiveScan(progressiveScan) }
      }

      Section(header: Text(L("Rendering")), footer: Text(L("Advanced rendering options that affect performance and compatibility. Fast Depth improves speed but may cause issues. Per-Pixel Lighting enhances visual quality at performance cost."))) {
        Toggle(L("Fast Depth Calculation"), isOn: $fastDepth).onChange(of: fastDepth) { DOLConfigBridge.setGfxFastDepthCalc($0) }
        Toggle(L("Per-Pixel Lighting"), isOn: $pixelLighting).onChange(of: pixelLighting) { DOLConfigBridge.setGfxEnablePixelLighting($0) }
        Toggle(L("Backend Multithreading"), isOn: $backendMT).onChange(of: backendMT) { DOLConfigBridge.setGfxBackendMultithreading($0) }
        Toggle(L("Enable Shader Cache"), isOn: $shaderCache).onChange(of: shaderCache) { DOLConfigBridge.setGfxShaderCache($0) }
        Toggle(L("Save Texture Cache to State"), isOn: $saveTexCache).onChange(of: saveTexCache) { DOLConfigBridge.setGfxSaveTextureCacheToState($0) }
        Toggle(L("Prefer Vertex Shader for Line/Point Expansion"), isOn: $preferVSForLines).onChange(of: preferVSForLines) { DOLConfigBridge.setGfxPreferVSForLinePointExpansion($0) }
        Toggle(L("CPU Culling"), isOn: $cpuCull).onChange(of: cpuCull) { DOLConfigBridge.setGfxCpuCull($0) }
      }

      Section(header: Text(L("Experimental")), footer: Text(L("⚠️ These settings are experimental and may cause instability, graphical glitches, or crashes in some games. Use with caution."))) {
        Toggle(L("Defer EFB Cache Invalidation"), isOn: $deferEfbInvalidation).onChange(of: deferEfbInvalidation) { _ in DOLConfigBridge.setGfxHackEfbDeferInvalidation(deferEfbInvalidation) }
        // Manual Texture Sampling is the inverse of Fast Texture Sampling
        Toggle(L("Manual Texture Sampling"), isOn: $manualTexSampling).onChange(of: manualTexSampling) { _ in DOLConfigBridge.setGfxHackFastTextureSampling(!manualTexSampling) }
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

private struct ControllersMappingPlaceholder: View {
  var body: some View {
    List { Text(L("TODO: Mapping")) }
      .navigationTitle(L("Configure"))
  }
}

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
      Section(header: Text(L("Motion IR Cursor")), footer: Text(L("Control method for Wiimote IR pointer. Gyro mode uses device motion for enhanced precision. Configure motion-specific settings when gyro is active."))) {
        NavigationLink(L("IR Control Method"), destination: TouchIRModePicker(selected: $currentIRMode))
          .onChange(of: currentIRMode) { mode in
            DOLConfigBridge.setMainTouchPadIRMode(mode.rawValue)
            notifyMotionSettingsChanged()
          }

        if currentIRMode == .gyro {
          NavigationLink(L("Horizontal Movement"), destination: HorizontalMotionPicker(selected: $horizontalMotionMode))
            .onAppear { syncHorizontalMode() }
            .onChange(of: horizontalMotionMode) { mode in
              useYawForHorizontal = (mode == .yaw)
            }

          Toggle(L("Invert Horizontal (Left/Right)"), isOn: $invertRoll)

          Toggle(L("Invert Vertical (Up/Down)"), isOn: $invertPitch)
        }
      }

      Section(header: Text(L("Shake Detection")), footer: Text(L("Modern algorithm analyzes motion patterns to detect shake gestures more reliably than the basic shake detection. Replaces Dolphin's built-in shake detection with improved sensitivity and accuracy."))) {
        Toggle(L("Enable Advanced Shake Detection"), isOn: $enhancedShakeEnabled)
      }

      Section(header: Text(L("Full Motion Mapping")), footer: Text(L("Maps device motion to all 6 degrees of freedom (3-axis rotation + 3-axis acceleration). Only active when IR control is not using gyro mode. Enables motion-controlled games like Wii Sports, Mario Kart steering, etc."))) {
        Toggle(L("Enable 6DOF Motion Controls"), isOn: $fullMotionEnabled)

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
    if #available(iOS 16.0, *) {
      content.scrollContentBackground(.hidden)
    } else {
      content
    }
  }
}
#endif
