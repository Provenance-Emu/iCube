// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import XCTest

@testable import iCube

/// The overlay's button art follows the pad shown (controller hub Phase 4: the separate colour
/// override is gone; the hub's Touch Controls "Layout" picks the pad).
final class TouchOverlayArtTests: XCTestCase {
  func testGameCubePadUsesTheGameCubePalette() {
    XCTAssertEqual(TouchOverlayArt.variant(for: .gameCube), .gameCube)
  }

  func testEveryWiiPadUsesTheWiiPalette() {
    for kind in [TouchOverlayPadKind.wiiRemote, .wiiRemoteSideways, .wiiClassic] {
      XCTAssertEqual(TouchOverlayArt.variant(for: kind), .wii, kind.rawValue)
    }
  }

  /// A player who once picked a colour override keeps the stored integer; it must no longer apply.
  func testAStaleColourOverrideIsIgnored() {
    let key = "touch_overlay_style"
    let saved = UserDefaults.standard.object(forKey: key)
    defer { UserDefaults.standard.set(saved, forKey: key) }
    UserDefaults.standard.set(2, forKey: key)  // the old "Wii" override
    XCTAssertEqual(TouchOverlayArt.variant(for: .gameCube), .gameCube)
  }
}
#endif
