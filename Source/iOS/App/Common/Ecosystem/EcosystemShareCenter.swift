// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVLibrarySnapshot

/// One incoming `dolphinios://requestGame` ask, awaiting the user's decision.
struct EcosystemShareRequest: Identifiable {
    let id = UUID()
    let game: LibrarySnapshotGame
    let callbackScheme: String
}

/// Hands a game's disc image to a sibling app on this device.
///
/// Both routes end in the system share sheet
/// (`EcosystemShareApprovalModifier` presents it): "Send to Provenance" in
/// the game context menu, and an approved `dolphinios://requestGame` ask from
/// a peer. The sheet lists every installed app that declares the file's type
/// (Provenance declares the GameCube and Wii disc types), and iOS copies the
/// file into that app itself.
///
/// This replaced a hand-off where iCube opened a short-lived HTTP session and
/// the peer downloaded from it after being opened by URL. On one device that
/// cannot work: opening the peer sends iCube to the background and suspends
/// the server before the first byte is fetched, so every transfer failed
/// silently. The share sheet keeps working while iCube is suspended because
/// the system, not iCube, does the copy, and it has no size limit.
///
/// File transfer to another app is deliberately user-confirmed every time,
/// even between Joe's own apps — the requesting URL is attacker-forgeable.
@MainActor
final class EcosystemShareCenter: ObservableObject {
    static let shared = EcosystemShareCenter()

    @Published var request: EcosystemShareRequest?
    /// The files the share sheet is offering, or nil when no sheet is up.
    @Published var exportItems: [URL]?
    /// Non-nil when a share couldn't start (the game's file is gone).
    /// Surfaced as an alert by `EcosystemShareApprovalModifier` so a "Send to
    /// Provenance" tap always produces visible feedback instead of silently
    /// doing nothing.
    @Published var shareError: String?

    private init() {}

    /// Entry point from `EcosystemBridge.perform`.
    func handleRequest(gameID: String, callbackScheme: String) {
        guard let game = EcosystemBridge.game(forID: gameID) else { return }
        // One ask at a time; a second requester is dropped (it can retry).
        guard request == nil else { return }
        request = EcosystemShareRequest(game: game, callbackScheme: callbackScheme)
    }

    func deny() {
        request = nil
    }

    /// Friendly peer name for user-facing messages ("provenance" → "Provenance").
    static func peerName(_ scheme: String) -> String {
        scheme.lowercased() == EcosystemSchemes.provenanceScheme ? "Provenance" : "\(scheme)://"
    }

    func approve() {
        guard let request else { return }
        self.request = nil
        offer(game: request.game)
    }

    /// User-initiated push ("Send to Provenance" in the game context menu). No
    /// confirm prompt: the user's tap IS the consent.
    func send(gameID: String) {
        guard let game = EcosystemBridge.game(forID: gameID) else {
            shareError = "That game isn\u{2019}t in the library snapshot yet. Try again in a moment."
            return
        }
        offer(game: game)
    }

    func finishExport() {
        exportItems = nil
    }

    private func offer(game: LibrarySnapshotGame) {
        guard let items = Self.exportItems(forFilePath: game.filePath) else {
            shareError = "The file for \u{201C}\(game.title)\u{201D} is missing. Rescan the library and try again."
            return
        }
        exportItems = items
    }

    /// What the share sheet offers for a game: its disc image, or nil when the
    /// file is not on disk. A game is one file on iCube (every supported disc
    /// format is single-file), so there is nothing else to bundle.
    nonisolated static func exportItems(forFilePath path: String) -> [URL]? {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return [URL(fileURLWithPath: path)]
    }
}
