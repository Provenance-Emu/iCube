//
//  EngineTests.swift
//  PVPatchEngineTests
//
//  Format detection, atomic output, cancellation and progress.
//

import XCTest
@testable import PVPatchEngine

final class EngineTests: PatchTestCase {
    func testChecksumOfTheCheckString() {
        XCTAssertEqual(crc32(Array("123456789".utf8)), 0xCBF4_3926)
    }

    func testDetectsEveryFormatByMagic() throws {
        let cases: [(PatchFormat, String, [UInt8])] = [
            (.ips, "a.bin", IPSBuilder.patch()),
            (.ips32, "a.bin", IPSBuilder.patch(ips32: true)),
            (.ips32, "a.ips32", Array("PATCH".utf8) + Array("EEOF".utf8)),
            (.bps, "a.bin", BPSBuilder(source: []).patch()),
            (.ups, "a.bin", UPSBuilder.patch(source: [1], target: [2])),
            (.ppf, "a.bin", PPFBuilder.v1(records: [])),
            (.xdelta3, "a.bin", [0xD6, 0xC3, 0xC4, 0x00, 0x00])
        ]
        for (format, name, bytes) in cases {
            let url = try write(bytes, named: name)
            XCTAssertEqual(PatchEngine.detectFormat(url), format, name)
        }
    }

    func testDoesNotDetectOtherFiles() throws {
        XCTAssertNil(PatchEngine.detectFormat(try write(Array("hello world".utf8), named: "x.ips")))
        XCTAssertNil(PatchEngine.detectFormat(try write([], named: "empty")))
        XCTAssertNil(PatchEngine.detectFormat(directory.appendingPathComponent("missing")))
        XCTAssertNil(PatchEngine.detectFormat(try write(Array("PPF40".utf8) + [0, 0, 0], named: "ppf4")))
    }

    func testInspectOfAnUnknownFileIsUnsupported() throws {
        let url = try write([1, 2, 3, 4, 5, 6, 7, 8], named: "junk")
        XCTAssertThrowsError(try PatchEngine.inspect(patch: url)) { error in
            guard case .unsupportedFormat? = error as? PatchError else { return XCTFail("got \(error)") }
        }
    }

    func testOutputReplacesAnExistingFileAndLeavesNoPartial() async throws {
        let outputURL = try write([0xEE], named: "output.bin")
        let patchURL = try write(IPSBuilder.patch(records: [(0, [9])]), named: "p.ips")
        let sourceURL = try write([1, 2, 3], named: "source.bin")
        let result = try await PatchEngine.apply(patch: patchURL, source: sourceURL, output: outputURL)
        XCTAssertEqual(result.output, outputURL)
        XCTAssertEqual(try read(outputURL), [9, 2, 3])
        XCTAssertEqual(try read(sourceURL), [1, 2, 3])
        XCTAssertTrue(partialFiles.isEmpty)
    }

    func testFailureLeavesAnExistingOutputUntouched() async throws {
        let outputURL = try write([0xEE], named: "output.bin")
        let patchURL = try write(Array("BPS1".utf8) + [0x80, 0x80], named: "p.bps")
        let sourceURL = try write([1, 2, 3], named: "source.bin")
        let error = await expectPatchError { _ = try await PatchEngine.apply(patch: patchURL, source: sourceURL, output: outputURL) }
        XCTAssertNotNil(error)
        XCTAssertEqual(try read(outputURL), [0xEE])
        XCTAssertTrue(partialFiles.isEmpty)
    }

    func testOutputCannotBeTheSource() async throws {
        let patchURL = try write(IPSBuilder.patch(records: [(0, [9])]), named: "p.ips")
        let sourceURL = try write([1, 2, 3], named: "source.bin")
        let error = await expectPatchError { _ = try await PatchEngine.apply(patch: patchURL, source: sourceURL, output: sourceURL) }
        guard case .io? = error else { return XCTFail("got \(String(describing: error))") }
        XCTAssertEqual(try read(sourceURL), [1, 2, 3])
    }

    func testMissingSourceIsAnIOError() async throws {
        let patchURL = try write(IPSBuilder.patch(), named: "p.ips")
        let error = await expectPatchError {
            _ = try await PatchEngine.apply(patch: patchURL, source: directory.appendingPathComponent("nope"), output: directory.appendingPathComponent("out"))
        }
        guard case .io? = error else { return XCTFail("got \(String(describing: error))") }
        XCTAssertTrue(partialFiles.isEmpty)
    }

    // MARK: - Progress and cancellation

    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<PatchResult, Error>?

        func set(_ newTask: Task<PatchResult, Error>) {
            lock.lock()
            task = newTask
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            task?.cancel()
            lock.unlock()
        }
    }

    private func makeSparse(_ name: String, size: UInt64) throws -> URL {
        let url = directory.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: size)
        try handle.close()
        return url
    }

    private func zeroCRC(_ count: UInt64) -> UInt32 {
        let zeros = [UInt8](repeating: 0, count: 1 << 20)
        var crc: UInt32 = 0
        var left = count
        while left > 0 {
            let chunk = Int(min(left, UInt64(zeros.count)))
            crc = zeros.withUnsafeBytes { Checksums.crc32(crc, $0.baseAddress!, count: chunk) }
            left -= UInt64(chunk)
        }
        return crc
    }

    func testCancellingDuringAnIPSCopyRemovesThePartialFile() async throws {
        let sourceURL = try makeSparse("source.bin", size: 256 << 20)
        let patchURL = try write(IPSBuilder.patch(records: [(0, [1])]), named: "p.ips")
        let outputURL = directory.appendingPathComponent("output.bin")
        let box = TaskBox()
        let task = Task {
            try await PatchEngine.apply(patch: patchURL, source: sourceURL, output: outputURL) { _ in box.cancel() }
        }
        box.set(task)
        let error = await expectPatchError { _ = try await task.value }
        guard case .cancelled? = error else { return XCTFail("got \(String(describing: error))") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertTrue(partialFiles.isEmpty)
    }

    func testCancellingDuringBPSVerificationRemovesThePartialFile() async throws {
        let size: UInt64 = 256 << 20
        let sourceURL = try makeSparse("source.bin", size: size)
        var body = Array("BPS1".utf8) + variableLength(size) + variableLength(size) + variableLength(0)
        body += variableLength((size - 1) << 2)
        body += littleEndian(zeroCRC(size)) + littleEndian(zeroCRC(size))
        let patchURL = try write(appendingPatchCRC(body), named: "p.bps")
        let outputURL = directory.appendingPathComponent("output.bin")

        let uncancelled = try await PatchEngine.apply(patch: patchURL, source: sourceURL, output: outputURL)
        XCTAssertEqual(uncancelled.bytesWritten, size)
        try FileManager.default.removeItem(at: outputURL)

        let box = TaskBox()
        let task = Task {
            try await PatchEngine.apply(patch: patchURL, source: sourceURL, output: outputURL) { _ in box.cancel() }
        }
        box.set(task)
        let error = await expectPatchError { _ = try await task.value }
        guard case .cancelled? = error else { return XCTFail("got \(String(describing: error))") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertTrue(partialFiles.isEmpty)
    }

    func testProgressNeverGoesBackwardsAndEndsAtOne() async throws {
        let sourceURL = try makeSparse("source.bin", size: 32 << 20)
        let patchURL = try write(IPSBuilder.patch(records: [(0, [1])]), named: "p.ips")
        let collector = ProgressCollector()
        _ = try await PatchEngine.apply(patch: patchURL, source: sourceURL, output: directory.appendingPathComponent("o")) {
            collector.add($0)
        }
        let values = collector.values
        XCTAssertGreaterThan(values.count, 2)
        XCTAssertEqual(values, values.sorted(by: { $0.fractionCompleted < $1.fractionCompleted }))
        XCTAssertEqual(values.last?.fractionCompleted, 1)
    }
}

final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PatchProgress] = []

    func add(_ progress: PatchProgress) {
        lock.lock()
        storage.append(progress)
        lock.unlock()
    }

    var values: [PatchProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
