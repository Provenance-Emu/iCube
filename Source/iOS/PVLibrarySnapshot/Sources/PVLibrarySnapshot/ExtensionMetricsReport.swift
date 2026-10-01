// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
#if canImport(MetricKit) && !os(tvOS)
import MetricKit
#endif

/// One custom signpost's daily aggregate as MetricKit reports it, without MetricKit types so the
/// report logic is testable everywhere.
public struct ExtensionSignpostSample: Equatable, Sendable {
    public struct Bucket: Equatable, Sendable {
        public let startMs: Double
        public let endMs: Double
        public let sampleCount: Int

        public init(startMs: Double, endMs: Double, sampleCount: Int) {
            self.startMs = startMs
            self.endMs = endMs
            self.sampleCount = sampleCount
        }
    }

    public let name: String
    public let category: String
    public let totalCount: Int
    /// Duration histogram; empty for point events.
    public let durationBuckets: [Bucket]

    public init(name: String, category: String, totalCount: Int, durationBuckets: [Bucket]) {
        self.name = name
        self.category = category
        self.totalCount = totalCount
        self.durationBuckets = durationBuckets
    }
}

#if canImport(MetricKit) && !os(tvOS)
extension ExtensionSignpostSample {
    public init(_ metric: MXSignpostMetric) {
        var buckets: [Bucket] = []
        if let histogram = metric.signpostIntervalData?.histogrammedSignpostDuration {
            for case let bucket as MXHistogramBucket<UnitDuration> in histogram.bucketEnumerator {
                buckets.append(Bucket(startMs: bucket.bucketStart.converted(to: .milliseconds).value,
                                      endMs: bucket.bucketEnd.converted(to: .milliseconds).value,
                                      sampleCount: bucket.bucketCount))
            }
        }
        self.init(name: metric.signpostName, category: metric.signpostCategory,
                  totalCount: metric.totalCount, durationBuckets: buckets)
    }
}
#endif

/// What the app's MetricKit subscriber found from the extensions' `ExtensionTelemetry` signposts in
/// one daily payload, and whether it is worth sending.
public struct ExtensionMetricsReport: Equatable, Sendable {
    public struct IntervalSummary: Equatable, Sendable {
        public let count: Int
        /// Approximate: histogram bucket midpoints weighted by count. nil without a histogram.
        public let meanMs: Double?
        /// Upper edge of the slowest non-empty bucket.
        public let maxMs: Double?
    }

    public enum Decision: Equatable, Sendable {
        /// At least one failure event: always send.
        case failures
        /// Timing only, and this payload won the sample roll.
        case timing
        case skip
    }

    /// Failure event name → count, zero counts dropped.
    public let failures: [String: Int]
    /// Interval name → summary.
    public let intervals: [String: IntervalSummary]

    private static let failureNames = Set(ExtensionTelemetry.FailureEvent.allCases.map(\.nameString))
    private static let intervalNames = Set(ExtensionTelemetry.Interval.allCases.map(\.nameString))

    public init(samples: [ExtensionSignpostSample]) {
        var failures: [String: Int] = [:]
        var intervals: [String: IntervalSummary] = [:]
        for sample in samples where sample.category == ExtensionTelemetry.signpostCategory {
            if Self.failureNames.contains(sample.name) {
                if sample.totalCount > 0 { failures[sample.name, default: 0] += sample.totalCount }
            } else if Self.intervalNames.contains(sample.name) {
                intervals[sample.name] = Self.summarize(sample)
            }
        }
        self.failures = failures
        self.intervals = intervals
    }

    public var isEmpty: Bool { failures.isEmpty && intervals.isEmpty }
    public var hasFailures: Bool { !failures.isEmpty }

    /// Failures are always sent; timing-only payloads are sampled so every device doesn't send an
    /// event every day.
    public func decision(sampleRoll: Double, timingSampleRate: Double) -> Decision {
        if hasFailures { return .failures }
        if !intervals.isEmpty && sampleRoll < timingSampleRate { return .timing }
        return .skip
    }

    /// One Sentry issue per combination of failure kinds; counts don't split it.
    public var failureFingerprint: [String] {
        ["app-extension-failure"] + failures.keys.sorted()
    }

    /// Plain property-list values for a Sentry context.
    public var sentryContext: [String: Any] {
        var timing: [String: [String: Double]] = [:]
        for (name, summary) in intervals {
            var entry: [String: Double] = ["count": Double(summary.count)]
            entry["mean_ms"] = summary.meanMs
            entry["max_ms"] = summary.maxMs
            timing[name] = entry
        }
        return ["failures": failures, "timing": timing]
    }

    private static func summarize(_ sample: ExtensionSignpostSample) -> IntervalSummary {
        let buckets = sample.durationBuckets.filter { $0.sampleCount > 0 }
        let histogramCount = buckets.reduce(0) { $0 + $1.sampleCount }
        guard histogramCount > 0 else { return IntervalSummary(count: sample.totalCount, meanMs: nil, maxMs: nil) }
        let weighted = buckets.reduce(0.0) { $0 + ($1.startMs + $1.endMs) / 2 * Double($1.sampleCount) }
        return IntervalSummary(count: max(sample.totalCount, histogramCount),
                               meanMs: weighted / Double(histogramCount),
                               maxMs: buckets.map(\.endMs).max())
    }
}
