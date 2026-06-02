// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

// Subtle animated background of swimming dolphins
struct SwimmingDolphinsView: View {
  enum Direction { case leftToRight, rightToLeft }
  let count: Int
  let direction: Direction
  let maxSize: CGFloat
  let opacity: Double

  init(count: Int = 3, direction: Direction = .leftToRight, maxSize: CGFloat = 110, opacity: Double = 0.2) {
    self.count = count
    self.direction = direction
    self.maxSize = max(60, maxSize)
    self.opacity = opacity
  }

  private func size(for i: Int) -> CGFloat { maxSize * (0.85 + CGFloat(i % 3) * 0.08) }

  // Pre-mirrored sprites to avoid runtime flipping artifacts
  private enum SpriteCache {
    static let normal: UIImage = UIImage(named: "DolphinLogo") ?? UIImage()
    static let mirrored: UIImage = {
      if let img = UIImage(named: "DolphinLogo") {
        return img.withHorizontallyFlippedOrientation()
      }
      return UIImage()
    }()
  }

  var body: some View {
    GeometryReader { geo in
      let w = max(geo.size.width, 1)
      let h = max(geo.size.height, 1)
      TimelineView(.animation) { timeline in
        let t = timeline.date.timeIntervalSinceReferenceDate
        ZStack {
          ForEach(0 ..< count, id: \.self) { i in
            Group {
              // Parameters per dolphin
              let base = Double(h) * (0.35 + Double(i % 5) * 0.1)
              let amplitude = 16.0 + Double(i % 3) * 10.0
              let phase = Double(i) * .pi / 3.0

              // Progress 0..1 controls full path traversal per dolphin
              let pad = 110.0
              let pathLen = Double(w) + 2.0 * pad
              let cyclesPerSecond = 0.03 + Double(i % 4) * 0.012
              let prog = (t * cyclesPerSecond + Double(i) * 0.173)
              let p = prog - floor(prog) // normalize

              // Position by direction (no ambiguity)
              let x = (direction == .leftToRight)
                ? (-pad + p * pathLen)
                : (Double(w) + pad - p * pathLen)

              // Per-dolphin pseudo-random to de-sync cycles
              let r1 = abs(sin(Double(i) * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1.0)
              let r2 = abs(sin(Double(i) * 78.233) * 19341.923).truncatingRemainder(dividingBy: 1.0)
              let r3 = abs(sin((Double(i) + 0.37) * 42.131) * 9182.12).truncatingRemainder(dividingBy: 1.0)
              let speedMul = 0.85 + 0.45 * r1
              let phaseExtra = r2 * 2.0 * .pi
              let ampMul = 0.85 + 0.45 * r3

              // Vertical wave + occasional jump; subtle yaw/pitch
              let theta = p * 2.0 * .pi * speedMul + phase + phaseExtra
              let baseWave = (amplitude * ampMul) * sin(theta)
              // Jump window per-dolphin (no mutation)
              let jRaw = (p + Double(i) * 0.17)
              let jMod = jRaw - floor(jRaw)
              let isJump = (jMod > 0.05 && jMod < 0.18)
              let tJump = isJump ? (jMod - 0.05) / 0.13 : 0.0
              let amplitudeWithBoost = amplitude * (1.0 + 0.4 * r2)
              let jumpDelta = isJump ? (amplitudeWithBoost * 1.1 * sin(tJump * .pi)) : 0.0
              let yPos = base + baseWave - jumpDelta
              let motionMul = 0.75 + 0.5 * r3
              let wag = (direction == .leftToRight ? 10.0 : -10.0) * motionMul * sin(theta)
              let yaw = (direction == .leftToRight ? 8.0 : -8.0) * motionMul * sin(theta * 1.2)
              let pitch = 6.0 * motionMul * cos(theta * 1.3)

              // Choose pre-mirrored sprite once per direction
              let uiImage = (direction == .leftToRight) ? SpriteCache.mirrored : SpriteCache.normal
              let sprite = Image(uiImage: uiImage)

              // Depth factor
              let depth = 0.90 + Double(i % 3) * 0.06
              let baseSize = size(for: i) * depth
              let alpha = opacity * (0.9 - Double(i % 3) * 0.08)

              // Caustic shimmer under-body
              let shimmer = 0.55 + 0.45 * sin(theta * 0.6 + 2.0)
              Group {
                Ellipse()
                  .fill(LinearGradient(colors: [Color.white.opacity(0.0), Color.white.opacity(0.22 * shimmer), Color.cyan.opacity(0.10)], startPoint: .leading, endPoint: .trailing))
                  .frame(width: baseSize * 0.85, height: baseSize * 0.22)
                  .position(x: CGFloat(x), y: CGFloat(yPos + baseSize * 0.18))
                  .blur(radius: 8)
                  .opacity(alpha * 0.6)
                  .blendMode(.screen)
              }

              // Trail ghosts (simple motion blur)
              ForEach(1 ... 2, id: \.self) { g in
                let pTrail = (p - Double(g) * 0.03)
                let pT = pTrail - floor(pTrail)
                let xT = (direction == .leftToRight) ? (-pad + pT * pathLen) : (Double(w) + pad - pT * pathLen)
                let thetaT = pT * 2.0 * .pi * speedMul + phase + phaseExtra
                let yT = base + (amplitude * ampMul) * sin(thetaT)
                Group {
                  sprite
                    .resizable()
                    .renderingMode(.original)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: baseSize * (1.0 - 0.15 * Double(g)))
                    .position(x: CGFloat(xT), y: CGFloat(yT))
                    .rotationEffect(.degrees(wag))
                    .opacity(alpha * (g == 1 ? 0.35 : 0.18))
                    .blur(radius: g == 1 ? 0.7 : 1.2)
                }
              }

              // Main sprite
              Group {
                sprite
                  .resizable()
                  .renderingMode(.original)
                  .aspectRatio(contentMode: .fit)
                  .frame(width: baseSize)
                  .position(x: CGFloat(x), y: CGFloat(yPos))
                  .rotationEffect(.degrees(wag))
                  .rotation3DEffect(.degrees(yaw), axis: (x: 0, y: 1, z: 0), perspective: 0.9)
                  .rotation3DEffect(.degrees(pitch), axis: (x: 1, y: 0, z: 0), perspective: 0.9)
                  .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)
                  .opacity(alpha)
                  .blendMode(.plusLighter)
              }

              // Leap splashes (particles) when jumping
              if isJump {
                let tJump = (jMod - 0.05) / 0.13
                ForEach(0 ..< 5, id: \.self) { k in
                  let rk = abs(sin(Double(k) * 17.23 + Double(i) * 3.11))
                  let ang = 2.0 * .pi * rk
                  let radius = (baseSize * 0.06) * (0.6 + rk) * (0.3 + tJump) * 2.0
                  let xOff = radius * cos(ang) * (direction == .leftToRight ? 1.0 : -1.0)
                  let yOff = -radius * 0.7 * (0.5 + 0.5 * rk)
                  Group {
                    Circle()
                      .fill(LinearGradient(colors: [Color.white.opacity(0.75 * (1.0 - tJump)), Color.cyan.opacity(0.35 * (1.0 - tJump))], startPoint: .top, endPoint: .bottom))
                      .frame(width: baseSize * 0.05 * (0.9 - 0.6 * tJump), height: baseSize * 0.05 * (0.9 - 0.6 * tJump))
                      .position(x: CGFloat(x + xOff), y: CGFloat(yPos + yOff))
                      .blur(radius: 0.8 + 1.6 * tJump)
                      .opacity(alpha * (0.85 - 0.8 * tJump))
                      .blendMode(.screen)
                  }
                }
              }
            }
          }
        }
      }
      .allowsHitTesting(false)
    }
  }
}
