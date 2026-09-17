import XCTest
@testable import PVWebServer

final class UploadFailureTests: XCTestCase {
    func testStatusMapping() {
        XCTAssertEqual(UploadFailure.diskFull.httpStatus, 507)
        XCTAssertEqual(UploadFailure.diskFull.statusText, "Insufficient Storage")
        XCTAssertEqual(UploadFailure.writeError.httpStatus, 500)
        XCTAssertEqual(UploadFailure.truncated.httpStatus, 500)
        XCTAssertEqual(UploadFailure.truncated.statusText, "Internal Server Error")
    }

    func testClassifyHealthyWriterIsNil() throws {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("icube-uf-\(ProcessInfo.processInfo.globallyUniqueString)")
        defer { try? FileManager.default.removeItem(at: target) }
        let writer = try XCTUnwrap(SerialFileWriter(at: target))
        XCTAssertNil(UploadFailure.classify(writer: writer, truncated: false))
        XCTAssertEqual(UploadFailure.classify(writer: writer, truncated: true), .truncated)
    }

    func testClassifyFailedWriterOutranksTruncation() throws {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("icube-uf-\(ProcessInfo.processInfo.globallyUniqueString)")
        defer { try? FileManager.default.removeItem(at: target) }
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: target.path))
        try handle.close()
        let writer = SerialFileWriter(handle: handle)
        writer.write(Data("x".utf8))
        let done = expectation(description: "finalize")
        writer.finalize { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(UploadFailure.classify(writer: writer, truncated: true), .writeError)
    }
}
