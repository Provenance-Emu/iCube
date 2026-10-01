// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import os
#if canImport(MetricKit) && !os(tvOS)
import MetricKit
#endif

/// Timing and failure records for the app extensions (Quick Look thumbnail and preview, Top Shelf,
/// the Recent Games widget).
///
/// Two channels, because neither reaches every case:
/// - Unified log (`Logger`): failures at `.error`, one `.notice` per run. Both are persisted, so
///   they appear in a sysdiagnose and in Console. This is the only channel that can carry
///   `appGroupUnavailable` (it can't be written into the group it's reporting as missing) and the
///   only one on tvOS.
/// - MetricKit signposts (`mxSignpost` on a `MXMetricManager.makeLogHandle` log). Extensions can't
///   subscribe to MetricKit themselves (Apple DTS: not a supported workflow), so these can at best
///   arrive in the containing app's daily payload. MetricKit doesn't exist on tvOS; there the same
///   signposts go to a plain `OSLog` and are visible in Instruments only. (The tvOS SDK still
///   ships a MetricKit module with every API marked unavailable, so `canImport` alone isn't enough.)
///
/// MetricKit keeps a capped number of custom signposts, so names are a small fixed set: one
/// interval per extension plus one event per failure reason, shared by every extension.
public struct ExtensionTelemetry {
    public enum Surface: String {
        case thumbnail, preview, topShelf = "topshelf", widget
    }

    /// The one timed operation per extension.
    public enum Interval: CaseIterable {
        case thumbnailLookup, previewBuild, topShelfBuild, widgetEntry

        var name: StaticString {
            switch self {
            case .thumbnailLookup: return "ThumbnailLookup"
            case .previewBuild: return "PreviewBuild"
            case .topShelfBuild: return "TopShelfBuild"
            case .widgetEntry: return "WidgetEntry"
            }
        }

        /// The name as MetricKit reports it back (`MXSignpostMetric.signpostName`).
        public var nameString: String { "\(name)" }
    }

    /// Point events, counted per day by MetricKit. Shared by every extension.
    public enum FailureEvent: CaseIterable {
        case snapshotNoAppGroup, snapshotDecodeFailed, snapshotNewerSchema, coverUnreadable

        /// nil for outcomes that aren't failures.
        init?(_ outcome: LibrarySnapshotLoadOutcome) {
            switch outcome {
            case .loaded, .neverWritten: return nil
            case .appGroupUnavailable: self = .snapshotNoAppGroup
            case .decodeFailed: self = .snapshotDecodeFailed
            case .newerSchema: self = .snapshotNewerSchema
            }
        }

        var name: StaticString {
            switch self {
            case .snapshotNoAppGroup: return "SnapshotNoAppGroup"
            case .snapshotDecodeFailed: return "SnapshotDecodeFailed"
            case .snapshotNewerSchema: return "SnapshotNewerSchema"
            case .coverUnreadable: return "CoverUnreadable"
            }
        }

        public var nameString: String { "\(name)" }
    }

    static let subsystem = "com.joemattiello.iCube"
    /// `MXSignpostMetric.signpostCategory` of everything recorded here; the app's
    /// `ExtensionMetricsReport` filters on it.
    public static let signpostCategory = "Extensions"

    public let surface: Surface
    private let logger: Logger
    private let signpostLog: OSLog

    public init(_ surface: Surface) {
        self.surface = surface
        logger = Logger(subsystem: Self.subsystem, category: surface.rawValue)
        #if canImport(MetricKit) && !os(tvOS)
        signpostLog = MXMetricManager.makeLogHandle(category: Self.signpostCategory)
        #else
        signpostLog = OSLog(subsystem: Self.subsystem, category: Self.signpostCategory)
        #endif
    }

    /// Runs `body` inside a signpost interval and logs how long it took.
    public func measure<T>(_ interval: Interval, _ body: () throws -> T) rethrows -> T {
        let id = OSSignpostID(log: signpostLog)
        let start = ContinuousClock.now
        signpost(.begin, interval.name, id)
        defer {
            signpost(.end, interval.name, id)
            let ms = (ContinuousClock.now - start) / .milliseconds(1)
            logger.notice("\(String(describing: interval.name), privacy: .public) took \(ms, format: .fixed(precision: 1)) ms")
        }
        return try body()
    }

    /// Records a snapshot load that came back empty for a reason other than "never written".
    public func record(_ outcome: LibrarySnapshotLoadOutcome) {
        guard let event = FailureEvent(outcome) else { return }
        if case .newerSchema(let version) = outcome {
            logger.error("""
                snapshot load failed: \(outcome.reason, privacy: .public) \
                (on disk \(version), understood \(LibrarySnapshot.currentSchemaVersion))
                """)
        } else {
            logger.error("snapshot load failed: \(outcome.reason, privacy: .public)")
        }
        signpost(.event, event.name, .exclusive)
    }

    /// The snapshot named a cover file that exists but couldn't be read.
    public func recordCoverUnreadable(_ error: Error) {
        // Domain and code are public so a permissions failure and a missing file stay
        // distinguishable off-device; the description may hold a path, so it stays private.
        let nsError = error as NSError
        logger.error("""
            cover unreadable: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public) \
            \(String(describing: error))
            """)
        signpost(.event, FailureEvent.coverUnreadable.name, .exclusive)
    }

    private func signpost(_ type: OSSignpostType, _ name: StaticString, _ id: OSSignpostID) {
        #if canImport(MetricKit) && !os(tvOS)
        mxSignpost(type, log: signpostLog, name: name, signpostID: id)
        #else
        os_signpost(type, log: signpostLog, name: name, signpostID: id)
        #endif
    }
}
