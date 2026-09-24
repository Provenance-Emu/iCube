// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import PVLibrarySnapshot

enum PreviewCard {
    static func html(game: ResolvedGame, filename: String, fileSize: Int64, coverData: Data?) -> String {
        let e = PreviewFormatting.escape
        var rows: [(String, String)] = [("Platform", game.platform.displayName)]
        if let id = game.gameID { rows.append(("Game ID", id)) }
        if let region = game.region { rows.append(("Region", region)) }
        if let disc = game.discNumber, disc > 0 { rows.append(("Disc", "\(disc + 1)")) }
        if let maker = game.makerCode { rows.append(("Maker", maker)) }
        if let tdb = game.snapshotGame?.gametdbID, tdb != game.gameID { rows.append(("GameTDB", tdb)) }
        rows.append(("File", filename))
        rows.append(("Size", PreviewFormatting.fileSizeString(fileSize)))
        if let played = PreviewFormatting.relativeDate(game.lastPlayed) { rows.append(("Last played", played)) }
        if game.isFavorite { rows.append(("Favorite", "★")) }

        let rowHTML = rows.map { "<tr><th>\(e($0.0))</th><td>\(e($0.1))</td></tr>" }.joined()
        let cover = coverData.map { "<img class=\"cover\" src=\"data:image/jpeg;base64,\($0.base64EncodedString())\" alt=\"\">" } ?? ""

        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: light dark; }
          body { margin:0; font: -apple-system-body; font-family: -apple-system, system-ui; background: Canvas; color: CanvasText; }
          .wrap { padding: 24px; display: flex; flex-direction: column; align-items: center; gap: 16px; }
          .cover { width: 240px; max-width: 70%; border-radius: 10px; box-shadow: 0 8px 24px rgba(0,0,0,.35); }
          h1 { font-size: 22px; margin: 0; text-align: center; }
          table { border-collapse: collapse; width: 100%; max-width: 480px; }
          th { text-align: left; font-weight: 600; opacity: .7; padding: 6px 12px 6px 0; white-space: nowrap; vertical-align: top; }
          td { padding: 6px 0; word-break: break-all; }
          tr + tr th, tr + tr td { border-top: 1px solid rgba(128,128,128,.25); }
        </style></head><body><div class="wrap">
        \(cover)
        <h1>\(e(game.title))</h1>
        <table>\(rowHTML)</table>
        </div></body></html>
        """
    }
}
