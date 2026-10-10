// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit
import XCTest

@testable import iCube

final class ICubeDesignTests: XCTestCase {
  func test_sixTypeRoles() {
    XCTAssertEqual(ICubeDesign.TypeRole.allCases, [.title, .section, .nav, .body, .detail, .tag])
  }

  func test_displayFaceIsRegistered() {
    XCTAssertTrue(UIFont.familyNames.contains(ICubeDesign.DisplayFace.family),
                  "UIAppFonts did not register \(ICubeDesign.DisplayFace.family)")
    XCTAssertNotNil(UIFont(name: ICubeDesign.DisplayFace.postScriptName(bold: false), size: 12))
    XCTAssertNotNil(UIFont(name: ICubeDesign.DisplayFace.postScriptName(bold: true), size: 12))
    XCTAssertTrue(ICubeDesign.DisplayFace.isAvailable)
  }

  func test_typeTable_matchesSpec() {
    // (tvOS pt, iPad pt) per spec §2.1.
    let expected: [ICubeDesign.TypeRole: (CGFloat, CGFloat)] = [
      .title: (48, 34), .section: (30, 20), .nav: (24, 17), .body: (29, 17), .detail: (23, 13), .tag: (20, 12),
    ]
    for role in ICubeDesign.TypeRole.allCases {
      let spec = ICubeDesign.TypeSpec.of(role)
      XCTAssertEqual(spec.tvSize, expected[role]!.0, "\(role) tvOS size")
      XCTAssertEqual(spec.padSize, expected[role]!.1, "\(role) iPad size")
    }
    XCTAssertTrue(ICubeDesign.TypeSpec.of(.section).uppercase)
    XCTAssertTrue(ICubeDesign.TypeSpec.of(.nav).uppercase)
    XCTAssertTrue(ICubeDesign.TypeSpec.of(.tag).uppercase)
    XCTAssertFalse(ICubeDesign.TypeSpec.of(.body).uppercase)
    XCTAssertEqual(ICubeDesign.TypeSpec.of(.section).tracking, 1.5)
    XCTAssertEqual(ICubeDesign.TypeSpec.of(.nav).tracking, 1.2)
    XCTAssertEqual(ICubeDesign.TypeSpec.of(.tag).tracking, 0.5)
  }

  func test_scaleRadiiLines() {
    XCTAssertEqual(ICubeDesign.Spacing.allCases.map(\.rawValue), [4, 8, 12, 16, 24, 40, 80])
    XCTAssertEqual(ICubeDesign.Radius.allCases.map(\.rawValue), [16, 10]) // plus Capsule()
    XCTAssertEqual(ICubeDesign.Line.allCases.map(\.rawValue), [1, 4])
  }

  /// The menu kit's values carried over unchanged from MenuTheme; step 2 restyles them.
  func test_menuKitValues_unchangedFromMenuTheme() {
    let icube = ICubeDesign.standard
    XCTAssertEqual(icube.cornerRadius, 16)
    XCTAssertEqual(icube.focusRingWidth, 4)
    XCTAssertEqual(icube.focusScale, 1.06)
    XCTAssertEqual(icube.tileMinHeight, 96) // iOS column; tvOS is 180
    XCTAssertEqual(icube.shelfHeight, 56) // iOS column; tvOS is 80
  }

  func test_colorRoles_matchSpecHex() {
    let light = UITraitCollection(userInterfaceStyle: .light)
    let dark = UITraitCollection(userInterfaceStyle: .dark)
    XCTAssertEqual(Self.rgba(ICubeDesign.uiColor(.accent), light), [0x3F, 0x56, 0xA4, 255])
    XCTAssertEqual(Self.rgba(ICubeDesign.uiColor(.accent), dark), [0x8E, 0xC5, 0xF9, 255])
    XCTAssertEqual(Self.rgba(ICubeDesign.uiColor(.textPrimary), light), [0x0A, 0x0F, 0x26, 255])
    XCTAssertEqual(Self.rgba(ICubeDesign.uiColor(.textPrimary), dark), [0xFF, 0xFF, 0xFF, 255])
    XCTAssertEqual(ICubeDesign.roomStops.map { Self.rgba($0, light) },
                   [[0xE6, 0xED, 0xFA, 255], [0xD6, 0xE3, 0xFA, 255], [0xF5, 0xF7, 0xFF, 255]])
    XCTAssertEqual(ICubeDesign.roomStops.map { Self.rgba($0, dark) },
                   [[0x14, 0x1F, 0x38, 255], [0x0A, 0x0F, 0x26, 255], [0x00, 0x00, 0x00, 255]])
  }

  /// Spec §4.4 with Correction 1. Each text tier, composited over each background, against its
  /// floor: 4.5:1 for body/detail/tag text, 3:1 for section/title (large) and tertiary (chevrons,
  /// disabled). Backgrounds are the three room stops and rowSurface over each stop, in both
  /// appearances.
  func test_contrast_meetsWCAG_AA_inBothAppearances() {
    let tiers: [(ICubeColorRole, Double)] = [
      (.textPrimary, 4.5), (.textSecondary, 4.5), (.accent, 4.5), (.textTertiary, 3.0),
    ]
    for style in [UIUserInterfaceStyle.light, .dark] {
      let traits = UITraitCollection(userInterfaceStyle: style)
      let surface = ICubeDesign.uiColor(.rowSurface).resolvedColor(with: traits)
      for stop in ICubeDesign.roomStops.map({ $0.resolvedColor(with: traits) }) {
        for background in [stop, Self.over(surface, stop)] {
          for (role, floor) in tiers {
            let text = Self.over(ICubeDesign.uiColor(role).resolvedColor(with: traits), background)
            let ratio = Self.contrast(text, background)
            XCTAssertGreaterThanOrEqual(ratio, floor, "\(role) in \(style == .dark ? "dark" : "light") = \(ratio)")
          }
        }
      }
    }
  }

  // MARK: Helpers

  private static func rgba(_ color: UIColor, _ traits: UITraitCollection) -> [Int] {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
    return [r, g, b, a].map { Int(($0 * 255).rounded()) }
  }

  /// `top` alpha-composited over opaque `bottom`.
  private static func over(_ top: UIColor, _ bottom: UIColor) -> UIColor {
    var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
    var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
    top.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
    bottom.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
    return UIColor(red: tr * ta + br * (1 - ta), green: tg * ta + bg * (1 - ta), blue: tb * ta + bb * (1 - ta), alpha: 1)
  }

  private static func luminance(_ color: UIColor) -> Double {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    color.getRed(&r, green: &g, blue: &b, alpha: &a)
    func lin(_ c: CGFloat) -> Double { let c = Double(c); return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
  }

  private static func contrast(_ a: UIColor, _ b: UIColor) -> Double {
    let (la, lb) = (luminance(a), luminance(b))
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
  }
}
