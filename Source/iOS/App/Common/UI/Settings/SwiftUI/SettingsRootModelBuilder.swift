// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

struct SettingsLeafEntry: Identifiable, Hashable {
  let id: String
  let title: String
  let icon: String
  let description: String
  let keywords: [String]
  let hostsMenuScreen: Bool
  let makeView: () -> AnyView
  let makeModel: (() -> MenuModel)?

  init(id: String, title: String, icon: String, description: String, keywords: [String] = [],
       hostsMenuScreen: Bool = false, makeModel: (() -> MenuModel)? = nil,
       @ViewBuilder view: @escaping () -> some View) {
    self.id = id
    self.title = title
    self.icon = icon
    self.description = description
    self.keywords = keywords
    self.hostsMenuScreen = hostsMenuScreen
    self.makeModel = makeModel
    self.makeView = { AnyView(view()) }
  }

  /// What iPhone push and search results show. A leaf that is not itself a `MenuScreen` has no pad Back,
  /// so a pad that pushed it could never leave it (see `PadBackNavigation`).
  func pushedView() -> AnyView {
    hostsMenuScreen ? makeView() : AnyView(makeView().padBackNavigation())
  }

  static func == (lhs: SettingsLeafEntry, rhs: SettingsLeafEntry) -> Bool { lhs.id == rhs.id }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct SettingsRootSection: Identifiable {
  let id: String
  let header: String
  let entries: [SettingsLeafEntry]
}

/// Spec §6.2: eight sections. Every leaf is one row; migrated leaves also expose their model so search
/// can see their rows. `isIOS`/`achievements` replace the `#if`s the old root had.
enum SettingsRootModelBuilder {
  static func sections(isIOS: Bool, achievements: Bool) -> [SettingsRootSection] {
    var consoles = [
      SettingsLeafEntry(id: "console-gamecube", title: L("GameCube"), icon: "cube", description: L("Memory cards, slots and GameCube-only options."),
                        hostsMenuScreen: true,
                        makeModel: { ConfigGameCubeModelBuilder.make(state: ConfigGameCubeState(), apply: { _ in }) }) { ConfigGameCubeView() },
      SettingsLeafEntry(id: "console-wii", title: L("Wii"), icon: "tv.and.hifispeaker.fill", description: L("System language, aspect, SD card and Wii-only options."),
                        hostsMenuScreen: true,
                        makeModel: { ConfigWiiModelBuilder.make(state: ConfigWiiState(), apply: { _ in }) }) { ConfigWiiView() },
    ]
    // ConfigAchievementsView only exists under this flag; the `achievements` argument alone would not compile without it.
    #if USE_RETRO_ACHIEVEMENTS
    if achievements {
      consoles.append(SettingsLeafEntry(id: "achievements", title: L("Achievements"), icon: "trophy", description: L("RetroAchievements sign-in and hardcore mode.")) { ConfigAchievementsView() })
    }
    #endif
    return [
      SettingsRootSection(id: "general", header: L("General"), entries: [
        SettingsLeafEntry(id: "general", title: L("General"), icon: "gear", description: L("Dual core, cheats, speed limit and other core options."),
                          hostsMenuScreen: true,
                          makeModel: { ConfigGeneralModelBuilder.make(state: ConfigGeneralState(), apply: { _ in }) }) { ConfigGeneralView() },
        SettingsLeafEntry(id: "interface", title: L("Interface"), icon: "menubar.rectangle", description: L("On-screen messages, confirmations and panic handling."),
                          hostsMenuScreen: true,
                          makeModel: { ConfigInterfaceModelBuilder.make(state: ConfigInterfaceState(), apply: { _ in }) }) { ConfigInterfaceView() },
        SettingsLeafEntry(id: "advanced", title: L("Advanced"), icon: "cpu", description: L("Clock overrides and other expert options."),
                          hostsMenuScreen: true,
                          makeModel: { ConfigAdvancedModelBuilder.make(state: ConfigAdvancedState(), apply: { _ in }) }) { ConfigAdvancedView() },
      ]),
      SettingsRootSection(id: "graphics", header: L("Graphics"), entries: [
        SettingsLeafEntry(id: "graphics-video", title: L("Video"), icon: "display",
                          description: L("Backend, aspect ratio, V-Sync, auto resolution and shader compilation."),
                          hostsMenuScreen: true,
                          makeModel: { GraphicsGeneralModelBuilder.make(state: GraphicsGeneralState(isIOS: isIOS), apply: { _ in }) }) { GraphicsGeneralView() },
        SettingsLeafEntry(id: "graphics-enhancements", title: L("Enhancements"), icon: "sparkles",
                          description: L("Internal resolution, anti-aliasing, filtering and colour."),
                          hostsMenuScreen: true,
                          makeModel: { GraphicsEnhancementsModelBuilder.make(state: GraphicsEnhancementsState(), apply: { _ in }) }) { GraphicsEnhancementsView() },
        SettingsLeafEntry(id: "graphics-hacks", title: L("Hacks"), icon: "wrench.and.screwdriver",
                          description: L("Speed-for-accuracy trade-offs in the GPU pipeline."),
                          hostsMenuScreen: true,
                          makeModel: { GraphicsHacksModelBuilder.make(state: GraphicsHacksState(), apply: { _ in }) }) { GraphicsHacksView() },
        SettingsLeafEntry(id: "graphics-advanced", title: L("Graphics Advanced"), icon: "slider.horizontal.3",
                          description: L("Metal presentation and buffer upload options."),
                          keywords: ["present drawable", "manually upload buffers", "metal"]) { GraphicsAdvancedView() },
        SettingsLeafEntry(id: "shaders", title: L("Shaders"), icon: "paintbrush", description: L("Post-processing presets and their parameters.")) { ShaderSettingsView() },
      ]),
      SettingsRootSection(id: "audio", header: L("Audio"), entries: [
        SettingsLeafEntry(id: "audio", title: L("Audio"), icon: "speaker.wave.3", description: L("Volume, DSP engine, stretching and effects."),
                          hostsMenuScreen: true,
                          makeModel: { ConfigAudioModelBuilder.make(state: ConfigAudioState(), apply: { _ in }) }) { ConfigAudioView() },
      ]),
      SettingsRootSection(id: "consoles", header: L("GameCube & Wii"), entries: consoles),
      SettingsRootSection(id: "controllers", header: L("Controllers"), entries: [
        // ControllersRootView embeds ControllerHubView (a MenuScreen), so it handles pad Back itself.
        SettingsLeafEntry(id: "controllers", title: L("Controllers"), icon: "gamecontroller",
                          description: L("Players, devices, what each plays as, and remapping."),
                          hostsMenuScreen: true) { ControllersRootView() },
      ]),
      SettingsRootSection(id: "performance", header: L("Performance"), entries: [
        SettingsLeafEntry(id: "performance-tuning", title: L("Performance Tuning"), icon: "gauge.with.dots.needle.67percent",
                          description: L("CPU engine, optimisations, clock overrides. The CPU is the bottleneck on iCube."),
                          hostsMenuScreen: true,
                          // showValidation: true so the correctness-validation rows are searchable.
                          makeModel: { PerformanceTuningModelBuilder.make(state: PerformanceTuningState(), showValidation: true, apply: { _ in }) }) { PerformanceTuningView() },
        SettingsLeafEntry(id: "debug", title: L("Debug"), icon: "ladybug", description: L("Developer switches: fastmem, JIT, logging, stall metrics."),
                          keywords: ["fastmem", "jit", "logging", "stall metrics", "wireframe", "haptics"]) { DebugRootView() },
      ]),
      SettingsRootSection(id: "sync-network", header: L("Sync & Network"), entries: [
        SettingsLeafEntry(id: "web-ui", title: L("Web UI & WebDAV"), icon: "network", description: L("Import games from a computer on the same Wi-Fi.")) { WebUISettingsView() },
        SettingsLeafEntry(id: "icloud", title: L("iCloud Sync"), icon: "icloud", description: L("Sync saves, states and settings across your devices.")) { CloudSyncSettingsView() },
        SettingsLeafEntry(id: "nearby", title: L("Nearby Devices"), icon: "antenna.radiowaves.left.and.right", description: L("Continue a game from another device, and manage paired ones.")) { ContinuityBrowseView() },
      ]),
      SettingsRootSection(id: "about", header: L("About"), entries: [
        SettingsLeafEntry(id: "about", title: L("About"), icon: "info.circle", description: L("Version, core, blog, help and Reset All Settings.")) { AboutView() },
      ]),
    ]
  }

  /// The root as one `MenuModel`: a chevron row per leaf. The iPhone list renders it; the sidebar renders `sections` directly.
  /// Rows stay `.action` (not `.destination`) because the sidebar must select a leaf into its pane instead of pushing it.
  static func model(sections: [SettingsRootSection], onSelect: @escaping (SettingsLeafEntry) -> Void) -> MenuModel {
    MenuModel(sections: sections.map { section in
      MenuSection(id: section.id, header: section.header, items: section.entries.map { entry in
        MenuItem(id: entry.id, title: entry.title, icon: entry.icon, role: .action { onSelect(entry) },
                 description: entry.description, showsChevron: true)
      })
    })
  }
}
