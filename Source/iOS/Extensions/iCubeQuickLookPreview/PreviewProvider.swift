// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import QuickLook
import UIKit
import UniformTypeIdentifiers
import PVLibrarySnapshot

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    private static let placeholderSize = CGSize(width: 480, height: 686)
    private let telemetry = ExtensionTelemetry(.preview)

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let html = telemetry.measure(.previewBuild) { previewHTML(for: request.fileURL) }
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 600, height: 800)) { reply in
            reply.stringEncoding = .utf8
            return html
        }
    }

    private func previewHTML(for url: URL) -> Data {
        let (game, outcome) = LibraryLookup.resolveWithOutcome(url: url)
        telemetry.record(outcome)
        let filename = LibraryLookup.realFilename(from: url)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

        var coverData: Data?
        if let cover = game.coverURL {
            do {
                coverData = try Data(contentsOf: cover)
            } catch {
                telemetry.recordCoverUnreadable(error)
            }
        }
        if coverData == nil {
            coverData = PlaceholderRenderer.image(for: game, size: Self.placeholderSize).jpegData(compressionQuality: 0.85)
        }

        return Data(PreviewCard.html(game: game, filename: filename, fileSize: size, coverData: coverData).utf8)
    }
}
