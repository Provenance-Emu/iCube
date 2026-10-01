import XCTest
@testable import PVLibrarySnapshot

final class ExtensionTelemetryTests: XCTestCase {
    private struct Boom: Error {}

    func testOnlyFailuresGetASignpostEvent() {
        XCTAssertNil(ExtensionTelemetry.signpostName(for: .loaded))
        XCTAssertNil(ExtensionTelemetry.signpostName(for: .neverWritten))
        let failures: [LibrarySnapshotLoadOutcome] = [.appGroupUnavailable, .decodeFailed, .newerSchema(2)]
        let names = failures.compactMap { ExtensionTelemetry.signpostName(for: $0).map { "\($0)" } }
        XCTAssertEqual(names.count, failures.count)
        XCTAssertEqual(Set(names).count, names.count, "each failure reason has its own event name")
    }

    func testNewerSchemaVersionsShareOneEventName() {
        // MetricKit keeps a capped number of custom signposts; the version goes in the log line.
        XCTAssertEqual(ExtensionTelemetry.signpostName(for: .newerSchema(2)).map { "\($0)" },
                       ExtensionTelemetry.signpostName(for: .newerSchema(9)).map { "\($0)" })
    }

    func testMeasureReturnsTheBodyValue() {
        XCTAssertEqual(ExtensionTelemetry(.thumbnail).measure(.thumbnailLookup) { 42 }, 42)
    }

    func testMeasureRethrows() {
        XCTAssertThrowsError(try ExtensionTelemetry(.preview).measure(.previewBuild) { throw Boom() }) {
            XCTAssertTrue($0 is Boom)
        }
    }

    func testRecordingDoesNotTrap() {
        let telemetry = ExtensionTelemetry(.widget)
        for outcome: LibrarySnapshotLoadOutcome in [.loaded, .neverWritten, .appGroupUnavailable, .decodeFailed, .newerSchema(3)] {
            telemetry.record(outcome)
        }
        telemetry.recordCoverUnreadable(Boom())
    }

    func testEachSurfaceHasADistinctLogCategory() {
        let surfaces: [ExtensionTelemetry.Surface] = [.thumbnail, .preview, .topShelf, .widget]
        XCTAssertEqual(Set(surfaces.map(\.rawValue)).count, surfaces.count)
        XCTAssertEqual(ExtensionTelemetry.Surface.topShelf.rawValue, "topshelf", "matches the existing Top Shelf log category")
    }
}
