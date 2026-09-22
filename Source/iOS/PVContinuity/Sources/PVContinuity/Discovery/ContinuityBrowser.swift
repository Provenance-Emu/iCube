// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Network

/// The Bonjour service type iCube advertises continuity on.
///
/// Must be listed in the app's `NSBonjourServices` Info.plist array — on
/// **both** `Info.plist` and `Info-TV.plist` — or `NWBrowser` finds nothing and
/// `NetService` publishes nothing, with no error either way.
public enum ContinuityService {
    public static let type = "_icube-continuity._tcp"
}

/// Browses the local network for iCube continuity advertisements.
///
/// This is the **only** discovery path on tvOS, which has no system Handoff,
/// and the in-app fallback everywhere else.
public actor ContinuityBrowser {
    public static let serviceType = ContinuityService.type

    private var browser: NWBrowser?
    private var continuation: AsyncStream<[ContinuityPeer]>.Continuation?

    public init() {}

    /// Starts browsing and streams the full peer set on every change.
    /// Restarting replaces any previous stream.
    public func peers() -> AsyncStream<[ContinuityPeer]> {
        stop()
        let (stream, continuation) = AsyncStream.makeStream(of: [ContinuityPeer].self)
        self.continuation = continuation

        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: Self.serviceType, domain: nil)
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.browseResultsChangedHandler = { results, _ in
            let peers = results.map(Self.peer(from:)).sorted { $0.serviceName < $1.serviceName }
            continuation.yield(peers)
        }
        browser.stateUpdateHandler = { state in
            if case .failed = state { continuation.finish() }
        }
        browser.start(queue: DispatchQueue(label: "com.joemattiello.icube.continuity.browser"))
        self.browser = browser
        return stream
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        continuation?.finish()
        continuation = nil
    }

    private static func peer(from result: NWBrowser.Result) -> ContinuityPeer {
        var name = "Unknown"
        if case .service(let serviceName, _, _, _) = result.endpoint {
            name = serviceName
        }
        var advertisement: ContinuityAdvertisement?
        if case .bonjour(let txt) = result.metadata {
            advertisement = ContinuityTXTRecord.decode(txt.dictionary)
        }
        return ContinuityPeer(serviceName: name, advertisement: advertisement)
    }
}
