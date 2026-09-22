// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Route paths for the continuity API, shared by server and client so the two
/// can never drift.
public enum ContinuityRoutes {
    // MARK: Handoff session
    public static let manifest = "/api/continuity/manifest"
    public static let mint = "/api/continuity/mint"
    public static let file = "/api/continuity/file"

    // MARK: Pairing + trusted-peer auth. All POST, JSON bodies.
    public static let pairStart = "/api/continuity/pair/start"
    public static let pairComplete = "/api/continuity/pair/complete"
    public static let authStart = "/api/continuity/auth/start"
    public static let authComplete = "/api/continuity/auth/complete"

    public static let filePathQueryKey = "path"

    /// URL for pulling one descriptor of a session manifest.
    public static func fileURL(base: URL, relativePath: String) -> URL {
        var components = URLComponents(
            url: base.appendingPathComponent(file), resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: filePathQueryKey, value: relativePath)]
        return components?.url ?? base
    }

    public static func manifestURL(base: URL) -> URL {
        base.appendingPathComponent(manifest)
    }

    public static func mintURL(base: URL) -> URL {
        base.appendingPathComponent(mint)
    }
}
