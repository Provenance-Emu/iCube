import XCTest
@testable import PVLibrarySnapshot

final class ExtensionMetricsReportTests: XCTestCase {
    private typealias Sample = ExtensionSignpostSample
    private let category = ExtensionTelemetry.signpostCategory

    private func interval(_ name: String, _ buckets: [(Double, Double, Int)]) -> Sample {
        Sample(name: name, category: category, totalCount: buckets.reduce(0) { $0 + $1.2 },
               durationBuckets: buckets.map { Sample.Bucket(startMs: $0.0, endMs: $0.1, sampleCount: $0.2) })
    }

    private func event(_ name: String, _ count: Int, category: String? = nil) -> Sample {
        Sample(name: name, category: category ?? self.category, totalCount: count, durationBuckets: [])
    }

    func testFailuresAreCountedByName() {
        let report = ExtensionMetricsReport(samples: [event("SnapshotDecodeFailed", 3), event("CoverUnreadable", 1)])
        XCTAssertEqual(report.failures, ["SnapshotDecodeFailed": 3, "CoverUnreadable": 1])
        XCTAssertTrue(report.hasFailures)
    }

    func testOtherCategoriesAndUnknownNamesAreIgnored() {
        let report = ExtensionMetricsReport(samples: [
            event("SnapshotDecodeFailed", 2, category: "SomethingElse"),
            event("NotOurs", 5),
            interval("NotOursEither", [(0, 10, 1)]),
        ])
        XCTAssertTrue(report.isEmpty)
    }

    func testZeroCountFailuresAreDropped() {
        XCTAssertFalse(ExtensionMetricsReport(samples: [event("SnapshotNoAppGroup", 0)]).hasFailures)
    }

    func testIntervalSummaryUsesBucketMidpoints() {
        // 2 runs in 0–10 ms (midpoint 5) + 2 runs in 10–30 ms (midpoint 20) → mean 12.5, max 30.
        let report = ExtensionMetricsReport(samples: [interval("PreviewBuild", [(0, 10, 2), (10, 30, 2)])])
        let summary = report.intervals["PreviewBuild"]
        XCTAssertEqual(summary?.count, 4)
        XCTAssertEqual(summary?.meanMs ?? 0, 12.5, accuracy: 0.001)
        XCTAssertEqual(summary?.maxMs, 30)
        XCTAssertFalse(report.hasFailures)
    }

    func testIntervalWithoutHistogramStillCounts() {
        let report = ExtensionMetricsReport(samples: [Sample(name: "WidgetEntry", category: category, totalCount: 7, durationBuckets: [])])
        XCTAssertEqual(report.intervals["WidgetEntry"], .init(count: 7, meanMs: nil, maxMs: nil))
    }

    func testDecision() {
        let failing = ExtensionMetricsReport(samples: [event("SnapshotNewerSchema", 1)])
        let timingOnly = ExtensionMetricsReport(samples: [interval("TopShelfBuild", [(0, 5, 1)])])
        let empty = ExtensionMetricsReport(samples: [])
        XCTAssertEqual(failing.decision(sampleRoll: 0.99, timingSampleRate: 0.1), .failures, "failures are never sampled out")
        XCTAssertEqual(timingOnly.decision(sampleRoll: 0.05, timingSampleRate: 0.1), .timing)
        XCTAssertEqual(timingOnly.decision(sampleRoll: 0.5, timingSampleRate: 0.1), .skip)
        XCTAssertEqual(empty.decision(sampleRoll: 0, timingSampleRate: 1), .skip)
    }

    func testFingerprintIsSortedAndStable() {
        let a = ExtensionMetricsReport(samples: [event("SnapshotDecodeFailed", 1), event("CoverUnreadable", 4)])
        let b = ExtensionMetricsReport(samples: [event("CoverUnreadable", 9), event("SnapshotDecodeFailed", 2)])
        XCTAssertEqual(a.failureFingerprint, ["app-extension-failure", "CoverUnreadable", "SnapshotDecodeFailed"])
        XCTAssertEqual(a.failureFingerprint, b.failureFingerprint, "counts don't split the issue")
    }

    func testContextShape() {
        let report = ExtensionMetricsReport(samples: [event("CoverUnreadable", 2), interval("ThumbnailLookup", [(0, 4, 1)])])
        let context = report.sentryContext
        XCTAssertEqual(context["failures"] as? [String: Int], ["CoverUnreadable": 2])
        let timing = context["timing"] as? [String: [String: Double]]
        XCTAssertEqual(timing?["ThumbnailLookup"]?["count"], 1)
        XCTAssertEqual(timing?["ThumbnailLookup"]?["mean_ms"], 2)
        XCTAssertEqual(timing?["ThumbnailLookup"]?["max_ms"], 4)
    }

    func testKnownNamesMatchTheTelemetryEnums() {
        XCTAssertEqual(Set(ExtensionTelemetry.FailureEvent.allCases.map(\.nameString)),
                       ["SnapshotNoAppGroup", "SnapshotDecodeFailed", "SnapshotNewerSchema", "CoverUnreadable"])
        XCTAssertEqual(Set(ExtensionTelemetry.Interval.allCases.map(\.nameString)),
                       ["ThumbnailLookup", "PreviewBuild", "TopShelfBuild", "WidgetEntry"])
    }
}
