// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import Foundation
import PVLibrarySnapshot
#if os(iOS)
import UIKit
#endif

/// iCube's side of the LudiHub-style cross-app protocol Provenance also
/// speaks with iFly (PVLibrary's `EcosystemApp` / `EcosystemCallbackParser`),
/// mirrored 1:1 except identity is the 6-character disc game ID instead of an
/// md5:
///
/// - `dolphinios://gameInfo?scheme=<cb>` → reply
///   `<cb>://dolphinios?games=<base64url JSON [GamePayload]>`.
/// - `dolphinios://play?id=<id>` (existing route, handled by
///   `URLRouterService`) / `dolphinios://open?id=<id>` (alias, handled here)
///   → launch that game.
/// - `dolphinios://requestGame?id=<id>&scheme=<cb>` → user-confirmed file
///   transfer: `EcosystemShareCenter` opens a one-shot continuity session and
///   replies `<cb>://dolphinios?fetch=<base64url JSON FetchPayload>` so the
///   peer can download the file set over HTTP with the session's bearer
///   token.
///
/// Parsing (`parse`) is plain, synchronous and side-effect free so it can run
/// on any thread and be unit tested without `@MainActor`. Everything that
/// touches `UIApplication` or app state (`perform`, `openCallback`,
/// `replyWithGameList`, `peerInstalled`) is `@MainActor`.
enum EcosystemBridge {

    // MARK: - Wire types

    /// One library entry in the gameInfo reply. Field names match
    /// Provenance's `EcosystemGameScheme` exactly.
    struct GamePayload: Codable {
        var titleName: String
        var titleId: String
        var developer: String?
        var version: String?
        var iconData: String?
    }

    /// The requestGame reply: everything the peer needs to pull the game's
    /// file set from this device's continuity session. Field names are fixed
    /// by Provenance's `EcosystemFetchPayload`.
    struct FetchPayload: Codable {
        var name: String
        var md5: String
        /// Base URLs to try, most-preferred first.
        var bases: [String]
        var manifestPath: String
        var filePath: String
        var fileQueryKey: String
        var token: String
    }

    // MARK: - Incoming requests

    enum Request: Equatable {
        case gameInfo(callbackScheme: String)
        case open(gameID: String)
        case requestGame(gameID: String, callbackScheme: String)
    }

    /// Parses a `dolphinios://` URL into an ecosystem request, or nil when
    /// it's not one of the three ecosystem routes (callers fall through to
    /// the existing `play`/`dsu` handlers).
    static func parse(_ url: URL) -> Request? {
        guard url.scheme?.lowercased() == EcosystemSchemes.ownScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let query = { (name: String) -> String? in
            components.queryItems?.first { $0.name.lowercased() == name }?.value
        }
        switch components.host?.lowercased() {
        case "gameinfo":
            guard let scheme = query("scheme"), isSafeCallbackScheme(scheme) else { return nil }
            return .gameInfo(callbackScheme: scheme)
        case "open":
            guard let id = query("id"), !id.isEmpty else { return nil }
            return .open(gameID: id)
        case "requestgame":
            guard let id = query("id"), !id.isEmpty,
                  let scheme = query("scheme"), isSafeCallbackScheme(scheme) else { return nil }
            return .requestGame(gameID: id, callbackScheme: scheme)
        default:
            return nil
        }
    }

    /// Callback schemes are attacker-supplied (any app can open `dolphinios://`
    /// URLs); constrain to plain scheme charset so the reply URL can't be
    /// shaped.
    private static func isSafeCallbackScheme(_ scheme: String) -> Bool {
        !scheme.isEmpty && scheme.count <= 64 && scheme.range(
            of: "^[A-Za-z][A-Za-z0-9+.-]*$", options: .regularExpression
        ) != nil
    }

    // MARK: - Dispatch

    /// Executes a parsed request. Split from `parse` so `URLRouterService` can
    /// synchronously decide whether to claim the URL (`parse != nil`) before
    /// dispatching the actual (MainActor, possibly UI-presenting) handling.
    @MainActor
    static func perform(_ request: Request) {
        switch request {
        case .gameInfo(let callbackScheme):
            replyWithGameList(callbackScheme: callbackScheme)
        case .open(let gameID):
            GameLaunchRequest.launch(gameID: gameID)
        case .requestGame(let gameID, let callbackScheme):
            EcosystemShareCenter.shared.handleRequest(gameID: gameID, callbackScheme: callbackScheme)
        }
    }

    // MARK: - Install detection

    /// Is a peer ecosystem app installed? Only schemes listed in
    /// LSApplicationQueriesSchemes are probeable; anything else returns false.
    @MainActor
    static func peerInstalled(scheme: String) -> Bool {
        #if os(iOS)
        guard let url = URL(string: "\(scheme)://") else { return false }
        return UIApplication.shared.canOpenURL(url)
        #else
        return false
        #endif
    }

    /// Is a *fetch-capable* Provenance installed? Probes the capability
    /// marker scheme, so an old Provenance (base scheme only) returns false.
    /// Use this — not `peerInstalled(scheme: EcosystemSchemes.provenanceScheme)`
    /// — to gate the "Send to Provenance" UI.
    @MainActor
    static func peerCapable(_ marker: String = EcosystemSchemes.provenanceEcosystemScheme) -> Bool {
        peerInstalled(scheme: marker)
    }

    // MARK: - gameInfo reply

    /// Games in the gameInfo reply, most-recently-played first, capped — the
    /// list rides in a URL, so it can't grow unbounded.
    static let gameListCap = 300

    /// Answers a gameInfo query by opening the peer's callback URL with this
    /// library's game-id-identified games, from the App Group snapshot (the
    /// same one Top Shelf and Spotlight read).
    @MainActor
    static func replyWithGameList(callbackScheme: String) {
        let snapshot = LibrarySnapshotStore().load()
        let payload = snapshot.byGameID.values
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            .prefix(gameListCap)
            .map { game in
                GamePayload(
                    titleName: game.title,
                    titleId: game.id,
                    developer: makerCode(forGameID: game.id),
                    version: game.platform.displayName,
                    iconData: nil
                )
            }
        guard let data = try? JSONEncoder().encode(Array(payload)) else { return }
        openCallback(scheme: callbackScheme, query: "games", value: base64url(data))
    }

    /// Resolves a game id to a library entry, from the App Group snapshot.
    static func game(forID gameID: String) -> LibrarySnapshotGame? {
        LibrarySnapshotStore().load().game(id: gameID)
    }

    /// Nintendo disc IDs are Console(1) + GameCode(2) + Region(1) + Maker(2):
    /// the maker code is always the last two characters. Derived from the id
    /// alone (no file IO) — `DiscHeaderReader` parses the same bytes out of
    /// the disc header, but the snapshot's id already carries them.
    static func makerCode(forGameID gameID: String) -> String? {
        guard gameID.count >= 6 else { return nil }
        return String(gameID.suffix(2))
    }

    /// A stable, opaque transfer id for `FetchPayload.md5`: the first 32 hex
    /// characters (16 bytes) of SHA-256(`gameID + "/" + filename`).
    ///
    /// Hashing the disc image itself (which is what `md5` names on iFly's
    /// side) is not acceptable here — discs run to multiple gigabytes and
    /// Provenance only checks that the value looks like a hex prefix before
    /// using it to name the import container, so any stable hex id serves the
    /// same purpose without reading the file.
    static func transferId(gameID: String, filename: String) -> String {
        let digest = SHA256.hash(data: Data("\(gameID)/\(filename)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(32))
    }

    // MARK: - Callback plumbing

    /// Builds `<scheme>://dolphinios?<query>=<value>` — pure and side-effect
    /// free so it's unit-testable without touching `UIApplication`.
    static func callbackURL(scheme: String, query: String, value: String) -> URL? {
        URL(string: "\(scheme)://\(EcosystemSchemes.ownScheme)?\(query)=\(value)")
    }

    @MainActor
    static func openCallback(scheme: String, query: String, value: String,
                             completion: ((Bool) -> Void)? = nil) {
        guard let url = callbackURL(scheme: scheme, query: query, value: value) else {
            completion?(false)
            return
        }
        #if os(iOS)
        UIApplication.shared.open(url) { success in
            completion?(success)
        }
        #else
        completion?(false)
        #endif
    }

    /// base64url (RFC 4648 §5), no padding — what Provenance's parser
    /// reverses.
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
