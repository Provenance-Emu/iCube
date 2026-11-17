// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The rules for the Mac app's menu-bar item: what happens when the last window closes and what the
/// menu shows. Free of UIKit and AppKit so the rules are tested on every platform; only the Mac
/// build (`MacDesktopController`) acts on them.
enum DesktopPresence {
  /// On by default: a desktop install is the natural always-on host for library sharing.
  static let keepRunningDefaultsKey = "mac_keep_running_in_menu_bar"

  enum AfterLastWindowCloses: Equatable {
    case stayInMenuBar
    case quit
  }

  /// A running game has nowhere to draw without its window, so it ends with the app, as it did
  /// before the app could outlive its window. Without a menu-bar item there is no way back to a
  /// windowless app, so that quits too.
  static func afterLastWindowCloses(keepRunning: Bool, gameRunning: Bool, hasMenuBarItem: Bool) -> AfterLastWindowCloses {
    keepRunning && hasMenuBarItem && !gameRunning ? .stayInMenuBar : .quit
  }

  /// macOS slows a windowless app down (App Nap). That only matters while other devices can ask
  /// this one for games.
  static func needsBackgroundActivity(sharingLibrary: Bool) -> Bool {
    sharingLibrary
  }

  enum MenuAction: Equatable {
    case openWindow
    case toggleSharing
    case toggleKeepRunning
    case quit
  }

  enum MenuRow: Equatable {
    case separator
    /// Text only; cannot be chosen.
    case status(String)
    case action(MenuAction, title: String, checked: Bool)
  }

  static func menu(sharingLibrary: Bool, keepRunning: Bool) -> [MenuRow] {
    [
      .action(.openWindow, title: L("Open iCube"), checked: false),
      .separator,
      .status(sharingLibrary ? L("Sharing your library on the local network") : L("Library sharing is off")),
      .action(.toggleSharing, title: L("Share Library on Local Network"), checked: sharingLibrary),
      .action(.toggleKeepRunning, title: L("Keep Running When the Window Is Closed"), checked: keepRunning),
      .separator,
      .action(.quit, title: L("Quit iCube"), checked: false),
    ]
  }
}
