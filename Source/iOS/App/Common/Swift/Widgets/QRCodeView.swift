// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
#if os(iOS)
import CoreImage
import CoreImage.CIFilterBuiltins

public struct QRCodeView: View {
  public let text: String
  private let context = CIContext()
  private let filter = CIFilter.qrCodeGenerator()

  public init(text: String) { self.text = text }

  public var body: some View {
    GeometryReader { geo in
      if let ui = makeImage(size: geo.size) {
        Image(uiImage: ui).interpolation(.none).resizable().scaledToFit()
      } else {
        Color.clear
      }
    }
  }

  private func makeImage(size: CGSize) -> UIImage? {
    filter.message = Data(text.utf8)
    guard let output = filter.outputImage else { return nil }
    let scaleX = size.width / output.extent.size.width
    let scaleY = size.height / output.extent.size.height
    let transformed = output.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
    if let cg = context.createCGImage(transformed, from: transformed.extent) {
      return UIImage(cgImage: cg)
    }
    return nil
  }
}
#endif
