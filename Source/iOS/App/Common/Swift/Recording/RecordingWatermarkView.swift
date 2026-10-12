// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Corner badge drawn in the game container while recording, so ReplayKit captures it: the iCube mark,
/// a QR code for the project site, and the name, on a panel capsule; plus a `REC` tag at top trailing.
struct RecordingWatermarkView: View {
  static let markSize: CGFloat = 32
  static let qrSize: CGFloat = 40
  static let siteURL = "https://icube-emu.com"
  private static let qrScale: CGFloat = 8

  /// Generated once; nearest-neighbour scaled so the modules stay sharp at 40 pt.
  static let qrImage: UIImage? = {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(siteURL.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: qrScale, y: qrScale)),
          let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
    return UIImage(cgImage: cgImage)
  }()

  var showsWatermark = true

  var body: some View {
    ZStack {
      recTag
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
      if showsWatermark {
        badge
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
      }
    }
    .padding(ICubeDesign.Spacing.l.rawValue)
    .allowsHitTesting(false)
  }

  private var badge: some View {
    HStack(spacing: ICubeDesign.Spacing.s.rawValue) {
      Image("iCube-Logo-Square-NoText")
        .resizable()
        .scaledToFit()
        .frame(width: Self.markSize, height: Self.markSize)
      if let qr = Self.qrImage {
        Image(uiImage: qr)
          .interpolation(.none)
          .resizable()
          .scaledToFit()
          .frame(width: Self.qrSize, height: Self.qrSize)
      }
      Text("iCube")
        .icubeText(.tag)
        .foregroundStyle(ICubeDesign.color(.textPrimary))
    }
    .padding(.horizontal, ICubeDesign.Spacing.s.rawValue)
    .padding(.vertical, ICubeDesign.Spacing.xs.rawValue)
    .icubePanel()
    .accessibilityHidden(true)
  }

  private var recTag: some View {
    HStack(spacing: ICubeDesign.Spacing.xxs.rawValue) {
      Text("REC")
      Image(systemName: "circle.fill")
    }
    .icubeText(.tag)
    .foregroundStyle(ICubeDesign.color(.destructive))
    .padding(.horizontal, ICubeDesign.Spacing.s.rawValue)
    .padding(.vertical, ICubeDesign.Spacing.xxs.rawValue)
    .background(Capsule().fill(ICubeDesign.color(.rowSurface)))
    .accessibilityHidden(true)
  }
}
