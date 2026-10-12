// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
#if canImport(Network)
import Network
#endif

/// What the engine wants to know about the network and power state before
/// moving a large file. A protocol so tests can say "cellular" without a radio.
public protocol SyncNetworkObserving: Sendable {
    /// The current path is metered (cellular, hotspot) or in Low Data Mode.
    var isConstrainedOrExpensive: Bool { get }
    /// Low Power Mode is on. Periodic syncs stand down; user-initiated ones run.
    var isLowPowerModeEnabled: Bool { get }
}

/// Fixed answers, for tests and previews.
public struct StaticNetworkState: SyncNetworkObserving {
    public var isConstrainedOrExpensive: Bool
    public var isLowPowerModeEnabled: Bool

    public init(isConstrainedOrExpensive: Bool = false, isLowPowerModeEnabled: Bool = false) {
        self.isConstrainedOrExpensive = isConstrainedOrExpensive
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }

    public static let unconstrained = StaticNetworkState()
}

#if canImport(Network)
/// Live answers from `NWPathMonitor` and `ProcessInfo`.
///
/// `isExpensive` covers cellular and personal hotspots; `isConstrained` covers
/// Low Data Mode. Either one holds back opt-in categories when the user has the
/// "large files over Wi-Fi only" switch on.
public final class SyncNetworkMonitor: SyncNetworkObserving, @unchecked Sendable {

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.joemattiello.icube.sync.network")
    private let lock = NSLock()
    private var path: NWPath?

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.path = path
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    public var isConstrainedOrExpensive: Bool {
        lock.lock(); defer { lock.unlock() }
        // No path yet: assume the worst for large files. A sync that starts
        // before the first path update only holds back opt-in categories until
        // the next run, which is the cheaper mistake.
        guard let path else { return true }
        return path.isExpensive || path.isConstrained
    }

    public var isLowPowerModeEnabled: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}
#endif
