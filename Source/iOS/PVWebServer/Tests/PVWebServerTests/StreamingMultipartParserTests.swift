import XCTest
@testable import PVWebServer

final class StreamingMultipartParserTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("icube-mp-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func multipart(boundary: String, filename: String, body: Data) -> Data {
        var d = Data()
        d.append(Data("--\(boundary)\r\n".utf8))
        d.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n\r\n".utf8))
        d.append(body)
        d.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return d
    }

    private func finalize(_ parser: StreamingMultipartParser) {
        let done = expectation(description: "finalize")
        parser.finalize { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testSingleFileWrittenToDisk() throws {
        let parser = StreamingMultipartParser(boundary: "B0", outputDirectory: dir)
        let content = Data("ROM-CONTENTS-123".utf8)
        parser.feed(multipart(boundary: "B0", filename: "game.iso", body: content))
        finalize(parser)
        XCTAssertFalse(parser.hadWriteError)
        XCTAssertEqual(parser.completedFiles.count, 1)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("game.iso")), content)
    }

    func testSubfolderStrippedToFilename() throws {
        let parser = StreamingMultipartParser(boundary: "B1", outputDirectory: dir)
        parser.feed(multipart(boundary: "B1", filename: "Wii/game.rvz", body: Data("x".utf8)))
        finalize(parser)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("game.rvz").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Wii/game.rvz").path))
    }

    func testTraversalFilenameNotWrittenOutsideDir() throws {
        let parser = StreamingMultipartParser(boundary: "B2", outputDirectory: dir)
        parser.feed(multipart(boundary: "B2", filename: "../escape.bin", body: Data("x".utf8)))
        finalize(parser)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("escape.bin").path))
    }

    func testBodySplitAcrossFeeds() throws {
        let parser = StreamingMultipartParser(boundary: "B3", outputDirectory: dir)
        let full = multipart(boundary: "B3", filename: "split.bin", body: Data(repeating: 0x41, count: 5000))
        var idx = full.startIndex
        while idx < full.endIndex {
            let end = full.index(idx, offsetBy: 512, limitedBy: full.endIndex) ?? full.endIndex
            parser.feed(Data(full[idx..<end]))
            idx = end
        }
        finalize(parser)
        let written = try Data(contentsOf: dir.appendingPathComponent("split.bin"))
        XCTAssertEqual(written.count, 5000)
        XCTAssertTrue(written.allSatisfy { $0 == 0x41 })
    }

    func testWriteFailureIsSurfacedAndFileNotCompleted() throws {
        // A read-only output directory makes createFile fail: writer is nil, part is skipped,
        // but hadWriteError must still be reported so the caller answers 5xx.
        let ro = dir.appendingPathComponent("ro")
        try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: ro.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ro.path) }
        let parser = StreamingMultipartParser(boundary: "B4", outputDirectory: ro)
        parser.feed(multipart(boundary: "B4", filename: "nope.bin", body: Data("x".utf8)))
        finalize(parser)
        XCTAssertTrue(parser.hadWriteError)
        XCTAssertTrue(parser.completedFiles.isEmpty)
    }

    private func multipart(boundary: String, parts: [(name: String, body: Data)]) -> Data {
        var d = Data()
        for part in parts {
            d.append(Data("--\(boundary)\r\n".utf8))
            d.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(part.name)\"\r\n\r\n".utf8))
            d.append(part.body)
            d.append(Data("\r\n".utf8))
        }
        d.append(Data("--\(boundary)--\r\n".utf8))
        return d
    }

    /// The socket died mid-body. `abort()` marks the parser truncated so `finalize` deletes the
    /// partial file and reports failure — it used to finish like a clean upload, append to
    /// `completedFiles`, fire `onFileCompleted` (posting the import notification) and answer 200.
    func testTruncatedBodyIsNotReportedAsSuccess() throws {
        let parser = StreamingMultipartParser(boundary: "B5", outputDirectory: dir)
        let full = multipart(boundary: "B5", filename: "half.iso", body: Data(repeating: 0x42, count: 4096))
        // Split mid-body: past the part headers, well before the closing boundary.
        let half = Data(full.prefix(full.count / 2))
        parser.feed(half)
        parser.abort()
        finalize(parser)

        XCTAssertTrue(parser.hadWriteError, "a truncated upload must be a failure")
        XCTAssertTrue(parser.completedFiles.isEmpty, "a truncated upload must not be announced as completed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("half.iso").path),
                       "the partial file must be deleted")
    }

    func testTruncatedBodyDoesNotFireOnFileCompleted() throws {
        var announced: [String] = []
        let parser = StreamingMultipartParser(boundary: "B6", outputDirectory: dir,
                                              onFileCompleted: { announced.append($0) })
        let full = multipart(boundary: "B6", filename: "half2.iso", body: Data(repeating: 0x43, count: 4096))
        parser.feed(Data(full.prefix(full.count / 2)))
        parser.abort()
        finalize(parser)
        XCTAssertTrue(announced.isEmpty)
    }

    /// One good part, one whose target name is already taken by a directory (so the writer
    /// cannot open). The good file still completes; the failure is still surfaced.
    func testMixedPartsReportOneCompletedFileAndAWriteError() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("blocked.bin"),
                                                withIntermediateDirectories: true)
        let parser = StreamingMultipartParser(boundary: "B7", outputDirectory: dir)
        parser.feed(multipart(boundary: "B7", parts: [
            ("good.bin", Data("GOOD".utf8)),
            ("blocked.bin", Data("NOPE".utf8))
        ]))
        finalize(parser)

        XCTAssertTrue(parser.hadWriteError)
        XCTAssertEqual(parser.completedFiles.count, 1)
        XCTAssertEqual(parser.completedFiles.first.map { ($0 as NSString).lastPathComponent }, "good.bin")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("good.bin")), Data("GOOD".utf8))
    }
}
