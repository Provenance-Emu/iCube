// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SwiftUI
import UIKit

/// What draws the on-screen controller on the SwiftUI side.
enum OverlayChoice: Equatable {
  /// The Swift-drawn overlay (or, with its flag off, the xib pads).
  case programmatic
  /// An imported skin.
  case skin(InstalledSkin)

  var skinID: String? {
    if case .skin(let skin) = self { return skin.id }
    return nil
  }
}

/// Posted when a skin's Menu, Quick Save or Quick Load item is touched. The game screen owns the pause
/// menu and the save slot, and observes this instead of taking a closure so the on-screen controller's
/// container keeps plain-value inputs (a closure would make SwiftUI update it on every screen redraw).
enum SkinActionNotification {
  static let name = Notification.Name("DOLSkinActionNotification")
  private static let actionKey = "action"

  static func post(_ action: SkinAction) {
    NotificationCenter.default.post(name: name, object: nil, userInfo: [actionKey: action])
  }

  static func action(in notification: Notification) -> SkinAction? {
    notification.userInfo?[actionKey] as? SkinAction
  }
}

/// The pure decisions behind putting a skin into the game screen: which overlay to mount, where the
/// game picture goes, and how it fits.
@MainActor
enum SkinMount {
  private static let infoFileName = "info.json"
  private static var infoCache: [URL: (modified: Date?, info: SkinInfo)] = [:]

  /// The skin the player picked for this pad kind and orientation, or `.programmatic` when there is none, its files are
  /// gone, or it has no layout for this device and orientation. Read-only: it runs while the game screen draws, where
  /// publishing a library change would be a view-update violation (`forgetDeadSelections` clears dead picks).
  static func overlayChoice(padKind: TouchOverlayPadKind, orientation: TouchOverlayOrientation, library: SkinLibrary,
                            isPad: Bool = UIDevice.current.userInterfaceIdiom == .pad) -> OverlayChoice {
    guard let skin = library.selectedSkin(for: padKind, orientation: orientation),
          info(for: skin) != nil,
          supports(skin, orientation: orientation, isPad: isPad) else { return .programmatic }
    return .skin(skin)
  }

  /// Whether `skin` declares a layout this device can draw in `orientation`.
  static func supports(_ skin: InstalledSkin, orientation: TouchOverlayOrientation,
                       isPad: Bool = UIDevice.current.userInterfaceIdiom == .pad) -> Bool {
    guard let info = info(for: skin) else { return false }
    return SkinOverlayInput.representation(info: info, isPad: isPad, orientation: orientation) != nil
  }

  /// Forgets every pick whose skin files are gone or unreadable. Call it outside view updates (a screen appearing,
  /// a library change): it publishes.
  static func forgetDeadSelections(in library: SkinLibrary) {
    for padKind in TouchOverlayPadKind.allCases {
      for orientation in TouchOverlayOrientation.allCases {
        guard let skin = library.selectedSkin(for: padKind, orientation: orientation), info(for: skin) == nil else { continue }
        library.select(nil, for: padKind, orientation: orientation)
      }
    }
  }

  /// A skin replaces the xib pads too, so the SwiftUI host is needed whenever the flag is on or a skin is chosen.
  static func usesHostedOverlay(flag: Bool, choice: OverlayChoice) -> Bool {
    flag || choice.skinID != nil
  }

  /// Where the skin puts the game picture on `canvas` (the full screen, safe areas included), from the same
  /// layout the skin is drawn with. `nil` when the skin declares no game screen for this canvas.
  static func gamePictureFrame(for skin: InstalledSkin, canvas: CGSize,
                               isPad: Bool = UIDevice.current.userInterfaceIdiom == .pad) -> CGRect? {
    let orientation = TouchOverlayOrientation(isPortrait: canvas.height >= canvas.width)
    guard let info = info(for: skin),
          let representation = SkinOverlayInput.representation(info: info, isPad: isPad, orientation: orientation),
          let rect = SkinLayout.make(representation, canvas: canvas).gameRect,
          rect.width > 0, rect.height > 0 else { return nil }
    return rect
  }

  /// The largest rect of `aspect` (width / height) that fits `rect`, centred in it. A non-positive aspect fills `rect`.
  static func aspectFit(aspect: CGFloat, in rect: CGRect) -> CGRect {
    guard aspect > 0, aspect.isFinite else { return rect }
    let size = rect.width / rect.height > aspect
      ? CGSize(width: rect.height * aspect, height: rect.height)
      : CGSize(width: rect.width, height: rect.width / aspect)
    return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
  }

  /// The skin's parsed `info.json`, re-read only when the file changes (imports replace a skin in place).
  /// `nil` when the file is gone or no longer parses.
  private static func info(for skin: InstalledSkin) -> SkinInfo? {
    let file = skin.directory.appendingPathComponent(infoFileName)
    let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    if let cached = infoCache[skin.directory], cached.modified == modified, modified != nil { return cached.info }
    guard let info = try? SkinInfo.load(directory: skin.directory) else {
      infoCache[skin.directory] = nil
      return nil
    }
    infoCache[skin.directory] = (modified, info)
    return info
  }
}

/// The SwiftUI root `TouchPadsContainer` hosts: the Swift-drawn overlay, or a skin in its place.
struct HostedOverlayRoot: View {
  let padKind: TouchOverlayPadKind
  /// The Touchscreen device id, never the player slot.
  let deviceId: Int
  let irMode: Int
  let choice: OverlayChoice

  var body: some View {
    switch choice {
    case .programmatic:
      TouchOverlayView(padKind: padKind, deviceId: deviceId, irMode: irMode)
    case .skin(let skin):
      SkinOverlayView(skin: skin, padKind: padKind, deviceId: deviceId, irMode: irMode, onAction: SkinActionNotification.post)
    }
  }
}
#endif
