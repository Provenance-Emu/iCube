// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// What a serving device broadcasts so a receiving device can find and
/// authenticate a session.
///
/// Carried two ways, with **different trust properties**:
///   * In the `NSUserActivity` userInfo (Handoff). Same-user and private to
///     that iCloud account, so it carries the session token inline.
///   * In the Bonjour TXT record. LAN-visible to anything on the network, so it
///     is published **redacted** — see `redactedForBonjour()`. A receiver
///     obtains the token by pairing or by trusted-peer auth, never by reading
///     it off the wire.
public struct ContinuityAdvertisement: Codable, Hashable, Sendable {
    public var payloadVersion: Int
    public var sessionId: String
    /// Empty string means "redacted — pair or authenticate to get one".
    public var token: String
    /// nil = a library-presence advert: the app is open and sharing, but no
    /// handoff session is running. Receivers must not offer to continue a game
    /// for one.
    public var game: GameIdentity?
    /// The core-provided save-state stem, so a browsing device can show what
    /// would be resumed before committing to a pull.
    public var saveStateStem: String?
    /// Candidate base URLs, most-preferred first (Bonjour `.local` hostname,
    /// then raw-IP fallbacks). Shipped explicitly so the browser never has to
    /// resolve endpoints itself.
    public var urlCandidates: [URL]
    /// True when this device serves the nearby-library browse routes.
    public var sharesLibrary: Bool
    /// Stable pairing-identity id of the advertiser, so browsers can dedupe
    /// and address the auth flow before any trust exists.
    public var peerId: String?
    /// Device type for the pill glyph: `ip` iPhone, `pd` iPad, `tv` Apple TV,
    /// `mc` Mac.
    public var deviceType: String?

    public init(
        payloadVersion: Int = ContinuityManifest.currentVersion,
        sessionId: String,
        token: String,
        game: GameIdentity?,
        saveStateStem: String? = nil,
        urlCandidates: [URL],
        sharesLibrary: Bool = false,
        peerId: String? = nil,
        deviceType: String? = nil
    ) {
        self.payloadVersion = payloadVersion
        self.sessionId = sessionId
        self.token = token
        self.game = game
        self.saveStateStem = saveStateStem
        self.urlCandidates = urlCandidates
        self.sharesLibrary = sharesLibrary
        self.peerId = peerId
        self.deviceType = deviceType
    }
}

extension ContinuityAdvertisement: Identifiable {
    /// Session-scoped identity — drives SwiftUI sheet presentation.
    public var id: String { sessionId }
}

extension ContinuityAdvertisement {
    /// True when the receiver must pair or authenticate to obtain a token.
    public var requiresPairing: Bool { token.isEmpty }

    /// LAN-safe copy for the Bonjour TXT record: everything **except** the
    /// token.
    ///
    /// The TXT record is readable by every device on the network, including
    /// ones that will never be paired. Publishing the session token there would
    /// make pairing decorative — anybody could read the token and pull the
    /// payload without ever being approved.
    public func redactedForBonjour() -> ContinuityAdvertisement {
        var copy = self
        copy.token = ""
        return copy
    }
}

// MARK: - NSUserActivity bridging

extension ContinuityAdvertisement {
    /// The custom Handoff activity type. Must appear in the app's
    /// `NSUserActivityTypes` Info.plist array on every receiving platform, or
    /// the activity is silently never delivered.
    public static let activityType = "com.joemattiello.icube.continuity.play"

    private enum UserInfoKey {
        static let payload = "continuityAdvertisement"
    }

    /// Plist-safe encoding for `NSUserActivity.userInfo`.
    public var userInfoRepresentation: [String: Any] {
        guard let data = try? JSONEncoder().encode(self) else { return [:] }
        return [UserInfoKey.payload: data]
    }

    public init?(userInfo: [AnyHashable: Any]?) {
        guard
            let data = userInfo?[UserInfoKey.payload] as? Data,
            let decoded = try? JSONDecoder().decode(ContinuityAdvertisement.self, from: data)
        else { return nil }
        self = decoded
    }
}
