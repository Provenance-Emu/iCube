// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import Foundation

/// Validates the per-session bearer token on every continuity route.
///
/// This is enforced, not decorative: no valid token, no bytes. It is also the
/// **only** thing standing between a peer and the payload — the transport is
/// plain HTTP with no TLS, so the token controls who may *ask* for bytes and
/// controls nothing at all about who may *read* bytes already in flight. See
/// the transport note at the top of `PVWebServer/WebRoute.swift`.
public struct BearerTokenValidator: Sendable {
    private let expectedDigest: SHA256Digest

    public init(token: String) {
        self.expectedDigest = SHA256.hash(data: Data(token.utf8))
    }

    /// Mints a 256-bit random token, base64url-encoded.
    public static func mintToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Accepts `Authorization: Bearer <token>`.
    ///
    /// The comparison is over SHA-256 digests rather than the raw strings:
    /// `Digest`'s `==` is fixed-width, so a wrong token leaks no information
    /// about how many leading characters were right.
    public func validate(authorizationHeader: String?) -> Bool {
        guard let authorizationHeader else { return false }
        let prefix = "Bearer "
        guard authorizationHeader.hasPrefix(prefix) else { return false }
        let presented = String(authorizationHeader.dropFirst(prefix.count))
        return SHA256.hash(data: Data(presented.utf8)) == expectedDigest
    }
}
