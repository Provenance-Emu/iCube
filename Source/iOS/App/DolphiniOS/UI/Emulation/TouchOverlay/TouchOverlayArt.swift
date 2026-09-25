// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SwiftUI

/// Procedural gradient+shadow art for the two palettes (design §5). No image assets: every shape
/// is drawn with SwiftUI `Shape`/`Path` + gradients + `.shadow`, patterned on iFly's
/// `ControllerArtKit` (glossy disc = base radial gradient + specular arc + inner-shadow rim +
/// outer drop shadow + colored glow). Pressed state is a brighter, slightly inset look, never a
/// separate pressed-image swap (there are no images).
enum TouchOverlayArt {
  /// Which palette a group renders in. GameCube-family and Wii-family (Wii Remote, Nunchuk,
  /// Classic Controller) groups always use their own console's palette (§5 table).
  enum Variant {
    case gameCube
    case wii
  }

  /// The Settings "Style" override (task item 3): `auto` keeps today's per-pad-kind palette
  /// choice, the other two cases force every group (regardless of pad kind) into one palette.
  /// Raw values are the `touch_overlay_style` UserDefaults integer, registered in
  /// `DefaultPreferences.plist`.
  enum Style: Int, CaseIterable, Sendable {
    case auto = 0
    case gameCube = 1
    case wii = 2

    static func current() -> Style {
      Style(rawValue: UserDefaults.standard.integer(forKey: "touch_overlay_style")) ?? .auto
    }

    func resolvedVariant(padKind: TouchOverlayPadKind) -> Variant {
      switch self {
      case .auto: return padKind == .gameCube ? .gameCube : .wii
      case .gameCube: return .gameCube
      case .wii: return .wii
      }
    }
  }

  /// Shape family for a face-style button, per the §5 table.
  enum ButtonShape {
    /// GC A / Wii A/B / 1/2 / Nunchuk C — round.
    case circle
    /// GC X/Y — kidney/bean.
    case kidney
    /// GC Z, GC/Classic L/R/ZL/ZR triggers — a tapering bar.
    case bar
    /// GC Start, Wii -/+  — a small pill.
    case pill
  }

  // MARK: Palette

  private static func rimGlow(_ variant: Variant) -> Color {
    switch variant {
    case .gameCube: return Color(red: 0.62, green: 0.48, blue: 0.95)
    case .wii: return Color(red: 0.32, green: 0.62, blue: 1.0)
    }
  }

  /// The neutral (non-A/B/Home) button body gradient for a palette: GameCube's indigo shell,
  /// Wii's off-white shell.
  private static func neutralBody(_ variant: Variant) -> (top: Color, bottom: Color) {
    switch variant {
    case .gameCube: return (Color(red: 0.46, green: 0.36, blue: 0.66), Color(red: 0.24, green: 0.17, blue: 0.40))
    case .wii: return (.white, Color(white: 0.86))
    }
  }

  /// Per-control accent color. GameCube gives A/B/Start their real hardware colors; everything
  /// else (and all of Wii, which reads through the rim glow instead of a body tint) uses the
  /// palette's neutral body.
  static func accent(for controlId: String, variant: Variant) -> (top: Color, bottom: Color) {
    guard variant == .gameCube else { return neutralBody(.wii) }
    let suffix = controlId.split(separator: ".").last.map(String.init) ?? ""
    switch suffix {
    case "a": return (Color(red: 0.32, green: 0.86, blue: 0.40), Color(red: 0.10, green: 0.55, blue: 0.22))
    case "b": return (Color(red: 0.95, green: 0.30, blue: 0.28), Color(red: 0.65, green: 0.08, blue: 0.10))
    case "start": return (Color(white: 0.98), Color(white: 0.80))
    default: return neutralBody(.gameCube)
    }
  }

  /// Short label text for a control id ("gc.a" -> "A", "wii.one" -> "1"). Every control keeps its
  /// label — §5 requires it even over procedural art with no baked-in text.
  static func label(for controlId: String) -> String {
    guard let suffix = controlId.split(separator: ".").last else { return "" }
    switch suffix {
    case "one": return "1"
    case "two": return "2"
    case "minus": return "\u{2212}"
    case "plus": return "+"
    case "home": return "\u{2302}"
    default: return suffix.uppercased()
    }
  }

  // MARK: Buttons

  /// One face-style button: shaped body (per `shape`), gradient fill, gloss highlight, rim +
  /// colored glow (brighter/inset when `pressed`), with its label centered on top.
  @ViewBuilder
  static func button(controlId: String, shape: ButtonShape, variant: Variant, pressed: Bool) -> some View {
    let (top, bottom) = accent(for: controlId, variant: variant)
    let glow = variant == .gameCube ? rimGlow(.gameCube) : rimGlow(.wii)
    ZStack {
      buttonShape(shape)
        .fill(LinearGradient(colors: pressed ? [bottom, top] : [top, bottom], startPoint: .top, endPoint: .bottom))
      buttonShape(shape)
        .fill(LinearGradient(colors: [Color.white.opacity(pressed ? 0.10 : 0.34), .clear], startPoint: .top, endPoint: .center))
      buttonShape(shape)
        .stroke(variant == .wii ? glow.opacity(pressed ? 0.95 : 0.6) : Color.white.opacity(0.5), lineWidth: pressed ? 2 : 1)
      Text(label(for: controlId))
        .font(.caption2.weight(.bold))
        .foregroundStyle(variant == .gameCube ? Color.white.opacity(0.9) : Color.black.opacity(0.55))
    }
    .scaleEffect(pressed ? 0.92 : 1.0)
    .shadow(color: .black.opacity(0.35), radius: pressed ? 1 : 3, x: 0, y: pressed ? 0 : 2)
    .shadow(color: glow.opacity(pressed ? 0.85 : 0.35), radius: pressed ? 8 : 4)
    .animation(.easeOut(duration: 0.08), value: pressed)
  }

  private static func buttonShape(_ shape: ButtonShape) -> AnyShape {
    switch shape {
    case .circle: return AnyShape(Circle())
    case .kidney: return AnyShape(KidneyShape())
    case .bar: return AnyShape(TrapezoidShape(taper: 0.14))
    case .pill: return AnyShape(Capsule())
    }
  }

  // MARK: D-pad

  /// Real cross D-pad with per-arm gloss and a lit arrow for every currently-pressed direction.
  @ViewBuilder
  static func dpad(pressed: Set<TouchOverlayHitTester.DPadDirection>, variant: Variant) -> some View {
    let (top, bottom) = neutralBody(variant)
    let glow = rimGlow(variant)
    ZStack {
      Circle()
        .fill(RadialGradient(colors: [top.opacity(0.9), bottom.opacity(0.95)], center: UnitPoint(x: 0.4, y: 0.34), startRadius: 2, endRadius: 90))
      Circle().strokeBorder(glow.opacity(0.55), lineWidth: 2)
      CrossShape()
        .fill(LinearGradient(colors: [bottom, top], startPoint: .top, endPoint: .bottom))
        .padding(18)
      dpadArrow(rotation: 0, lit: pressed.contains(.up), variant: variant).offset(y: -34)
      dpadArrow(rotation: 180, lit: pressed.contains(.down), variant: variant).offset(y: 34)
      dpadArrow(rotation: -90, lit: pressed.contains(.left), variant: variant).offset(x: -34)
      dpadArrow(rotation: 90, lit: pressed.contains(.right), variant: variant).offset(x: 34)
    }
    .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 2)
  }

  @ViewBuilder
  private static func dpadArrow(rotation: Double, lit: Bool, variant: Variant) -> some View {
    Triangle()
      .fill(lit ? rimGlow(variant) : Color.white.opacity(0.85))
      .frame(width: 20, height: 20)
      .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
      .rotationEffect(.degrees(rotation))
      .scaleEffect(lit ? 1.1 : 1.0)
      .animation(.easeOut(duration: 0.08), value: lit)
  }

  // MARK: Stick

  /// Dished analog base with an OCTAGONAL GATE ring drawn purely for looks — the actual travel
  /// math (`TouchOverlayInput.stickAxes`) is a circle and stays that way (design §5 note: don't
  /// couple cosmetic gate art to hit-test geometry).
  @ViewBuilder
  static func stickBase(variant: Variant, dragging: Bool) -> some View {
    let glow = rimGlow(variant)
    ZStack {
      Circle()
        .fill(RadialGradient(colors: [Color.black.opacity(0.35), glow.opacity(0.28)], center: .center, startRadius: 2, endRadius: 70))
      OctagonShape()
        .stroke(glow.opacity(0.6), lineWidth: 2)
        .padding(6)
      Circle()
        .stroke(glow.opacity(dragging ? 0.9 : 0), lineWidth: 3)
        .shadow(color: glow.opacity(dragging ? 0.9 : 0), radius: 8)
        .animation(.easeOut(duration: 0.1), value: dragging)
    }
  }

  @ViewBuilder
  static func stickKnob(variant: Variant) -> some View {
    let (top, bottom) = neutralBody(variant)
    Circle()
      .fill(RadialGradient(colors: [top, bottom], center: UnitPoint(x: 0.38, y: 0.3), startRadius: 1, endRadius: 40))
      .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 1.5))
      .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
  }

  // MARK: IR pad (phase 2: static, inert visual only — §2.1/§6.5)

  /// Translucent region marking where the Wii pointer's drag/follow surface WILL live once phase
  /// 3 wires touches to it. No crosshair tracking yet (nothing to track — the surface is inert),
  /// just the low-opacity fill + glow border §5 calls for.
  @ViewBuilder
  static func irPad(variant: Variant) -> some View {
    let glow = rimGlow(variant)
    RoundedRectangle(cornerRadius: 20, style: .continuous)
      .fill(Color.white.opacity(0.06))
      .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(glow.opacity(0.35), lineWidth: 1.5))
  }
}

// MARK: - Shapes

/// A rounded-arm plus/cross, used by the D-pad body.
struct CrossShape: Shape {
  var armRatio: CGFloat = 0.34
  var corner: CGFloat = 6

  func path(in rect: CGRect) -> Path {
    let w = rect.width, h = rect.height
    let armW = w * armRatio, armH = h * armRatio
    let vx = (w - armW) / 2, hy = (h - armH) / 2
    let vertical = CGRect(x: rect.minX + vx, y: rect.minY, width: armW, height: h)
    let horizontal = CGRect(x: rect.minX, y: rect.minY + hy, width: w, height: armH)
    var path = Path()
    path.addRoundedRect(in: vertical, cornerSize: CGSize(width: corner, height: corner))
    path.addRoundedRect(in: horizontal, cornerSize: CGSize(width: corner, height: corner))
    return path
  }
}

/// A simple upward-pointing triangle, used for the D-pad's arrows.
struct Triangle: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.midX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}

/// A regular octagon inscribed in `rect`, used as the stick's cosmetic gate ring (§5 — visual
/// only, never the hit-test geometry).
struct OctagonShape: Shape {
  func path(in rect: CGRect) -> Path {
    let sides = 8
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let radius = min(rect.width, rect.height) / 2
    var path = Path()
    for i in 0..<sides {
      let angle = (CGFloat(i) / CGFloat(sides)) * 2 * .pi - .pi / 8
      let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
      if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
  }
}

/// A symmetric trapezoid tapering toward the bottom by `taper` of the width — gives triggers and
/// the GC Z button a contoured, sloped silhouette instead of a flat rectangle.
struct TrapezoidShape: Shape {
  var taper: CGFloat = 0.16

  func path(in rect: CGRect) -> Path {
    let dx = rect.width * taper
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - dx, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX + dx, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}

/// A bean/kidney silhouette (GC X/Y, §5) — two opposing bulges along the long axis.
struct KidneyShape: Shape {
  func path(in rect: CGRect) -> Path {
    let w = rect.width, h = rect.height
    var path = Path()
    path.move(to: CGPoint(x: rect.minX + w * 0.12, y: rect.minY + h * 0.55))
    path.addCurve(
      to: CGPoint(x: rect.minX + w * 0.88, y: rect.minY + h * 0.45),
      control1: CGPoint(x: rect.minX + w * 0.05, y: rect.minY + h * 0.05),
      control2: CGPoint(x: rect.minX + w * 0.60, y: rect.minY - h * 0.08)
    )
    path.addCurve(
      to: CGPoint(x: rect.minX + w * 0.12, y: rect.minY + h * 0.55),
      control1: CGPoint(x: rect.minX + w * 1.05, y: rect.minY + h * 0.62),
      control2: CGPoint(x: rect.minX + w * 0.50, y: rect.minY + h * 1.08)
    )
    path.closeSubpath()
    return path
  }
}
#endif
