// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Keeps iCube's continuity advert on the port iCube's web server actually holds.
///
/// iFly and Provenance run their own servers on the same device and also want
/// port 80. Whoever binds first owns it, and iOS defuncts a suspended app's
/// listener, so after a resume our old port can belong to another app. An
/// advert naming it sends peers to the wrong app. So the advert is withdrawn
/// while the server is down and rebuilt from the live server when it is back.
/// Same rule as iFly's `ContinuitySessionAdvertSync`.
enum ContinuityAdvertSync {
    enum Action: Equatable {
        /// The advert already matches the live server.
        case keep
        /// The server is down: take the advert off the network.
        case withdraw
        /// The server is up on a different port or URL set (or came back after
        /// a withdraw): rebuild the advert from the live server and publish it.
        case republish
    }

    /// The upload server's bound port, or `nil` while it is down.
    ///
    /// The PVWebServer facade doesn't expose `ROMUploadServer.port`, but its
    /// `url` is built from that bound port and is `nil` unless the listener is
    /// `.ready`. So while the server reports running, the URL's port is the
    /// bound port. `URL.port` is `nil` for `http://ip/` because the server
    /// leaves `:80` out, so `nil` there means 80. With no URL there is no port:
    /// never fall back to a guess.
    static func boundPort(isRunning: Bool, url: URL?) -> Int? {
        guard isRunning, let url, url.scheme?.lowercased() == "http" else { return nil }
        return url.port ?? 80
    }

    /// The URLs a peer should try, keeping only those that reach `boundPort`.
    /// The Bonjour URL outlives a dead listener (only `stopServers()` clears it),
    /// so a stale one is dropped rather than advertised.
    static func candidates(serverURL: URL?, bonjourURL: URL?, boundPort: Int?) -> [URL] {
        guard let boundPort else { return [] }
        var result: [URL] = []
        for url in [serverURL, bonjourURL].compactMap({ $0 })
        where (url.port ?? 80) == boundPort && !result.contains(url) {
            result.append(url)
        }
        return result
    }

    static func action(serverPort: Int?, advertisedPort: Int?, candidatesChanged: Bool) -> Action {
        guard let serverPort, serverPort > 0 else {
            return advertisedPort == nil ? .keep : .withdraw
        }
        if advertisedPort != serverPort || candidatesChanged {
            return .republish
        }
        return .keep
    }
}
