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
    .configSynced { syncGC() }
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
        SettingsSelectRow(label: label(v), checked: v == selected) { selected = v; DOLConfigBridge.setMainGCLanguage(v) }
      }
    }
    .navigationTitle(L("System Language"))
  }
  private func label(_ v: Int) -> String {
    switch v { case 0: return L("English"); case 1: return L("German"); case 2: return L("French"); case 3: return L("Spanish"); case 4: return L("Italian"); case 5: return L("Dutch"); default: return L("Error") }
  }
}
/// Wii config placeholder
