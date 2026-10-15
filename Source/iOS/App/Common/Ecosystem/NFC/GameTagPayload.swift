// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The NDEF contents of a "tap to play" tag, shared by iCube, Provenance and
/// iFly so a tag written by one app is unambiguous to the others:
///
/// - record 1: a Well-Known URI record with the writing app's own launch URL
///   (iCube: `dolphinios://play?id=<game id>`);
/// - record 2: a Well-Known Text record, language "en",
///   `app=<bundle id>;title=<game title>`.
///
/// A reader accepts only a URI with its own scheme and route; a sibling's URI
/// (`provenance://`, `ifly://`) is reported as belonging to that app and
/// nothing else happens. Pure strings and URLs, so it compiles and tests on
/// every platform; `GameTagCenter` does the CoreNFC part.
struct GameTagPayload: Equatable {
    static let launchHost = "play"
    static let launchQueryKey = "id"
    static let textLanguage = "en"
    static let appField = "app"
    static let titleField = "title"
    /// What this app writes into the text record's `app` field.
    static let ownAppID = "com.joemattiello.iCube"

    /// Sibling apps, by launch-URL scheme or universal-link host.
    enum Sibling: String, CaseIterable {
        case provenance = "provenance"
        case ifly = "ifly"

        var displayName: String {
            switch self {
            case .provenance: return "Provenance"
            case .ifly: return "iFly"
            }
        }

        /// Hosts of the sibling's universal links (Provenance writes
        /// `https://provenance-emu.com/game/<MD5>`).
        var hosts: [String] {
            switch self {
            case .provenance: return ["provenance-emu.com", "provenance.app"]
            case .ifly: return ["ifly-emu.com"]
            }
        }

        static func matching(host: String) -> Sibling? {
            allCases.first { sibling in sibling.hosts.contains { host == $0 || host.hasSuffix("." + $0) } }
        }
    }

    /// Host of this app's universal links; `https://icube-emu.com/play?id=<id>` is
    /// accepted as our own once the site serves an apple-app-site-association file.
    static let ownHost = "icube-emu.com"

    /// What a scanned tag turned out to be.
    enum Classification: Equatable {
        /// One of ours: launch this game.
        case own(gameID: String)
        /// A sibling app's tag.
        case sibling(Sibling)
        /// Not a game tag.
        case unknown
    }

    let launchURL: URL
    let appID: String
    let title: String

    /// The tag for one of this app's games.
    init?(gameID: String, title: String) {
        guard let url = Self.launchURL(gameID: gameID) else { return nil }
        launchURL = url
        appID = Self.ownAppID
        self.title = title
    }

    init(launchURL: URL, appID: String, title: String) {
        self.launchURL = launchURL
        self.appID = appID
        self.title = title
    }

    /// `dolphinios://play?id=<gameID>`: the route `URLRouterService` already serves.
    static func launchURL(gameID: String) -> URL? {
        let trimmed = gameID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = EcosystemSchemes.ownScheme
        components.host = launchHost
        components.queryItems = [URLQueryItem(name: launchQueryKey, value: trimmed)]
        return components.url
    }

    /// The text record: `app=<bundle id>;title=<title>`. A `;` in the title is
    /// dropped so the record stays parseable.
    var textRecord: String {
        let safeTitle = title.replacingOccurrences(of: ";", with: " ")
        return "\(Self.appField)=\(appID);\(Self.titleField)=\(safeTitle)"
    }

    /// Parses `app=…;title=…`. Returns the fields, or nil when `app` is missing.
    static func parseTextRecord(_ text: String) -> (appID: String, title: String)? {
        var fields: [String: String] = [:]
        for part in text.split(separator: ";", omittingEmptySubsequences: true) {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = part[..<eq].trimmingCharacters(in: .whitespaces)
            let value = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        guard let app = fields[appField], !app.isEmpty else { return nil }
        return (app, fields[titleField] ?? "")
    }

    /// Classifies a tag's URI: ours (with the game id), a sibling's, or not a game tag.
    static func classify(_ url: URL) -> Classification {
        guard let scheme = url.scheme?.lowercased() else { return .unknown }
        let host = url.host?.lowercased() ?? ""
        if scheme == EcosystemSchemes.ownScheme, host == launchHost {
            return gameID(in: url).map { .own(gameID: $0) } ?? .unknown
        }
        if scheme == "https", host == ownHost || host.hasSuffix("." + ownHost) {
            guard url.path.lowercased() == "/" + launchHost, let id = gameID(in: url) else { return .unknown }
            return .own(gameID: id)
        }
        if let sibling = Sibling(rawValue: scheme) { return .sibling(sibling) }
        if scheme == "https", let sibling = Sibling.matching(host: host) { return .sibling(sibling) }
        return .unknown
    }

    private static func gameID(in url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = components.queryItems?.first(where: { $0.name == launchQueryKey })?.value,
              !id.isEmpty else { return nil }
        return id
    }

    /// Rebuilds a payload from the two records a tag carries; nil without a URI.
    static func from(uri: URL?, text: String?) -> GameTagPayload? {
        guard let uri else { return nil }
        let parsed = text.flatMap(parseTextRecord)
        return GameTagPayload(launchURL: uri, appID: parsed?.appID ?? "", title: parsed?.title ?? "")
    }
}
