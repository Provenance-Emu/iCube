// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CoreGraphics

/// Which part of the frame the core drew is the game picture, for the screen filters.
///
/// The core draws into a surface the size of the view. When that view is wider or taller than the
/// picture (a phone in landscape, a TV, a wide window), the frame holds the picture with black bars
/// beside it. A filter given the whole frame treats the bars as picture: a preset that draws its own
/// TV shrinks the game to fit bars and all, and one that assumes a 4:3 source zooms in and crops.
enum ShaderPictureGeometry {
  /// The picture's rectangle inside a frame of `textureSize` pixels, or `nil` when the filters should take
  /// the whole frame: the picture already fills it, or `reported` is not usable.
  ///
  /// `reported` is the core's target rectangle in frame pixels. It can reach past the frame (a zoomed or
  /// cropped picture), so the result is the part inside it, on whole pixels.
  static func pictureRect(reported: CGRect, textureSize: CGSize) -> CGRect? {
    guard textureSize.width >= 1, textureSize.height >= 1,
          !reported.isNull, !reported.isInfinite,
          reported.origin.x.isFinite, reported.origin.y.isFinite,
          reported.width.isFinite, reported.height.isFinite else { return nil }
    let frame = CGRect(origin: .zero, size: textureSize)
    let picture = reported.integral.intersection(frame)
    guard !picture.isNull, picture.width >= 1, picture.height >= 1, picture != frame else { return nil }
    return picture
  }
}
