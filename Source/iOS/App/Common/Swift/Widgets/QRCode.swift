// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// QR codes on every platform (`QRCodeView` is iOS-only and scales by a fractional factor).
enum QRCode {
  /// CIContext is expensive to create and thread-safe for rendering, so one serves every call.
  private static let context = CIContext()

  /// Each module becomes `scale` × `scale` pixels; drawn with `.interpolation(.none)` it stays crisp.
  static let moduleScale: CGFloat = 8

  /// A QR image for `string` with error correction M, or nil when `string` is empty.
  static func image(from string: String, scale: CGFloat = moduleScale) -> CGImage? {
    guard !string.isEmpty else { return nil }
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    return context.createCGImage(scaled, from: scaled.extent)
  }
}

/// A square, nearest-neighbour QR code for `string`; clear while `string` is empty.
struct QRCodeImage: View {
  let string: String

  var body: some View {
    if let cgImage = QRCode.image(from: string) {
      Image(decorative: cgImage, scale: 1)
        .interpolation(.none)
        .resizable()
        .aspectRatio(1, contentMode: .fit)
    } else {
      Color.clear
        .aspectRatio(1, contentMode: .fit)
    }
  }
}
