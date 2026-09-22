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

private enum AboutLogoAnimationStyle {
  case centerPulse
  case orbitRight
}

struct AboutView: View {
  @Environment(\.openURL) private var openURL
  @State private var animationStyle: AboutLogoAnimationStyle = .centerPulse
  @State private var logoScale: CGFloat = 1.0
  @State private var orbitAngle: Double = 0.0
  @State private var sparkleOpacity: Double = 0.3

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        // Top spacer to mimic storyboard padding
        Color.clear.frame(height: 0)
        // Animated iCube logo with sparkle effects
        ZStack {
          // Subtle sparkles around the logo
          ForEach(0..<6, id: \.self) { index in
            Image(systemName: "sparkle")
              .font(.system(size: 12))
              .foregroundColor(.blue.opacity(0.6))
              .offset(
                x: cos(Double(index) * .pi / 3) * 80,
                y: sin(Double(index) * .pi / 3) * 80
              )
              .opacity(sparkleOpacity)
              .animation(.easeInOut(duration: 2.0).delay(Double(index) * 0.2).repeatForever(autoreverses: true), value: sparkleOpacity)
          }

          // Main logo — center pulse or right-biased orbit, chosen at random.
          Image("iCube-Logo-Square-NoText")
            .resizable()
            .scaledToFit()
            .frame(height: 128)
            .scaleEffect(logoScale)
            .offset(
              x: animationStyle == .orbitRight ? 8 + 14 * cos(orbitAngle) : 0,
              y: animationStyle == .orbitRight ? 6 * sin(orbitAngle) : 0
            )
            .tint(Color("DolphinTint"))
        }
        .frame(height: 160)
        .onAppear {
          startAboutAnimation()
        }

        Text("iCube")
          .font(.system(size: 28, weight: .semibold))
          .foregroundColor(.blue)

        // App version / build + Dolphin core version.
        VStack(spacing: 2) {
          Text(verbatim: "\(L("Version")) \(VersionManager.shared().appVersion.userFacing)")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Text(verbatim: "\(L("Core")) \(VersionManager.shared().coreVersion)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Text("© 2003-2015+ Dolphin Team.\n© 2025+ iCube Project.")
          .multilineTextAlignment(.center)

        Text("SwiftUI version by Joe Mattiello")
          .multilineTextAlignment(.center)

        Button("github.com/JoeMatt") {
          if let url = URL(string: "https://github.com/JoeMatt") {
            openURL(url)
          }
        }

        Button("joemattiello.dev") {
          if let url = URL(string: "https://joemattiello.dev") {
            openURL(url)
          }
        }

        Text("iCube is an unofficial and separately maintained port of Dolphin to iOS. The iCube Project has no relation to Dolphin Team.")
          .multilineTextAlignment(.center)

        // Fork lineage with tappable source links.
        VStack(spacing: 8) {
          Text(L("iCube is a fork of OatmealDome's DolphiniOS, based on the Dolphin emulator."))
            .multilineTextAlignment(.center)
            .font(.subheadline)
            .foregroundStyle(.secondary)
          VStack(spacing: 6) {
            Button("dolphinios.oatmealdome.me") {
              if let url = URL(string: "https://dolphinios.oatmealdome.me") { openURL(url) }
            }
            Button("dolphin-emu.org") {
              if let url = URL(string: "https://dolphin-emu.org") { openURL(url) }
            }
            Button("icube-emu.com") {
              if let url = URL(string: "https://icube-emu.com") { openURL(url) }
            }
          }
          .font(.callout)
        }
        .padding(.vertical, 4)

        Text("\"GameCube\" and \"Wii\" are trademarks of Nintendo. iCube is not affiliated with Nintendo in any way.")
          .multilineTextAlignment(.center)

        Text("This software should not be used to play games you do not legally own.")
          .multilineTextAlignment(.center)

        Button(L("Source Code")) {
          if let url = URL(string: "https://github.com/provenance-Emu/icube") {
            openURL(url)
          }
        }

        Color.clear.frame(height: 0)
      }
      .padding(.horizontal, 20)
      .frame(maxWidth: .infinity)
    }
    .navigationTitle(L("About iCube"))
  }

  private func startAboutAnimation() {
    animationStyle = Bool.random() ? .centerPulse : .orbitRight
    sparkleOpacity = 0.8
    switch animationStyle {
    case .centerPulse:
      logoScale = 0.94
      withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
        logoScale = 1.08
      }
    case .orbitRight:
      logoScale = 1.02
      orbitAngle = 0
      withAnimation(.linear(duration: 6.0).repeatForever(autoreverses: false)) {
        orbitAngle = 2 * .pi
      }
    }
  }
}
