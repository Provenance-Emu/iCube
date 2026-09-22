// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Bonjour TXT codec for `ContinuityAdvertisement`.
///
/// Keys are terse because each TXT string caps at 255 bytes. Base URLs ride
/// along explicitly (`u0`, `u1`, …) rather than being resolved from the
/// endpoint, so a browser can offer a peer without opening a connection first.
public enum ContinuityTXTRecord {
    private enum Key {
        static let version = "v"
        static let sessionId = "sid"
        static let token = "tok"
        static let gameID = "gid"
        static let md5 = "md5"
        static let crc32 = "crc"
        static let displayName = "name"
        static let platform = "plat"
        static let disc = "disc"
        static let revision = "rev"
        static let stem = "stem"
        static let urlPrefix = "u"
        static let sharesLibrary = "lib"
        static let peerId = "pid"
        static let deviceType = "dt"
    }

    /// TXT records are size-limited; four candidates covers a `.local` name
    /// plus IPv4/IPv6 fallbacks with room to spare.
    private static let maxURLCandidates = 4

    /// Display names go into a 255-byte TXT string; 180 characters leaves
    /// headroom for multi-byte UTF-8 without truncating mid-character concerns
    /// reaching the wire.
    private static let maxDisplayNameLength = 180

    public static func encode(_ advertisement: ContinuityAdvertisement) -> [String: String] {
        var txt: [String: String] = [
            Key.version: String(advertisement.payloadVersion),
            Key.sessionId: advertisement.sessionId
        ]

        // Game keys ride only on session adverts. A library-presence advert has
        // no game, and a receiver requiring name+platform simply ignores it.
        if let game = advertisement.game {
            txt[Key.displayName] = String(game.displayName.prefix(maxDisplayNameLength))
            txt[Key.platform] = game.platform
            if let gameID = game.gameID { txt[Key.gameID] = gameID }
            if let md5 = game.md5 { txt[Key.md5] = md5 }
            if let crc32 = game.crc32 { txt[Key.crc32] = crc32 }
            if let disc = game.discNumber { txt[Key.disc] = String(disc) }
            if let revision = game.revision { txt[Key.revision] = String(revision) }
        }

        // An empty token means "pairing required". The key is OMITTED rather
        // than published blank — a blank value on the wire invites somebody to
        // treat the empty string as a token.
        if !advertisement.token.isEmpty { txt[Key.token] = advertisement.token }
        if advertisement.sharesLibrary { txt[Key.sharesLibrary] = "1" }
        if let peerId = advertisement.peerId { txt[Key.peerId] = peerId }
        if let deviceType = advertisement.deviceType { txt[Key.deviceType] = deviceType }
        if let stem = advertisement.saveStateStem { txt[Key.stem] = stem }

        for (index, url) in advertisement.urlCandidates.prefix(maxURLCandidates).enumerated() {
            txt["\(Key.urlPrefix)\(index)"] = url.absoluteString
        }
        return txt
    }

    public static func decode(_ txt: [String: String]) -> ContinuityAdvertisement? {
        guard
            let versionString = txt[Key.version],
            let version = Int(versionString),
            let sessionId = txt[Key.sessionId]
        else { return nil }

        // Missing token = this server requires pairing/auth to hand one out.
        let token = txt[Key.token] ?? ""

        var game: GameIdentity?
        if let displayName = txt[Key.displayName], let platform = txt[Key.platform] {
            game = GameIdentity(
                gameID: txt[Key.gameID],
                md5: txt[Key.md5],
                crc32: txt[Key.crc32],
                displayName: displayName,
                platform: platform,
                discNumber: txt[Key.disc].flatMap(Int.init),
                revision: txt[Key.revision].flatMap(Int.init)
            )
        }

        var urls: [URL] = []
        for index in 0..<maxURLCandidates {
            guard let raw = txt["\(Key.urlPrefix)\(index)"], let url = URL(string: raw) else { break }
            urls.append(url)
        }

        return ContinuityAdvertisement(
            payloadVersion: version,
            sessionId: sessionId,
            token: token,
            game: game,
            saveStateStem: txt[Key.stem],
            urlCandidates: urls,
            sharesLibrary: txt[Key.sharesLibrary] == "1",
            peerId: txt[Key.peerId],
            deviceType: txt[Key.deviceType]
        )
    }
}

/// A discovered iCube instance on the local network.
public struct ContinuityPeer: Sendable, Equatable, Identifiable {
    /// Bonjour service instance name, typically the device name.
    public var serviceName: String
    /// Decoded advertisement; nil when the TXT record is malformed or from an
    /// incompatible version.
    public var advertisement: ContinuityAdvertisement?

    public var id: String { advertisement?.sessionId ?? serviceName }

    public init(serviceName: String, advertisement: ContinuityAdvertisement?) {
        self.serviceName = serviceName
        self.advertisement = advertisement
    }

    /// True when this peer is advertising a game that can be continued.
    public var offersHandoff: Bool { advertisement?.game != nil }
}
