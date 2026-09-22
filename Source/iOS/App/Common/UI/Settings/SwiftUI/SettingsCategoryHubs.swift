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

struct ConfigRootView: View {
  var body: some View {
    List {
      NavigationLink(destination: ConfigGeneralView()) {
        Label(L("General"), systemImage: "gear")
      }
      NavigationLink(destination: PerformanceTuningView()) {
        Label(L("Performance Tuning"), systemImage: "gauge.with.dots.needle.67percent")
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
