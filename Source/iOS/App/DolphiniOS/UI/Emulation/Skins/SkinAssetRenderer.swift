// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import UIKit

/// Turns a skin's PDF or PNG asset file into a `UIImage` at a target size.
/// Asset names come from third-party `info.json` files, so a name that would resolve outside the skin's folder is refused.
enum SkinAssetRenderer {
  /// Largest pixel dimension a rasterized PDF may have (the larger of width and height).
  static let maxPixelDimension: CGFloat = 4096

  private static let pdfExtension = "pdf"
  private static let firstPDFPage = 1
  private static let parentComponent = ".."
  private static let cacheKeySeparator = "|"
  private static let cache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.name = "SkinAssetRenderer"
    return cache
  }()

  /// Returns the asset at `directory/name`, or nil when the name is empty or unsafe, the file is missing, or it cannot be decoded.
  /// A PDF is rasterized to fill `size × scale` pixels (clamped to `maxPixelDimension`, keeping the aspect ratio); any other file is decoded as-is.
  static func image(named name: String, in directory: URL, size: CGSize, scale: CGFloat) -> UIImage? {
    guard size.width > 0, size.height > 0, scale > 0,
          let url = resolvedURL(named: name, in: directory) else { return nil }

    let key = cacheKey(for: url, size: size, scale: scale)
    if let cached = cache.object(forKey: key) { return cached }

    let image: UIImage?
    if url.pathExtension.lowercased() == pdfExtension {
      image = rasterizePDF(at: url, size: size, scale: scale)
    } else {
      image = UIImage(contentsOfFile: url.path)
    }
    if let image { cache.setObject(image, forKey: key) }
    return image
  }

  // MARK: - Path safety

  /// The existing file `name` points to inside `directory`, with symlinks resolved, or nil when it is empty, absolute, climbs out with `..`, or resolves outside.
  private static func resolvedURL(named name: String, in directory: URL) -> URL? {
    guard !name.isEmpty, !name.hasPrefix("/") else { return nil }
    let components = name.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.contains(where: { $0 == parentComponent }) else { return nil }

    let root = directory.standardizedFileURL.resolvingSymlinksInPath()
    let candidate = root.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
    guard candidate.path.hasPrefix(root.path + "/"),
          FileManager.default.fileExists(atPath: candidate.path) else { return nil }
    return candidate
  }

  // MARK: - Cache

  private static func cacheKey(for url: URL, size: CGSize, scale: CGFloat) -> NSString {
    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
    return [url.path, "\(size.width)x\(size.height)", "\(scale)", "\(modified)"].joined(separator: cacheKeySeparator) as NSString
  }

  // MARK: - PDF

  private static func rasterizePDF(at url: URL, size: CGSize, scale: CGFloat) -> UIImage? {
    guard let document = CGPDFDocument(url as CFURL),
          let page = document.page(at: firstPDFPage) else { return nil }
    let pageRect = page.getBoxRect(.mediaBox)
    guard pageRect.width > 0, pageRect.height > 0 else { return nil }

    var pixelWidth = (size.width * scale).rounded()
    var pixelHeight = (size.height * scale).rounded()
    let longSide = max(pixelWidth, pixelHeight)
    if longSide > maxPixelDimension {
      let shrink = maxPixelDimension / longSide
      pixelWidth = (pixelWidth * shrink).rounded()
      pixelHeight = (pixelHeight * shrink).rounded()
    }
    guard pixelWidth >= 1, pixelHeight >= 1 else { return nil }

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: pixelWidth, height: pixelHeight), format: format)
    let rendered = renderer.image { context in
      let cgContext = context.cgContext
      // PDF space is bottom-left origin: flip, then stretch the page over the whole target rect.
      cgContext.translateBy(x: 0, y: pixelHeight)
      cgContext.scaleBy(x: pixelWidth / pageRect.width, y: -pixelHeight / pageRect.height)
      cgContext.translateBy(x: -pageRect.minX, y: -pageRect.minY)
      cgContext.drawPDFPage(page)
    }
    guard let cgImage = rendered.cgImage else { return nil }
    // Keep the logical size the caller asked for, even when the pixel cap shrank the bitmap.
    return UIImage(cgImage: cgImage, scale: pixelWidth / size.width, orientation: .up)
  }
}
#endif
