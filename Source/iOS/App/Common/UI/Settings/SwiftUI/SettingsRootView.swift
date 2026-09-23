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

  init(backgroundView: Background? = nil) {
    self.backgroundView = backgroundView
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

      settingsContent
    }
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DOLSettingsSelectControllers"))) { _ in
      jumpToControllersRequested = true
    }
    .task {
      await refreshLightweightInfo()
    }
  }

  /// Set by the `DOLSettingsSelectControllers` deep link (posted after adding a DSU
  /// server via a `dolphinios://dsu/add` or legacy `dsu://` URL) so Settings opens
  /// straight into Controllers instead of leaving the user to find it in the list.
  @State private var jumpToControllersRequested = false
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

  /// One row in the flattened root list. `destination` is type-erased because the
  /// row array below mixes ~15 unrelated destination view types; with a fixed, small
  /// row count this is simpler than threading generics through, and it's what makes
  /// the list filterable by `.searchable` below (a static tree of `NavigationLink`s
  /// can't be filtered without either this or duplicating every row behind an `if`).
  private struct SettingsEntry: Identifiable {
    /// Derived, not `UUID()` — `settingsSections` below is a computed property, so a
    /// fresh UUID per row on every `body` evaluation would churn `ForEach` identity
    /// on every re-render (e.g. `refreshLightweightInfo()`'s polling `@State` writes,
    /// or every keystroke in the search field), tearing down and rebuilding rows and
    /// popping an open destination back to the list. Titles are unique per section.
    var id: String { title }
    let title: String
    let icon: String
    let accessibilityLabel: String?
    /// Extra terms this row should also match on when searching (iOS only — see
    /// `filteredSettingsSections`), for settings that live a level down and whose
    /// name alone wouldn't surface the page (e.g. searching "vsync" should find
    /// Hacks). Deliberately sparse: only the pages with the deepest/least
    /// discoverable settings get keywords; this is not full-page content indexing.
    let keywords: [String]
    let destination: AnyView

    init(title: String, icon: String, accessibilityLabel: String? = nil, keywords: [String] = [], @ViewBuilder destination: () -> some View) {
      self.title = title
      self.icon = icon
      self.accessibilityLabel = accessibilityLabel
      self.keywords = keywords
      self.destination = AnyView(destination())
    }
  }

  private struct SettingsListSection: Identifiable {
    /// Derived, not `UUID()` — see `SettingsEntry.id`. The six headers are unique.
    var id: String { header }
    let header: String
    let entries: [SettingsEntry]
  }

  /// The root list, restructured (WS-6) into ~15 specific destinations grouped under
  /// a handful of headers, instead of the previous 5 broad hubs (Config/Graphics/...)
  /// that each hid their own sub-list. Matches Provenance's long-scroll-with-many-
  /// sections shape (`SettingsSwiftUI.swift`) rather than iFly's tabbed sidebar —
  /// see the WS-6 report for why. "Config"/"Graphics" as navigation hubs are gone
  /// from here in favor of their individual rows below (General/Interface/Advanced,
  /// Video/Enhancements/Hacks/…), each linking straight to its own destination view.
  private var settingsSections: [SettingsListSection] {
    let generalSection: [SettingsEntry] = [
      SettingsEntry(title: L("General"), icon: "gear", accessibilityLabel: L("Config Settings")) { ConfigGeneralView() },
      SettingsEntry(title: L("Performance Tuning"), icon: "gauge.with.dots.needle.67percent", keywords: ["cpu", "interpreter", "cached interpreter", "jit", "speed limit", "fast forward"]) { PerformanceTuningView() },
      SettingsEntry(title: L("Interface"), icon: "menubar.rectangle") { ConfigInterfaceView() },
      SettingsEntry(title: L("Advanced"), icon: "cpu") { ConfigAdvancedView() },
    ]
    let audioSection: [SettingsEntry] = [
      SettingsEntry(title: L("Audio"), icon: "speaker.wave.3") { ConfigAudioView() },
    ]
    var consolesSection: [SettingsEntry] = [
      SettingsEntry(title: L("GameCube"), icon: "cube") { ConfigGameCubeView() },
      SettingsEntry(title: L("Wii"), icon: "tv.and.hifispeaker.fill") { ConfigWiiView() },
    ]
    #if USE_RETRO_ACHIEVEMENTS
    consolesSection.append(SettingsEntry(title: L("Achievements"), icon: "trophy") { ConfigAchievementsView() })
    #endif
    let graphicsSection: [SettingsEntry] = [
      SettingsEntry(title: L("Video"), icon: "display", accessibilityLabel: L("Graphics Settings")) { GraphicsGeneralView() },
      SettingsEntry(title: L("Enhancements"), icon: "sparkles", keywords: ["anisotropic", "anisotropy", "msaa", "anti-aliasing", "resampling", "efb scale", "internal resolution"]) { GraphicsEnhancementsView() },
      SettingsEntry(title: L("Hacks"), icon: "wrench.and.screwdriver", keywords: ["texture cache", "vsync", "v-sync", "bbox", "vi skip", "efb"]) { GraphicsHacksView() },
      SettingsEntry(title: L("Graphics Advanced"), icon: "slider.horizontal.3", keywords: ["present drawable", "manually upload buffers", "metal"]) { GraphicsAdvancedView() },
      SettingsEntry(title: L("Shaders"), icon: "paintbrush") { ShaderSettingsView() },
    ]
    let inputSection: [SettingsEntry] = [
      SettingsEntry(title: L("Controllers"), icon: "gamecontroller") { ControllersRootView() },
    ]
    let systemSection: [SettingsEntry] = [
      SettingsEntry(title: L("Debug"), icon: "ladybug", keywords: ["fastmem", "jit", "logging", "stall metrics", "wireframe", "haptics"]) { DebugRootView() },
    ]
    return [
      SettingsListSection(header: L("General"), entries: generalSection),
      SettingsListSection(header: L("Audio"), entries: audioSection),
      SettingsListSection(header: L("GameCube & Wii"), entries: consolesSection),
      SettingsListSection(header: L("Graphics"), entries: graphicsSection),
      SettingsListSection(header: L("Input"), entries: inputSection),
      SettingsListSection(header: L("System"), entries: systemSection),
    ]
  }

#if os(iOS)
  /// Full-text search, iOS/iPadOS only — deliberately absent on tvOS. tvOS remote
  /// text entry is slower than just flipping through a dozen rows with the D-pad;
  /// iFly's SettingsView+Search.swift makes the same call for the same reason, and
  /// the WS-6 plan calls it worth copying. Filters the flattened list in place
  /// rather than jumping between tabs (iFly's approach), since after WS-6 there's
  /// only the one list to filter.
  @State private var settingsSearchText: String = ""
#endif

  private var filteredSettingsSections: [SettingsListSection] {
#if os(iOS)
    let query = settingsSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return settingsSections }
    return settingsSections.compactMap { section in
      let matches = section.entries.filter { entry in
        entry.title.localizedCaseInsensitiveContains(query)
          || entry.keywords.contains { $0.localizedCaseInsensitiveContains(query) }
      }
      return matches.isEmpty ? nil : SettingsListSection(header: section.header, entries: matches)
    }
#else
    return settingsSections
#endif
  }

  @ViewBuilder
  private var settingsContent: some View {
    NavigationStack {
      List {
        ForEach(filteredSettingsSections) { section in
          Section(header: Text(section.header)) {
            ForEach(section.entries) { entry in
              NavigationLink(destination: entry.destination) {
                if let a11y = entry.accessibilityLabel {
                  Label(entry.title, systemImage: entry.icon).accessibilityLabel(a11y)
                } else {
                  Label(entry.title, systemImage: entry.icon)
                }
              }
            }
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
          // iCloud sync of everything except ROMs. Everything about it lives
          // in CloudSyncSettingsView; this is only the way in.
          NavigationLink(destination: CloudSyncSettingsView()) {
            HStack {
              Label(L("iCloud Sync"), systemImage: "icloud")
              Spacer()
              SyncStatusIndicator()
            }
          }
          // The receiving side of handoff, and where paired devices are
          // reviewed and forgotten. Its own row rather than controls inline,
          // so tvOS can focus it.
          NavigationLink(destination: ContinuityBrowseView()) {
            Label(L("Nearby Devices"), systemImage: "antenna.radiowaves.left.and.right")
          }
        }
      }
      .navigationTitle(L("Settings"))
#if os(iOS)
      .searchable(text: $settingsSearchText, prompt: L("Search Settings"))
#endif
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button(L("Reset All")) { showGlobalResetAlert = true }
        }
      }
      // DSU-add deep link (dolphinios://dsu/add, legacy dsu://) jumps straight here
      // instead of leaving the user to find Controllers in the flattened list.
      .navigationDestination(isPresented: $jumpToControllersRequested) {
        ControllersRootView()
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
  }
}
