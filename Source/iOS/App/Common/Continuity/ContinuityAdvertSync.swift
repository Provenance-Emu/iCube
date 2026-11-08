// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Keeps iCube's continuity advert on the port iCube's web server actually holds.
///
/// iFly and Provenance run their own servers on the same device. Each app has
/// its own home port (`ICubeServerPorts`), but whoever binds a port first owns
/// it, and iOS defuncts a suspended app's listener, so after a resume our old
/// port can be gone or belong to another app. An advert naming it sends peers
/// to the wrong app. So the advert is withdrawn
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
    /// `PVWebServer.port` is 0 unless the listener is `.ready`. Never fall back to
    /// a guess: on a shared device a guessed port can be another app's server.
    static func boundPort(serverPort: Int) -> Int? {
        serverPort > 0 ? serverPort : nil
    }

    /// The URLs a peer should try, keeping only those that reach `boundPort`.
    /// A portless `http://ip/` means port 80.
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
