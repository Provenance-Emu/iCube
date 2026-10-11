// Common/Swift/MenuKit/ICubeDesign.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

/// Every design token iCube draws its tvOS and controller-driven chrome with
/// (docs/superpowers/specs/2026-10-10-icube-design-language.md). Raw sizes, radii, line widths and
/// colours live only in `ICubeDesign*.swift`; `Project/Scripts/check_design_tokens.py` ratchets the
/// rest of `Common/` toward zero. Views read the instance through `@Environment(\.icube)` so
/// previews and tests can inject values.
struct ICubeDesign {
  static let standard = ICubeDesign()

  // MARK: Menu kit (carried over from MenuTheme; step 2 moves these onto the roles below)

  /// The app's AccentColor asset (#8EC5F9 in both appearances), not the adaptive `accent` role.
  var tileAccent: Color = .accentColor
  var tileFill: Material = .ultraThinMaterial
  var cornerRadius: CGFloat = Radius.large.rawValue
  var focusRingWidth: CGFloat = Line.focus.rawValue
  var focusScale: CGFloat = Motion.tileFocusScale
  #if os(tvOS)
  var tileMinHeight: CGFloat = 180
  var shelfHeight: CGFloat = 80
  var tileTitleFont: Font = .headline
  #else
  var tileMinHeight: CGFloat = 96
  var shelfHeight: CGFloat = 56
  var tileTitleFont: Font = .subheadline.weight(.semibold)
  #endif

  // MARK: Type

  /// The six type roles (spec §2.1). There are no other text sizes.
  enum TypeRole: CaseIterable {
    case title, section, nav, body, detail, tag
  }

  enum Face { case displayBold, displayMedium, system, mono }

  struct TypeSpec {
    let face: Face
    let tvSize: CGFloat
    let padSize: CGFloat
    let relativeTo: Font.TextStyle
    let uppercase: Bool
    let tracking: CGFloat

    static func of(_ role: TypeRole) -> TypeSpec {
      switch role {
      case .title: TypeSpec(face: .displayBold, tvSize: 48, padSize: 34, relativeTo: .largeTitle, uppercase: false, tracking: 0)
      case .section: TypeSpec(face: .displayBold, tvSize: 30, padSize: 20, relativeTo: .title3, uppercase: true, tracking: 1.5)
      case .nav: TypeSpec(face: .displayMedium, tvSize: 24, padSize: 17, relativeTo: .headline, uppercase: true, tracking: 1.2)
      case .body: TypeSpec(face: .system, tvSize: 29, padSize: 17, relativeTo: .body, uppercase: false, tracking: 0)
      case .detail: TypeSpec(face: .system, tvSize: 23, padSize: 13, relativeTo: .footnote, uppercase: false, tracking: 0)
      case .tag: TypeSpec(face: .mono, tvSize: 20, padSize: 12, relativeTo: .caption, uppercase: true, tracking: 0.5)
      }
    }
  }

  /// M PLUS Rounded 1c (SIL OFL 1.1), bundled via `UIAppFonts`. Names read from the TTFs.
  enum DisplayFace {
    static let family = "Rounded Mplus 1c"

    /// False if registration failed; the roles then fall back to the rounded system face.
    static let isAvailable: Bool = UIFont.familyNames.contains(family)

    static func postScriptName(bold: Bool) -> String {
      bold ? "RoundedMplus1c-Bold" : "RoundedMplus1c-Medium"
    }
  }

  /// The font for `role`: the tvOS column on tvOS; on iOS the iPad column, as the matching text
  /// style so it follows Dynamic Type (17/13/12 pt at the default size).
  func font(_ role: TypeRole) -> Font {
    let spec = TypeSpec.of(role)
    #if os(tvOS)
    let size = spec.tvSize
    #else
    let size = spec.padSize
    #endif
    switch spec.face {
    case .displayBold, .displayMedium:
      let bold = spec.face == .displayBold
      guard DisplayFace.isAvailable else {
        return .system(size: size, weight: bold ? .bold : .medium, design: .rounded)
      }
      #if os(tvOS)
      return .custom(DisplayFace.postScriptName(bold: bold), fixedSize: size)
      #else
      return .custom(DisplayFace.postScriptName(bold: bold), size: size, relativeTo: spec.relativeTo)
      #endif
    case .system:
      #if os(tvOS)
      return .system(size: size)
      #else
      return .system(spec.relativeTo)
      #endif
    case .mono:
      #if os(tvOS)
      return .system(size: size, weight: .medium, design: .monospaced)
      #else
      return .system(spec.relativeTo, design: .monospaced, weight: .medium)
      #endif
    }
  }

  // MARK: Spacing, radii, lines (spec §2.2–2.4)

  enum Spacing: CGFloat, CaseIterable {
    case xxs = 4, xs = 8, s = 12, m = 16, l = 24, xl = 40, xxl = 80
  }

  /// Card art, tile and panel use `large`; row surface, icon badge and rail highlight use `small`.
  /// The third radius is `Capsule()`.
  enum Radius: CGFloat, CaseIterable {
    case large = 16, small = 10
  }

  /// `hairline` in the hairline colour; `focus` in the focus gradient. Selection is fill, never stroke.
  enum Line: CGFloat, CaseIterable {
    case hairline = 1, focus = 4
  }

  // MARK: Motion (spec §2.7)

  enum Motion {
    static let focusSpring = Animation.spring(response: 0.4, dampingFraction: 0.8)
    static let selection = Animation.easeInOut(duration: 0.2)
    static let rowFocusScale: CGFloat = 1.04
    static let tileFocusScale: CGFloat = 1.06
    static let railCollapsedWidth: CGFloat = 88
    static let railExpandedWidth: CGFloat = 320
  }
}

extension EnvironmentValues {
  @Entry var icube: ICubeDesign = .standard
}

private struct ICubeTextModifier: ViewModifier {
  let role: ICubeDesign.TypeRole
  @Environment(\.icube) private var icube

  func body(content: Content) -> some View {
    let spec = ICubeDesign.TypeSpec.of(role)
    content
      .font(icube.font(role))
      .textCase(spec.uppercase ? .uppercase : nil)
      .tracking(spec.tracking)
  }
}

extension View {
  /// Sets `role`'s font, case and tracking (spec §2.1).
  func icubeText(_ role: ICubeDesign.TypeRole) -> some View {
    modifier(ICubeTextModifier(role: role))
  }
}

extension ICubeDesign {
  /// SF Symbol glyph sizes for tiles and shelves (tvOS points).
  enum Symbol: CGFloat {
    case tilePrimary = 40, tile = 30, shelf = 28
  }

  static func symbolFont(_ size: Symbol) -> Font {
    .system(size: size.rawValue, weight: .medium)
  }
}
