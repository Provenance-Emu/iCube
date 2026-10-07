// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Shows `idle` normally and `whileEmulating` while a game is running.
///
/// Reads `EmulationState` itself, so a session start or end re-evaluates only this small view, not
/// the library screen that hosts it.
struct EmulationQuiet<Idle: View, Active: View>: View {
  let idle: Idle
  let whileEmulating: Active

  var body: some View {
    if EmulationState.shared.isActive {
      whileEmulating
    } else {
      idle
    }
  }
}

/// The library's "Animated" background style: a gradient, a faint grid, drifting orbs and tiles.
///
/// The orb and tile geometry is fixed per index. It used to be drawn from `CGFloat.random` inside
/// `body` under `.animation(..., value: UUID())`, so every re-evaluation of the library (any
/// published change) picked new random frames and new animation identities, restarting every
/// `repeatForever` at once. Now the motion is one `@State` flag flipped once on appear.
struct LibraryAnimatedBackground: View {
  @Environment(\.colorScheme) private var colorScheme

  /// Flipped once on appear; the orbs and tiles animate between its two values forever.
  @State private var drifting = false

  private static let orbCount = 5
  private static let tileCount = 8

  /// Deterministic spread in `[0, 1)` for the `index`th element of the `salt` series.
  static func unit(_ index: Int, salt: Int) -> Double {
    let value = sin(Double(index * 31 + salt) * 12.9898) * 43758.5453
    return abs(value - value.rounded(.down))
  }

  var body: some View {
    ZStack {
      baseGradient

      // Elegant animated orbs with GameCube/Wii theming
      ForEach(0..<Self.orbCount, id: \.self) { index in
        let size = 200 + Self.unit(index, salt: 1) * 200
        let x = (Self.unit(index, salt: 2) - 0.5) * 300
        let y = (Self.unit(index, salt: 3) - 0.5) * 400
        let drift = 30 + Self.unit(index, salt: 4) * 40
        let duration = 10 + Self.unit(index, salt: 5) * 8
        orb(index: index)
          .frame(width: size, height: size)
          .offset(x: x + (drifting ? drift : -drift), y: y + (drifting ? -drift : drift))
          .scaleEffect(0.8 + CGFloat(index) * 0.1)
          .animation(
            .easeInOut(duration: duration).repeatForever(autoreverses: true).delay(Double(index) * 1.5),
            value: drifting)
      }

      majorGrid
      minorGrid

      // Floating elements
      ForEach(0..<Self.tileCount, id: \.self) { index in
        let side = 20 + Self.unit(index, salt: 6) * 20
        let x = (Self.unit(index, salt: 7) - 0.5) * 400
        let y = (Self.unit(index, salt: 8) - 0.5) * 600
        let startAngle = Self.unit(index, salt: 9) * 360
        let duration = 20 + Self.unit(index, salt: 10) * 10
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(
            LinearGradient(
              colors: [
                (colorScheme == .dark ? Color.white.opacity(0.03) : Color.white.opacity(0.5)),
                Color.clear
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
          .frame(width: side, height: side)
          .offset(x: x, y: y)
          .rotationEffect(.degrees(startAngle + (drifting ? 360 : 0)))
          .animation(.linear(duration: duration).repeatForever(autoreverses: false).delay(Double(index) * 2), value: drifting)
      }
    }
    // No .clipped(): it cut the whole effect off at the safe area, leaving plain bands behind the
    // navigation bar and the bottom search bar. The orbs move by .offset, which never affects
    // layout, and this is the bottom layer, so nothing needs clipping.
    .ignoresSafeArea()
    .onAppear { drifting = true }
  }

  @ViewBuilder
  private var baseGradient: some View {
    // Premium gradient switches for light/dark
    if colorScheme == .dark {
      RadialGradient(
        colors: [
          Color(red: 0.12, green: 0.15, blue: 0.28),
          Color(red: 0.08, green: 0.12, blue: 0.22),
          Color(red: 0.04, green: 0.06, blue: 0.15),
          Color.black
        ],
        center: .topLeading,
        startRadius: 100,
        endRadius: 800
      )
      .ignoresSafeArea()
    } else {
      RadialGradient(
        colors: [
          Color(red: 0.92, green: 0.95, blue: 1.00),
          Color(red: 0.88, green: 0.93, blue: 1.00),
          Color(red: 0.98, green: 0.99, blue: 1.00)
        ],
        center: .topLeading,
        startRadius: 100,
        endRadius: 800
      )
      .ignoresSafeArea()
    }
  }

  private func orb(index: Int) -> some View {
    Circle()
      .fill(
        RadialGradient(
          colors: [
            (colorScheme == .dark ? (index % 2 == 0 ? Color.purple.opacity(0.06) : Color.blue.opacity(0.05))
             : (index % 2 == 0 ? Color.purple.opacity(0.10) : Color.blue.opacity(0.10))),
            (colorScheme == .dark ? (index % 2 == 0 ? Color.purple.opacity(0.03) : Color.blue.opacity(0.025))
             : Color.white.opacity(0.0)),
            Color.clear
          ],
          center: .center,
          startRadius: 20,
          endRadius: 180
        )
      )
  }

  /// Subtle grid pattern
  private var majorGrid: some View {
    Canvas { context, size in
      let spacing: CGFloat = 80
      let lineWidth: CGFloat = 0.5
      let gradient = Gradient(colors: [
        (colorScheme == .dark ? .white.opacity(0.08) : .black.opacity(0.06)),
        .clear,
        (colorScheme == .dark ? .white.opacity(0.04) : .black.opacity(0.03))
      ])

      context.stroke(
        Path { path in
          for x in stride(from: 0, through: size.width, by: spacing) {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
          }
          for y in stride(from: 0, through: size.height, by: spacing) {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
          }
        },
        with: .linearGradient(
          gradient,
          startPoint: CGPoint(x: 0, y: 0),
          endPoint: CGPoint(x: size.width, y: size.height)
        ),
        lineWidth: lineWidth
      )
    }
    .ignoresSafeArea()
    .opacity(colorScheme == .dark ? 0.6 : 0.25)
  }

  /// Minor grid checks (subtle)
  private var minorGrid: some View {
    Canvas { context, size in
      let spacing: CGFloat = 20
      let lineWidth: CGFloat = 0.25
      let strokeColor = (colorScheme == .dark ? Color.white.opacity(0.02) : Color.black.opacity(0.02))
      context.stroke(
        Path { path in
          for x in stride(from: 0, through: size.width, by: spacing) {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
          }
          for y in stride(from: 0, through: size.height, by: spacing) {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
          }
        },
        with: .color(strokeColor),
        lineWidth: lineWidth
      )
    }
    .ignoresSafeArea()
    .opacity(colorScheme == .dark ? 0.25 : 0.12)
  }
}
