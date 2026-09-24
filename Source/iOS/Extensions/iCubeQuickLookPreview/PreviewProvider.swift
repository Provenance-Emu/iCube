// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import QuickLook
import UIKit
import UniformTypeIdentifiers
import PVLibrarySnapshot

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    private static let placeholderSize = CGSize(width: 480, height: 686)

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let game = LibraryLookup.resolve(url: url)
        let filename = LibraryLookup.realFilename(from: url)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

        let coverData: Data?
        if let cover = game.coverURL, let data = try? Data(contentsOf: cover) {
            coverData = data
        } else {
            coverData = PlaceholderRenderer.image(for: game, size: Self.placeholderSize).jpegData(compressionQuality: 0.85)
        }

        let html = Data(PreviewCard.html(game: game, filename: filename, fileSize: size, coverData: coverData).utf8)
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 600, height: 800)) { reply in
            reply.stringEncoding = .utf8
            return html
        }
    }
}
