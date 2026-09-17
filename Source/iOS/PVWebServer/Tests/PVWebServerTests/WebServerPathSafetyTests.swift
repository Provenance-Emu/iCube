import XCTest
@testable import PVWebServer

final class WebServerPathSafetyTests: XCTestCase {
    private let base = URL(fileURLWithPath: "/tmp/icube-roms", isDirectory: true)

    func testInsideSandboxIsOK() {
        guard case .ok(let url) = WebServerPathSafety.resolve("Wii/Game.rvz", within: base) else {
            return XCTFail("expected .ok")
        }
        XCTAssertTrue(url.path.hasPrefix(base.standardized.path))
    }

    func testEmptyPathResolvesToBase() {
        guard case .ok(let url) = WebServerPathSafety.resolve("", within: base) else {
            return XCTFail("expected .ok")
        }
        XCTAssertEqual(url.standardized.path, base.standardized.path)
    }

    func testDotDotTraversalRejected() {
        XCTAssertEqual(WebServerPathSafety.resolve("../secrets.txt", within: base), .lexicalEscape)
        XCTAssertEqual(WebServerPathSafety.resolve("a/b/../../../etc/passwd", within: base), .lexicalEscape)
    }

    func testSiblingPrefixNotAccepted() {
        XCTAssertEqual(WebServerPathSafety.resolve("../icube-roms-evil/x", within: base), .lexicalEscape)
    }

    func testSymlinkEscapeRejected() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("icube-pathtest-\(ProcessInfo.processInfo.globallyUniqueString)")
        let outside = fm.temporaryDirectory.appendingPathComponent("icube-outside-\(ProcessInfo.processInfo.globallyUniqueString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: outside) }
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)

        XCTAssertEqual(WebServerPathSafety.resolve("link/file", within: root), .symlinkEscape)
        // A file that does not exist yet under the symlinked dir (the PUT-new-file case).
        XCTAssertEqual(WebServerPathSafety.resolve("link/new/deeper.bin", within: root), .symlinkEscape)
    }

    func testTmpToPrivateTmpSymlinkIsNotAFalseReject() throws {
        // macOS/iOS: /tmp -> /private/tmp. Base and target resolve the same way.
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("icube-real-\(ProcessInfo.processInfo.globallyUniqueString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        guard case .ok = WebServerPathSafety.resolve("game.iso", within: root) else {
            return XCTFail("expected .ok through the /tmp symlink")
        }
    }
}
