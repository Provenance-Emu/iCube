import XCTest
@testable import PVWebServer

/// Finder writes an AppleDouble `._<name>` sidecar next to every file it copies over WebDAV.
/// Those must never be announced as uploads or left in the Software folder.
final class MetadataSidecarTests: XCTestCase {
    func testAppleDoubleSidecarIsMetadata() {
        XCTAssertTrue(ROMUploadServer.isMetadataSidecar(URL(fileURLWithPath: "/x/Software/._Super Mario Sunshine (USA).rvz")))
        XCTAssertTrue(ROMUploadServer.isMetadataSidecar(URL(fileURLWithPath: "/x/Software/sub/._game.iso")))
    }

    func testDSStoreIsMetadata() {
        XCTAssertTrue(ROMUploadServer.isMetadataSidecar(URL(fileURLWithPath: "/x/Software/.DS_Store")))
    }

    func testRealGamesAreNotMetadata() {
        XCTAssertFalse(ROMUploadServer.isMetadataSidecar(URL(fileURLWithPath: "/x/Software/Super Mario Sunshine (USA).rvz")))
        XCTAssertFalse(ROMUploadServer.isMetadataSidecar(URL(fileURLWithPath: "/x/Software/_underscore.iso")))
        XCTAssertFalse(ROMUploadServer.isMetadataSidecar(URL(fileURLWithPath: "/x/Software/.hidden.rvz")))
    }
}
