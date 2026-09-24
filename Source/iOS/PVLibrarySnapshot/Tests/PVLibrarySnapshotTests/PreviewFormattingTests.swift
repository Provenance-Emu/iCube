import XCTest
@testable import PVLibrarySnapshot

final class PreviewFormattingTests: XCTestCase {
    func testEscapesHTML() {
        XCTAssertEqual(PreviewFormatting.escape("Tom & \"Jerry\" <3"), "Tom &amp; &quot;Jerry&quot; &lt;3")
    }

    func testFileSize() {
        XCTAssertEqual(PreviewFormatting.fileSizeString(0), "0 bytes")
        XCTAssertEqual(PreviewFormatting.fileSizeString(1_459_978_240), "1.46 GB")
        XCTAssertEqual(PreviewFormatting.fileSizeString(4_699_979_776), "4.7 GB")
    }

    func testRelativeDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(PreviewFormatting.relativeDate(now.addingTimeInterval(-30), now: now), "Just now")
        XCTAssertEqual(PreviewFormatting.relativeDate(now.addingTimeInterval(-3 * 3600), now: now), "3 hours ago")
        XCTAssertEqual(PreviewFormatting.relativeDate(now.addingTimeInterval(-2 * 86400), now: now), "2 days ago")
        XCTAssertNil(PreviewFormatting.relativeDate(nil, now: now))
    }
}
