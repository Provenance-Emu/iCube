// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Publishes the continuity advertisement as a Bonjour TXT record.
///
/// Always **redacts the token** before publishing — the TXT record is visible
/// to everything on the LAN, so a token published there would make pairing
/// decorative. See `ContinuityAdvertisement.redactedForBonjour()`.
///
/// `NetService` (rather than `NWListener`'s own service) because the listener
/// here belongs to `PVWebServer`, which already publishes `_webdav._tcp` on the
/// same port for a different audience; a second `NetService` lets continuity
/// own its TXT record without touching the upload server's.
public actor ContinuityBonjourAdvertiser: ContinuityAdvertising {
    private let port: Int
    private var service: NetService?
    private let delegate = AdvertiserDelegate()

    /// - Parameter port: the port `PVWebServer` bound. Continuity rides the
    ///   same listener, so this is the upload server's port, not a new one.
    public init(port: Int) {
        self.port = port
    }

    public func publish(_ advertisement: ContinuityAdvertisement) async {
        await withdraw()
        let redacted = advertisement.redactedForBonjour()
        let txt = NetService.data(fromTXTRecord: ContinuityTXTRecord.encode(redacted).mapValues { Data($0.utf8) })

        let service = NetService(
            domain: "local.",
            type: ContinuityService.type,
            name: Self.serviceName(),
            port: Int32(port)
        )
        service.delegate = delegate
        service.setTXTRecord(txt)
        self.service = service

        // NetService schedules on the calling thread's run loop; main is the
        // only one guaranteed to be running.
        await MainActor.run { service.publish() }
    }

    public func withdraw() async {
        guard let service else { return }
        self.service = nil
        await MainActor.run { service.stop() }
    }

    /// Bonjour instance names must be unique on the network and are what the
    /// browsing user sees, so the device name is the right choice; the suffix
    /// disambiguates two devices a user gave the same name.
    private static func serviceName() -> String {
        #if canImport(UIKit) && !os(watchOS)
        let base = DeviceNameProvider.current()
        #else
        let base = Host.current().localizedName ?? "iCube"
        #endif
        return base
    }
}

/// `NetService` requires an `NSObject` delegate; publication failures are
/// logged rather than thrown because there is nothing a caller could do about
/// them synchronously — the advertisement simply never appears, and the
/// browsing side treats an absent peer as an absent peer.
private final class AdvertiserDelegate: NSObject, NetServiceDelegate, @unchecked Sendable {
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        NSLog("%@", "[ContinuityBonjourAdvertiser] failed to publish \(sender.type): \(errorDict)")
    }
}

#if canImport(UIKit) && !os(watchOS)
import UIKit

private enum DeviceNameProvider {
    static func current() -> String {
        MainActor.assumeIsolated { UIDevice.current.name }
    }
}
#endif
