import XCTest
@testable import PVWebServer

final class SerialFileWriterTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("icube-writer-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testWritesBytesAndCountsThem() throws {
        let target = dir.appendingPathComponent("a.bin")
        let writer = try XCTUnwrap(SerialFileWriter(at: target))
        writer.write(Data("hello".utf8))
        writer.write(Data(" world".utf8))
        let done = expectation(description: "finalize")
        writer.finalize { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertFalse(writer.failed)
        XCTAssertEqual(writer.bytesWritten, 11)
        XCTAssertEqual(try Data(contentsOf: target), Data("hello world".utf8))
    }

    func testWriteToClosedHandleIsReportedAsFailure() throws {
        let target = dir.appendingPathComponent("b.bin")
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: target.path))
        try handle.close() // every later write throws EBADF
        let writer = SerialFileWriter(handle: handle)
        writer.write(Data("x".utf8))
        let done = expectation(description: "finalize")
        writer.finalize { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertTrue(writer.failed)
        XCTAssertFalse(writer.diskFull)
        XCTAssertEqual(writer.bytesWritten, 0)
    }

    func testEmptyWriteIsIgnored() throws {
        let target = dir.appendingPathComponent("c.bin")
        let writer = try XCTUnwrap(SerialFileWriter(at: target))
        writer.write(Data())
        let done = expectation(description: "finalize")
        writer.finalize { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertFalse(writer.failed)
        XCTAssertEqual(writer.bytesWritten, 0)
    }
}
