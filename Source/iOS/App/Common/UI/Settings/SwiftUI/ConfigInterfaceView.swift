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
    .configSynced { sync() }
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
