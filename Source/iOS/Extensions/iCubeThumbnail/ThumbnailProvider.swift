// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import UIKit
import QuickLookThumbnailing
import PVLibrarySnapshot

/// Files app / Finder thumbnails for GameCube and Wii disc images. Reads at most
/// 64 KiB of the file for the header and one mirrored JPEG from the App Group.
/// Never returns an error for a readable file: unknown discs get a drawn placeholder.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let game = LibraryLookup.resolve(url: request.fileURL)

        if let cover = game.coverURL {
            handler(QLThumbnailReply(imageFileURL: cover), nil)
            return
        }

        // Poster aspect inside the requested box, so the tile matches real covers.
        let box = request.maximumSize
        let posterAspect: CGFloat = 0.7
        let size = box.width / box.height > posterAspect
            ? CGSize(width: (box.height * posterAspect).rounded(), height: box.height)
            : CGSize(width: box.width, height: (box.width / posterAspect).rounded())

        handler(QLThumbnailReply(contextSize: size, currentContextDrawing: {
            guard let context = UIGraphicsGetCurrentContext() else { return false }
            PlaceholderRenderer.draw(game, in: context, size: size)
            return true
        }), nil)
    }
}
