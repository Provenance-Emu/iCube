// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import UIKit
import PVLibrarySnapshot

/// Draws the no-cover tile: platform-tinted gradient, platform glyph, game id (or
/// filename-derived title). Used by the thumbnail reply and the preview fallback.
enum PlaceholderRenderer {
    static func colors(for platform: LibraryPlatform) -> (top: UIColor, bottom: UIColor) {
        switch platform {
        case .gamecube, .triforce:
            return (UIColor(red: 0.42, green: 0.32, blue: 0.68, alpha: 1), UIColor(red: 0.20, green: 0.13, blue: 0.38, alpha: 1))
        case .wii, .wiiware:
            return (UIColor(red: 0.93, green: 0.95, blue: 0.98, alpha: 1), UIColor(red: 0.55, green: 0.70, blue: 0.90, alpha: 1))
        case .elfdol, .unknown:
            return (UIColor(white: 0.40, alpha: 1), UIColor(white: 0.16, alpha: 1))
        }
    }

    static func glyph(for platform: LibraryPlatform) -> String {
        switch platform {
        case .gamecube, .triforce: return "🟪"
        case .wii, .wiiware: return "⬜️"
        case .elfdol, .unknown: return "🎮"
        }
    }

    /// Draws into the current graphics context. `size` is the full tile.
    static func draw(_ game: ResolvedGame, in context: CGContext, size: CGSize) {
        let palette = colors(for: game.platform)
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [palette.top.cgColor, palette.bottom.cgColor] as CFArray,
                                     locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }

        let isLight = game.platform == .wii || game.platform == .wiiware
        let textColor: UIColor = isLight ? UIColor(white: 0.12, alpha: 1) : .white

        let glyph = glyph(for: game.platform) as NSString
        let glyphFont = UIFont.systemFont(ofSize: min(size.width, size.height) * 0.36)
        let glyphSize = glyph.size(withAttributes: [.font: glyphFont])
        glyph.draw(at: CGPoint(x: (size.width - glyphSize.width) / 2, y: size.height * 0.22), withAttributes: [.font: glyphFont])

        let label = (game.gameID ?? game.title) as NSString
        let labelFont = UIFont.monospacedSystemFont(ofSize: max(8, min(size.width, size.height) * 0.11), weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: textColor, .paragraphStyle: paragraph]
        let inset = size.width * 0.08
        label.draw(in: CGRect(x: inset, y: size.height * 0.68, width: size.width - inset * 2, height: labelFont.lineHeight * 2), withAttributes: attrs)
    }

    static func image(for game: ResolvedGame, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            draw(game, in: ctx.cgContext, size: size)
        }
    }
}
