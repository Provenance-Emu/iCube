// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The iCube mark ringed by twinkling sparkles, either pulsing in place or drifting round a small orbit (picked at
/// random each time it appears). About and the first-run welcome both show it; Reduce Motion holds it still.
struct ICubeAnimatedLogo: View {
  var height: CGFloat = ICubeDesign.Logo.aboutHeight

  private enum Motion { case centerPulse, orbitRight }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var motion: Motion = .centerPulse
  @State private var scale: CGFloat = 1
  @State private var orbitAngle: Double = 0
  @State private var sparkleOpacity: Double = 0.3

  var body: some View {
    let logo = ICubeDesign.Logo.self
    ZStack {
      ForEach(0 ..< logo.sparkleCount, id: \.self) { index in
        let angle = Double(index) * 2 * .pi / Double(logo.sparkleCount)
        Image(systemName: "sparkle")
          .font(logo.sparkleFont)
          .foregroundStyle(ICubeDesign.color(.accent).opacity(logo.sparkleOpacity))
          .offset(x: cos(angle) * height * logo.sparkleRingRadius, y: sin(angle) * height * logo.sparkleRingRadius)
          .opacity(sparkleOpacity)
          .animation(reduceMotion ? nil : .easeInOut(duration: logo.sparkleDuration)
                       .delay(Double(index) * logo.sparkleStagger).repeatForever(autoreverses: true),
                     value: sparkleOpacity)
      }

      Image("iCube-Logo-Square-NoText")
        .resizable()
        .scaledToFit()
        .frame(height: height)
        .scaleEffect(scale)
        .offset(x: motion == .orbitRight ? height * (logo.orbitCenterX + logo.orbitRadiusX * cos(orbitAngle)) : 0,
                y: motion == .orbitRight ? height * logo.orbitRadiusY * sin(orbitAngle) : 0)
        .tint(ICubeDesign.color(.accent))
    }
    .frame(height: height * logo.frameScale)
    .accessibilityHidden(true)
    .onAppear(perform: start)
  }

  private func start() {
    let logo = ICubeDesign.Logo.self
    sparkleOpacity = 0.8
    guard !reduceMotion else { return }
    motion = Bool.random() ? .centerPulse : .orbitRight
    switch motion {
    case .centerPulse:
      scale = logo.pulseRange.lowerBound
      withAnimation(.easeInOut(duration: logo.pulseDuration).repeatForever(autoreverses: true)) {
        scale = logo.pulseRange.upperBound
      }
    case .orbitRight:
      scale = logo.orbitScale
      orbitAngle = 0
      withAnimation(.linear(duration: logo.orbitDuration).repeatForever(autoreverses: false)) {
        orbitAngle = 2 * .pi
      }
    }
  }
}
