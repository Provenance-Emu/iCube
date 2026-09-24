// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import UIKit
import PVLibrarySnapshot

struct CoverJob: @unchecked Sendable {
  let gameID: String
  let image: UIImage
}

/// Writes 1280 px JPEG mirrors of cover art into the App Group so extensions can read
/// them. tvOS `.poster` @2x is 808×1216; anything smaller renders blank tiles.
enum CoverMirror {
  static let maxEdge: CGFloat = 1280
  static let jpegQuality: CGFloat = 0.85
  private static var loggedUnavailable = false

  /// Skips files that already exist. Safe to call from any queue.
  static func mirror(_ jobs: [CoverJob]) {
    guard let dir = LibrarySnapshotAppGroup.mediaDirectory else {
      if !loggedUnavailable {
        loggedUnavailable = true
        NSLog("[Snapshot] App Group container unavailable; cover mirroring skipped")
      }
      return
    }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for job in jobs {
      let url = dir.appendingPathComponent(LibrarySnapshotAppGroup.coverFilename(gameID: job.gameID))
      if FileManager.default.fileExists(atPath: url.path) { continue }
      guard let data = jpegData(job.image) else { continue }
      try? data.write(to: url, options: .atomic)
    }
  }

  static func jpegData(_ image: UIImage) -> Data? {
    let size = image.size
    let scale = min(1, maxEdge / max(size.width * image.scale, size.height * image.scale))
    let target = CGSize(width: (size.width * image.scale * scale).rounded(),
                        height: (size.height * image.scale * scale).rounded())
    guard target.width > 0, target.height > 0 else { return nil }
    let format = UIGraphicsImageRendererFormat.preferred()
    format.scale = 1
    format.opaque = true
    let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: target))
    }
    return rendered.jpegData(compressionQuality: jpegQuality)
  }
}
