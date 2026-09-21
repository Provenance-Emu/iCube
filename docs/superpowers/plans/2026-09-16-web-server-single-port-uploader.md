# Web Server Re-port Implementation Plan

> **SUPERSEDED / DONE — 2026-09-21.** Every task in this plan landed on `develop`; the
> checkboxes below were simply never ticked. Verified by reading the merged code and by
> `git merge-base --is-ancestor` on the cited SHAs (all true against current `develop`):
> `33d42a8195`, `5c670ea3fb`, `c46ec4f263`, `17c008f41e`, `40fc5e427b`. iCube already has
> a single `NWListener` on one port, per-request WebDAV-vs-browser classification, the
> package-resource upload page, a benchmark script, and real `swift test` coverage. Do
> **not** re-run this plan. Remaining lifecycle work (who calls `start()`/`stop()`, and
> when) is tracked separately as WS-3 in
> `docs/superpowers/plans/2026-09-21-icube-post-jit-roadmap.md`. This file is kept for
> history; its checkboxes are left unticked on purpose rather than hand-waved, since no
> one has re-verified each one individually against this exact wording — the SHAs above
> are the actual evidence.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring iCube's `PVWebServer` package up to iFly's server: one port for WebDAV and the browser UI, no silent upload corruption, no symlink escape, iFly's upload page, real unit tests, and a benchmark.

**Architecture:** `ROMUploadServer.swift` stays the single NWListener engine, but its private helper types move into their own internal files so `swift test` can reach them. Pure decision logic (path safety, client-mode classification, upload-failure classification, template rendering) lives in small enums with no socket dependency. The upload page becomes package resources rendered through a `{{TOKEN}}` template engine.

**Tech Stack:** Swift 5 language mode, Network.framework (`NWListener`/`NWConnection`), Foundation `FileHandle`, XCTest via `swift test` on macOS, SwiftLint.

**Spec:** `docs/superpowers/specs/2026-09-16-web-server-single-port-uploader-design.md`

## Global Constraints

- Package: `Source/iOS/PVWebServer` (SPM, `swift-tools-version:6.0`, `swiftLanguageModes: [.v5]`). `swift build` and `swift test` work on macOS today (verified 2026-09-16, 0 tests).
- Never change the `@objc(PVWebServer)` facade signatures or the notification string constants `PVWebServerFileUploadStartedNotification` / `PVWebServerFileUploadCompletedNotification`.
- Never post the completed notification for a failed upload.
- Debug API (`Source/iOS/App/Common/Swift/Debug/`, port 8723) is out of scope. Do not touch it.
- Run every changed Swift file through `swiftlint lint --config <repo>/.swiftlint.yml <file>` before committing.
- Never `git add -A` in this repo. The app build rewrites tracked `build/xcframework` binaries and bartycrouch rewrites `Core.strings`. Add files by name.
- All commits end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Paths below are relative to the repo root `Cores/Dolphin/dolphin-ios` unless stated. `PKG` means `Source/iOS/PVWebServer`, `SRC` means `PKG/Sources/PVWebServer`, `TESTS` means `PKG/Tests/PVWebServerTests`. iFly source is at `/Users/jmattiello/Workspace/Provenance/iFly/iFly`; shell snippets use `$IFLY`, so run `export IFLY=/Users/jmattiello/Workspace/Provenance/iFly/iFly` first.

---

## File structure

| File | Responsibility |
|---|---|
| `SRC/SerialFileWriter.swift` (new, extracted) | Serial disk writer that records `failed` / `diskFull` / `bytesWritten` |
| `SRC/UploadFailure.swift` (new) | Pure classification of a finished upload into 507 / 500 / success |
| `SRC/WebServerPathSafety.swift` (new, from iFly) | Lexical + symlink sandbox guard |
| `SRC/WebServerClientMode.swift` (new) | Pure browser-vs-WebDAV classification of one request |
| `SRC/WebServerPageRenderer.swift` (new) | Loads `Bundle.module` templates, renders `{{TOKEN}}`s |
| `SRC/Resources/upload-page.html`, `.css`, `.js`, `nav-fragment.html` (new, from iFly) | Upload page |
| `SRC/ROMUploadServer.swift` (modify) | Engine: single listener, routes, streaming |
| `SRC/PVWebServer.swift` (modify) | Facade: single port |
| `PKG/Package.swift` (modify) | Declare resources |
| `TESTS/*.swift` (new) | One test file per unit above |
| `Source/iOS/App/Common/UI/Settings/SwiftUI/SettingsRootView.swift`, `Source/iOS/App/Common/Swift/LibraryWebImportView.swift` (modify) | One URL, Finder instructions |
| `Source/iOS/App/Scripts/webserver_transfer_bench.sh` (new, from iFly), `Source/iOS/App/Makefile` (modify) | Benchmark |

---

### Task 1: SerialFileWriter surfaces write failures

**Files:**
- Create: `SRC/SerialFileWriter.swift`
- Create: `SRC/UploadFailure.swift`
- Modify: `SRC/ROMUploadServer.swift:33-69` (delete the private class there)
- Test: `TESTS/SerialFileWriterTests.swift`, `TESTS/UploadFailureTests.swift`
- Delete: `TESTS/PVWebServerTests.swift` (Xcode boilerplate)

**Interfaces:**
- Produces: `final class SerialFileWriter` with `init?(at: URL)`, `init(handle: FileHandle)`, `func write(_ data: Data)`, `func finalize(completion: @escaping @Sendable () -> Void)`, `private(set) var failed: Bool`, `private(set) var diskFull: Bool`, `private(set) var bytesWritten: Int`. `finalize` runs `completion` after the close attempt, on a global queue, and by then `failed` reflects the close result too.
- Produces: `enum UploadFailure { case diskFull, writeError, truncated }` with `var httpStatus: Int` (507, 500, 500), `var statusText: String`, and `static func classify(writer: SerialFileWriter, truncated: Bool) -> UploadFailure?`.

- [ ] **Step 1: Remove the boilerplate test and write the failing writer test**

```bash
git rm -q Source/iOS/PVWebServer/Tests/PVWebServerTests/PVWebServerTests.swift
```

Create `TESTS/SerialFileWriterTests.swift`:

```swift
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
```

Create `TESTS/UploadFailureTests.swift`:

```swift
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
        XCTAssertEqual(UploadFailure.classify(writer: writer, truncated: true), .writeError)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Source/iOS/PVWebServer && swift test 2>&1 | tail -20`
Expected: compile errors, `cannot find 'SerialFileWriter' in scope` (it is `private` inside `ROMUploadServer.swift`) and `cannot find 'UploadFailure'`.

- [ ] **Step 3: Extract and extend the writer**

Delete lines 33 to 69 of `SRC/ROMUploadServer.swift` (the `// MARK: - SerialFileWriter` comment through the closing brace of `private final class SerialFileWriter`). Create `SRC/SerialFileWriter.swift`:

```swift
// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
//  SerialFileWriter.swift
//  PVWebServer
//
//  Offloads `FileHandle` writes to a per-file serial queue so `NWConnection.receive`
//  can schedule the next socket read without waiting on flash I/O. Records write and
//  close failures: a disk-full upload used to truncate the file while the client got
//  a 2xx, so callers MUST consult `failed` before reporting success.

import Foundation

final class SerialFileWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let queue: DispatchQueue

    /// A write or close threw. Read only after `finalize`'s completion has run.
    private(set) var failed = false
    /// The failure was ENOSPC, so the caller can answer 507.
    private(set) var diskFull = false
    private(set) var bytesWritten = 0

    init?(at url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else { return nil }
        self.handle = handle
        self.queue = Self.makeQueue()
    }

    init(handle: FileHandle) {
        self.handle = handle
        self.queue = Self.makeQueue()
    }

    private static func makeQueue() -> DispatchQueue {
        DispatchQueue(label: "org.dolphin.iCube.uploadserver.disk.\(UUID().uuidString)", qos: .utility)
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async {
            guard !self.failed else { return }
            do {
                try self.handle.write(contentsOf: data)
                self.bytesWritten += data.count
            } catch {
                self.recordFailure(error, context: "write after \(self.bytesWritten) bytes")
            }
        }
    }

    func finalize(completion: @escaping @Sendable () -> Void) {
        queue.async {
            do {
                try self.handle.close()
            } catch {
                if !self.failed { self.recordFailure(error, context: "close") }
            }
            DispatchQueue.global(qos: .userInitiated).async(execute: completion)
        }
    }

    private func recordFailure(_ error: Error, context: String) {
        failed = true
        let ns = error as NSError
        let underlying = (ns.userInfo[NSUnderlyingErrorKey] as? NSError)?.code
        if ns.code == Int(ENOSPC) || underlying == Int(ENOSPC) { diskFull = true }
        NSLog("[ROMUploadServer] upload \(context) failed\(diskFull ? " (disk full)" : ""): \(error)")
    }
}
```

Create `SRC/UploadFailure.swift`:

```swift
// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
//  UploadFailure.swift
//  PVWebServer
//
//  Why a finished upload must not be reported as success. Pure so it is testable
//  without a socket.

import Foundation

enum UploadFailure: Equatable {
    case diskFull
    case writeError
    /// The socket closed before `Content-Length` bytes arrived.
    case truncated

    var httpStatus: Int {
        switch self {
        case .diskFull: return 507
        case .writeError, .truncated: return 500
        }
    }

    var statusText: String {
        switch self {
        case .diskFull: return "Insufficient Storage"
        case .writeError, .truncated: return "Internal Server Error"
        }
    }

    var logReason: String {
        switch self {
        case .diskFull: return "disk full"
        case .writeError: return "write error"
        case .truncated: return "connection closed before Content-Length"
        }
    }

    /// Call only after `writer.finalize`'s completion has run.
    static func classify(writer: SerialFileWriter, truncated: Bool) -> UploadFailure? {
        if writer.failed { return writer.diskFull ? .diskFull : .writeError }
        if truncated { return .truncated }
        return nil
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Source/iOS/PVWebServer && swift test 2>&1 | tail -6`
Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 5: Lint and commit**

```bash
swiftlint lint --config .swiftlint.yml Source/iOS/PVWebServer/Sources/PVWebServer/SerialFileWriter.swift Source/iOS/PVWebServer/Sources/PVWebServer/UploadFailure.swift
git add Source/iOS/PVWebServer/Sources/PVWebServer/SerialFileWriter.swift Source/iOS/PVWebServer/Sources/PVWebServer/UploadFailure.swift Source/iOS/PVWebServer/Sources/PVWebServer/ROMUploadServer.swift Source/iOS/PVWebServer/Tests/PVWebServerTests
git commit -m "fix(webserver): SerialFileWriter records write and close failures

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Symlink-safe path guard

**Files:**
- Create: `SRC/WebServerPathSafety.swift`
- Modify: `SRC/ROMUploadServer.swift` (`resolvedPath(_:within:)`, currently around line 2045 after Task 1)
- Test: `TESTS/WebServerPathSafetyTests.swift`

**Interfaces:**
- Produces: `enum WebServerPathSafety { enum Resolution: Equatable { case ok(URL), lexicalEscape, symlinkEscape }; static func resolve(_ rawPath: String, within baseDir: URL) -> Resolution }`.
- `ROMUploadServer.resolvedPath(_:within:) -> URL?` keeps its signature but delegates and logs rejections.

- [ ] **Step 1: Write the failing tests**

Create `TESTS/WebServerPathSafetyTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Source/iOS/PVWebServer && swift test --filter WebServerPathSafetyTests 2>&1 | tail -5`
Expected: `cannot find 'WebServerPathSafety' in scope`.

- [ ] **Step 3: Copy iFly's guard and wire it in**

```bash
cp "$IFLY/Sources/Core/WebServer/WebServerPathSafety.swift" Source/iOS/PVWebServer/Sources/PVWebServer/WebServerPathSafety.swift
```

Then edit the header comment in the copied file: replace `//  iFly EMU` with `//  PVWebServer` and `iFlyTests` with `PVWebServerTests`. The body is unchanged (it is the exact code shown in the spec, section 4.2).

In `SRC/ROMUploadServer.swift`, replace the whole `resolvedPath` function:

```swift
    private func resolvedPath(_ rawPath: String, within baseDir: URL) -> URL? {
        switch WebServerPathSafety.resolve(rawPath, within: baseDir) {
        case .ok(let url):
            return url
        case .lexicalEscape:
            NSLog("[ROMUploadServer] rejected path (lexical escape): \(rawPath)")
            return nil
        case .symlinkEscape:
            NSLog("[ROMUploadServer] rejected path (symlink escape): \(rawPath)")
            return nil
        }
    }
```

- [ ] **Step 4: Run all tests**

Run: `cd Source/iOS/PVWebServer && swift test 2>&1 | tail -4`
Expected: `Executed 12 tests, with 0 failures`.

- [ ] **Step 5: Lint and commit**

```bash
swiftlint lint --config .swiftlint.yml Source/iOS/PVWebServer/Sources/PVWebServer/WebServerPathSafety.swift
git add Source/iOS/PVWebServer/Sources/PVWebServer/WebServerPathSafety.swift Source/iOS/PVWebServer/Sources/PVWebServer/ROMUploadServer.swift Source/iOS/PVWebServer/Tests/PVWebServerTests/WebServerPathSafetyTests.swift
git commit -m "fix(webserver): symlink-safe sandbox guard, log every rejection

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Open the parser types to tests

**Files:**
- Modify: `SRC/ROMUploadServer.swift` (`private struct HTTPRequest` → `struct HTTPRequest`; nested `private final class ChunkedBodyReader` → `final class ChunkedBodyReader`; `private final class StreamingMultipartParser` → `final class StreamingMultipartParser`, add `hadWriteError`)
- Test: `TESTS/HTTPRequestParseTests.swift`, `TESTS/ChunkedBodyReaderTests.swift`, `TESTS/StreamingMultipartParserTests.swift`

**Interfaces:**
- Consumes: `SerialFileWriter.failed` (Task 1).
- Produces: `StreamingMultipartParser.hadWriteError: Bool` (true if any part's writer failed; set inside `closeCurrentFile` before `completedFiles.append`, and a failed part is NOT appended to `completedFiles` and does NOT invoke `onFileCompleted`).

- [ ] **Step 1: Write the failing tests**

Create `TESTS/HTTPRequestParseTests.swift`:

```swift
import XCTest
@testable import PVWebServer

final class HTTPRequestParseTests: XCTestCase {
    func testParsesRequestLine() {
        let req = HTTPRequest.parse("GET /files/Super%20Mario.rvz?foo=bar HTTP/1.1\r\nHost: x")
        XCTAssertEqual(req?.method, "GET")
        XCTAssertEqual(req?.path, "/files/Super%20Mario.rvz")
        XCTAssertEqual(req?.queryString, "foo=bar")
        XCTAssertEqual(req?.httpVersion, "HTTP/1.1")
    }

    func testMethodUppercasedAndHeadersLowercased() {
        let req = HTTPRequest.parse("propfind / HTTP/1.1\r\nDepth: 1\r\nContent-Length: 42")
        XCTAssertEqual(req?.method, "PROPFIND")
        XCTAssertEqual(req?.headers["depth"], "1")
        XCTAssertEqual(req?.contentLength, 42)
    }

    func testMissingVersionDefaultsTo11() {
        let req = HTTPRequest.parse("OPTIONS *")
        XCTAssertEqual(req?.method, "OPTIONS")
        XCTAssertEqual(req?.httpVersion, "HTTP/1.1")
    }

    func testMalformedRequestLineReturnsNil() {
        XCTAssertNil(HTTPRequest.parse("GET"))
        XCTAssertNil(HTTPRequest.parse(""))
    }

    func testChunkedAndExpectContinue() {
        let req = HTTPRequest.parse("PUT /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\nExpect: 100-continue")
        XCTAssertTrue(req?.isChunked == true)
        XCTAssertTrue(req?.expectsContinue == true)
    }

    func testWantsKeepAlive() {
        XCTAssertTrue(HTTPRequest.parse("GET / HTTP/1.1\r\nHost: x")?.wantsKeepAlive == true)
        XCTAssertFalse(HTTPRequest.parse("GET / HTTP/1.1\r\nConnection: close")?.wantsKeepAlive == true)
        XCTAssertFalse(HTTPRequest.parse("GET / HTTP/1.0\r\nHost: x")?.wantsKeepAlive == true)
        XCTAssertTrue(HTTPRequest.parse("GET / HTTP/1.0\r\nConnection: keep-alive")?.wantsKeepAlive == true)
    }

    func testMultipartBoundary() {
        let req = HTTPRequest.parse("POST /upload HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=\"AaB03x\"")
        XCTAssertEqual(req?.multipartBoundary, "AaB03x")
        XCTAssertNil(HTTPRequest.parse("POST /x HTTP/1.1\r\nContent-Type: application/json")?.multipartBoundary)
    }

    func testQueryParametersPercentDecoded() {
        let req = HTTPRequest.parse("GET /?path=Wii%2FGames&flag HTTP/1.1")
        XCTAssertEqual(req?.queryParameters["path"], "Wii/Games")
        XCTAssertEqual(req?.queryParameters["flag"], "")
    }
}
```

Create `TESTS/ChunkedBodyReaderTests.swift`:

```swift
import XCTest
@testable import PVWebServer

final class ChunkedBodyReaderTests: XCTestCase {
    private typealias Event = ROMUploadServer.ChunkedBodyReader.Event

    private func payloads(_ events: [Event]) -> Data {
        var out = Data()
        for e in events { if case .payload(let d) = e { out.append(d) } }
        return out
    }

    private func isComplete(_ events: [Event]) -> Bool {
        events.contains { if case .complete = $0 { return true } else { return false } }
    }

    func testSingleChunk() {
        let reader = ROMUploadServer.ChunkedBodyReader()
        let events = reader.feed(Data("5\r\nhello\r\n0\r\n\r\n".utf8))
        XCTAssertEqual(payloads(events), Data("hello".utf8))
        XCTAssertTrue(isComplete(events))
    }

    func testMultipleChunks() {
        let reader = ROMUploadServer.ChunkedBodyReader()
        let events = reader.feed(Data("3\r\nabc\r\n3\r\ndef\r\n0\r\n\r\n".utf8))
        XCTAssertEqual(payloads(events), Data("abcdef".utf8))
        XCTAssertTrue(isComplete(events))
    }

    func testChunkSplitAcrossFeeds() {
        let reader = ROMUploadServer.ChunkedBodyReader()
        var got = Data()
        got.append(payloads(reader.feed(Data("5\r\nhe".utf8))))
        got.append(payloads(reader.feed(Data("llo\r\n0\r\n\r\n".utf8))))
        XCTAssertEqual(got, Data("hello".utf8))
    }

    func testHexSizeAndTrailing() {
        let body = String(repeating: "z", count: 26)
        let reader = ROMUploadServer.ChunkedBodyReader()
        let events = reader.feed(Data("1a\r\n\(body)\r\n0\r\n\r\nNEXT".utf8))
        XCTAssertEqual(payloads(events), Data(body.utf8))
        var trailing = Data()
        for e in events { if case .complete(let t) = e { trailing = t } }
        XCTAssertEqual(trailing, Data("NEXT".utf8))
    }

    func testInvalidSizeEmitsInvalid() {
        let reader = ROMUploadServer.ChunkedBodyReader()
        let events = reader.feed(Data("XYZ\r\n".utf8))
        XCTAssertTrue(events.contains { if case .invalid = $0 { return true } else { return false } })
    }
}
```

Create `TESTS/StreamingMultipartParserTests.swift`. Note iCube's parser strips a part's filename to its last path component (subfolders are the job of `PUT /files/`), so the iFly "subfolder preserved" case becomes "subfolder stripped":

```swift
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
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Source/iOS/PVWebServer && swift test 2>&1 | grep -E 'error:' | head`
Expected: `'HTTPRequest' is inaccessible due to 'private' protection level`, same for `ChunkedBodyReader`, `StreamingMultipartParser`, and `hadWriteError`.

- [ ] **Step 3: Open the types and add write-error tracking**

In `SRC/ROMUploadServer.swift`:

1. `private struct HTTPRequest {` → `struct HTTPRequest {`
2. Inside `ROMUploadServer`: `private final class ChunkedBodyReader: @unchecked Sendable {` → `final class ChunkedBodyReader: @unchecked Sendable {`
3. `private final class StreamingMultipartParser {` → `final class StreamingMultipartParser {`
4. Add a property next to `completedFiles`:

```swift
    private(set) var completedFiles: [String] = []
    /// True once any part failed to open or write. The caller must answer 5xx.
    private(set) var hadWriteError = false
```

5. In `process()`, `.readingHeaders` case, after `currentWriter = SerialFileWriter(at: filePath)` add:

```swift
                    if currentWriter == nil {
                        NSLog("[ROMUploadServer] multipart: cannot open \(filePath.path) for writing")
                        hadWriteError = true
                        currentFilename = nil
                        currentFilePath = nil
                    }
```

6. Replace `closeCurrentFile()` so a failed writer is not reported as complete:

```swift
    private func closeCurrentFile() {
        guard let writer = currentWriter else { return }
        let path = currentFilePath?.path
        let filename = currentFilename
        currentWriter = nil
        currentFilename = nil
        currentFilePath = nil
        pendingCloses += 1
        writer.finalize { [weak self] in
            guard let self else { return }
            if writer.failed {
                self.hadWriteError = true
                if let path { try? FileManager.default.removeItem(atPath: path) }
            } else if let path, filename != nil {
                self.completedFiles.append(path)
                self.onFileCompleted?(path)
            }
            self.pendingCloses -= 1
            if self.pendingCloses == 0, let completion = self.finalizeCompletion {
                self.finalizeCompletion = nil
                completion()
            }
        }
    }
```

7. In `finishMultipartUpload`, answer failure first:

```swift
    private func finishMultipartUpload(on connection: NWConnection, request: HTTPRequest,
                                       parser: StreamingMultipartParser) {
        if parser.hadWriteError {
            sendJSON(on: connection, status: 500, json: ["ok": false, "error": "Upload failed"],
                     request: request, isWebDAV: false, forceClose: true)
            return
        }
        let files = parser.completedFiles
        if files.isEmpty {
            sendJSON(on: connection, status: 400, json: ["ok": false, "error": "No files uploaded"],
                     request: request, isWebDAV: false, forceClose: true)
            return
        }
        sendJSON(on: connection, status: 200, json: ["ok": true, "uploaded": files.count],
                 request: request, isWebDAV: false)
    }
```

- [ ] **Step 4: Run all tests**

Run: `cd Source/iOS/PVWebServer && swift test 2>&1 | tail -4`
Expected: `Executed 30 tests, with 0 failures`.

- [ ] **Step 5: Lint and commit**

```bash
swiftlint lint --config .swiftlint.yml Source/iOS/PVWebServer/Sources/PVWebServer/ROMUploadServer.swift
git add Source/iOS/PVWebServer/Sources/PVWebServer/ROMUploadServer.swift Source/iOS/PVWebServer/Tests/PVWebServerTests
git commit -m "test(webserver): parser, chunked decoder and multipart coverage; multipart write errors answer 500

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Streaming PUT never reports a partial file as success

**Files:**
- Modify: `SRC/ROMUploadServer.swift` (`streamWebDAVPut`, `streamPutChunks`, `streamChunkedWebDAVPut`)

**Interfaces:**
- Consumes: `UploadFailure.classify(writer:truncated:)` (Task 1).
- Produces: `private typealias PutFinish = (_ failure: UploadFailure?) -> Void` and `private func completeStreamingPut(writer: SerialFileWriter, target: URL, truncated: Bool, finish: @escaping PutFinish)`. Task 6 reuses both for the browser PUT.

- [ ] **Step 1: Add the shared completion helper**

Insert directly above `// MARK: - Streaming WebDAV PUT`:

```swift
    private typealias PutFinish = (_ failure: UploadFailure?) -> Void

    /// Finish a streaming PUT. On writer failure or truncation, delete the partial file, log,
    /// and hand the failure to `finish` WITHOUT posting the completion notification.
    private func completeStreamingPut(writer: SerialFileWriter, target: URL,
                                      truncated: Bool, finish: @escaping PutFinish) {
        writer.finalize { [weak self] in
            guard let self else { return }
            if let failure = UploadFailure.classify(writer: writer, truncated: truncated) {
                NSLog("[ROMUploadServer] upload FAILED for \(target.lastPathComponent): \(failure.logReason) after \(writer.bytesWritten) bytes — deleting partial file")
                try? FileManager.default.removeItem(at: target)
                finish(failure)
                return
            }
            self.postUploadCompleted(filePath: target.path)
            finish(nil)
        }
    }

    private func webDAVPutFinish(on connection: NWConnection, request: HTTPRequest) -> PutFinish {
        return { [weak self] failure in
            guard let self else { return }
            if let failure {
                self.sendWebDAVResponse(on: connection, status: failure.httpStatus,
                                        statusText: failure.statusText, body: "Upload failed",
                                        request: request, forceClose: true)
            } else {
                self.sendWebDAVResponse(on: connection, status: 201, statusText: "Created", request: request)
            }
        }
    }
```

- [ ] **Step 2: Rewrite the Content-Length PUT path**

Replace `streamWebDAVPut` and `streamPutChunks` with:

```swift
    private func streamWebDAVPut(on connection: NWConnection, request: HTTPRequest,
                                 initialBody: Data, remaining: Int) {
        let rawPath = String(request.path.dropFirst())
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        guard let target = resolvedPath(decoded, within: romsDirectory) else {
            sendResponse(on: connection, status: 403, statusText: "Forbidden", body: "Path traversal denied",
                         request: request, isWebDAV: true, forceClose: true)
            return
        }
        guard let writer = openPutTarget(target) else {
            sendWebDAVResponse(on: connection, status: 500, statusText: "Internal Server Error",
                               body: "Cannot create file", request: request, forceClose: true)
            return
        }
        postUploadStarted(path: target.path)
        writer.write(initialBody)
        streamPutChunks(on: connection, writer: writer, target: target, remaining: remaining,
                        finish: webDAVPutFinish(on: connection, request: request))
    }

    /// Creates the parent directory, replaces any existing file (createFile does not truncate,
    /// and preallocating over an existing file is slow on APFS), and opens the writer.
    private func openPutTarget(_ target: URL) -> SerialFileWriter? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            NSLog("[ROMUploadServer] PUT: cannot create parent for \(target.lastPathComponent): \(error)")
            return nil
        }
        if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
        guard let writer = SerialFileWriter(at: target) else {
            NSLog("[ROMUploadServer] PUT: cannot open \(target.path) for writing")
            return nil
        }
        return writer
    }

    private func streamPutChunks(on connection: NWConnection, writer: SerialFileWriter,
                                 target: URL, remaining: Int, finish: @escaping PutFinish) {
        if remaining <= 0 {
            completeStreamingPut(writer: writer, target: target, truncated: false, finish: finish)
            return
        }
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: min(remaining, Self.readChunkSize)) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { writer.write(data) }
            let newRemaining = remaining - (data?.count ?? 0)
            if newRemaining <= 0 || isComplete || error != nil {
                self.completeStreamingPut(writer: writer, target: target,
                                          truncated: newRemaining > 0, finish: finish)
            } else {
                self.streamPutChunks(on: connection, writer: writer, target: target,
                                     remaining: newRemaining, finish: finish)
            }
        }
    }
```

- [ ] **Step 3: Rewrite the chunked PUT path**

In `streamChunkedWebDAVPut`, replace the block from `let parent = target.deletingLastPathComponent()` through `let writer = SerialFileWriter(handle: handle)` with:

```swift
        guard let writer = openPutTarget(target) else {
            sendWebDAVResponse(on: connection, status: 500, statusText: "Internal Server Error",
                               body: "Cannot create file", request: request, forceClose: true)
            return
        }
        postUploadStarted(path: target.path)
```

Replace the `finishSuccess` closure with:

```swift
        let finishSuccess: (Data) -> Void = { [weak self] trailing in
            guard let self else { return }
            if !trailing.isEmpty {
                let connID = ObjectIdentifier(connection)
                self.lock.lock()
                if var ctx = self.connectionContexts[connID] {
                    ctx.pendingPipelined = trailing
                    self.connectionContexts[connID] = ctx
                }
                self.lock.unlock()
            }
            self.completeStreamingPut(writer: writer, target: target, truncated: false,
                                      finish: self.webDAVPutFinish(on: connection, request: request))
        }
```

In the same function's `readMore()`, the `error != nil` and `isComplete` branches currently answer 400 and leave the partial file. Replace both with a truncation completion:

```swift
                if error != nil || isComplete {
                    self.completeStreamingPut(writer: writer, target: target, truncated: true,
                                              finish: self.webDAVPutFinish(on: connection, request: request))
                    return
                }
```

(Keep the `let events = reader.feed(...)`/`if handleEvents(events) { return }` lines between the error check and the `isComplete` check as they are, so the order is: error → feed → handled → isComplete → readMore.)

- [ ] **Step 4: Build and run tests**

Run: `cd Source/iOS/PVWebServer && swift build 2>&1 | grep -E 'error|warning: var' ; swift test 2>&1 | tail -3`
Expected: no errors, 30 tests pass.

- [ ] **Step 5: Manual check on device (optional now, mandatory in Task 9)**

`curl -T big.iso http://<device>:81/big.iso` then Ctrl-C mid-transfer: the file must be gone from Documents/Software and no snackbar appears.

- [ ] **Step 6: Lint and commit**

```bash
swiftlint lint --config .swiftlint.yml Source/iOS/PVWebServer/Sources/PVWebServer/ROMUploadServer.swift
git add Source/iOS/PVWebServer/Sources/PVWebServer/ROMUploadServer.swift
git commit -m "fix(webserver): streaming PUT deletes partial files and answers 507/500

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Upload page as package resources

**Files:**
- Create: `SRC/Resources/upload-page.html`, `SRC/Resources/upload-page.css`, `SRC/Resources/upload-page.js`, `SRC/Resources/nav-fragment.html`
- Create: `SRC/WebServerPageRenderer.swift`
- Modify: `PKG/Package.swift` (resources)
- Modify: `SRC/ROMUploadServer.swift` (`serveHTML`, `fileRowHTML`, delete the `uploadPageHTML` extension at the end of the file, add `htmlAttrEscaped`)
- Test: `TESTS/WebServerPageRendererTests.swift`

**Interfaces:**
- Produces: `enum WebServerPageRenderer { static func uploadPage(appName: String, ipAddress: String, portSuffix: String, fileRows: String, currentPath: String) -> String; static func render(_ template: String, variables: [String: String]) -> String; static func loadResource(name: String, ext: String) -> String? }`.
- JS contract with Task 6: `PUT /files/<relative path>` (raw body, `Content-Type: application/octet-stream`), `POST /move` JSON `{src, dst}`, `POST /mkdir` JSON `{path}`, `GET /api/health`, `DELETE /files/<path>`. Row markup carries `data-dir`, `data-path`, `data-name`, `draggable="true"`, and the classes `dir-row`, `file-row`, `uprow`.

- [ ] **Step 1: Write the failing renderer test**

Create `TESTS/WebServerPageRendererTests.swift`:

```swift
import XCTest
@testable import PVWebServer

final class WebServerPageRendererTests: XCTestCase {
    func testRenderSubstitutesEveryToken() {
        let out = WebServerPageRenderer.render("a {{X}} b {{Y}} {{X}}", variables: ["X": "1", "Y": "2"])
        XCTAssertEqual(out, "a 1 b 2 1")
    }

    func testResourcesAreBundled() {
        for (name, ext) in [("upload-page", "html"), ("upload-page", "css"), ("upload-page", "js"), ("nav-fragment", "html")] {
            XCTAssertNotNil(WebServerPageRenderer.loadResource(name: name, ext: ext), "\(name).\(ext) missing from Bundle.module")
        }
    }

    func testUploadPageHasNoUnrenderedTokensAndUsesAppName() {
        let html = WebServerPageRenderer.uploadPage(appName: "iCube", ipAddress: "10.0.0.5", portSuffix: "",
                                                    fileRows: "<tr><td>row</td></tr>", currentPath: "Wii")
        XCTAssertFalse(html.contains("{{"), "unrendered token in page")
        XCTAssertTrue(html.contains("iCube"))
        XCTAssertTrue(html.contains("http://10.0.0.5/"))
        XCTAssertTrue(html.contains("<tr><td>row</td></tr>"))
        XCTAssertTrue(html.contains("Wii"))
        XCTAssertFalse(html.contains("iFly"))
    }

    func testMissingResourceRendersVisibleError() {
        let html = WebServerPageRenderer.errorPage(missing: "upload-page.html")
        XCTAssertTrue(html.contains("upload-page.html"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Source/iOS/PVWebServer && swift test --filter WebServerPageRendererTests 2>&1 | tail -3`
Expected: `cannot find 'WebServerPageRenderer' in scope`.

- [ ] **Step 3: Copy the templates and rebrand**

```bash
mkdir -p Source/iOS/PVWebServer/Sources/PVWebServer/Resources
R=Source/iOS/PVWebServer/Sources/PVWebServer/Resources
cp "$IFLY/Resources/WebServer/upload-page.html" "$IFLY/Resources/WebServer/upload-page.css" "$IFLY/Resources/WebServer/upload-page.js" "$IFLY/Resources/WebServer/nav-fragment.html" "$R/"
sed -i '' -e 's/iFly EMU - File Upload/{{APP_NAME}} - File Upload/' \
          -e 's/<h1>iFly EMU &mdash; File Upload<\/h1>/<h1>{{APP_NAME}} \&mdash; File Upload<\/h1>/' \
          -e 's/Transfer ROMs, BIOS files, and saves/Transfer GameCube and Wii games, saves, and texture packs/' \
          -e 's#https://ifly-emu.com/support#https://icube-emu.com/help/web-import#' \
          -e 's#ifly-emu.com/support#icube-emu.com/help/web-import#' \
          -e 's#<a href="https://discord.gg/QF5ZjVT4Sa"[^<]*</a>#<a href="https://discord.gg/provenance" target="_blank" rel="noopener" style="color:inherit;">Join the Discord</a>#' \
          "$R/upload-page.html"
# Comment at the top of upload-page.js mentions Naomi/flycast: rewrite it.
sed -i '' -e '1,10{s/meltybld\/gdl-0028c.chd/Textures\/GAME01\/tex.png/;s/flycast.*$/Dolphin loads texture packs and Riivolution mods from subfolders, so the/;s/resolves Naomi GD-ROM CHDs.*$/relative path is preserved on upload./}' "$R/upload-page.js"
grep -n -i 'ifly\|flycast\|naomi\|dreamcast' "$R"/* ; echo "(expect no output above)"
```

Remove the Live Stats and Settings links from `nav-fragment.html` (iCube has no `/stats` or `/settings` pages). Replace the `<nav>` block with:

```html
<nav class="site-nav" aria-label="Primary">
  <a href="/" class="site-nav-link{{ACTIVE_FILES}}">Files</a>
  <a href="/stats" class="site-nav-link debug-stats-nav" style="display:none">Live Stats</a>
</nav>
```

(The hidden Live Stats link stays so `syncDebugStatsNav()` in the JS has an element to toggle; `/api/health` in iCube reports `features.stats = false`, so it never shows. Task 6 adjusts the JS to check that flag.)

- [ ] **Step 4: Declare resources and write the renderer**

In `PKG/Package.swift`, change the target to:

```swift
        .target(
            name: "PVWebServer",
            dependencies: [
			],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
```

Create `SRC/WebServerPageRenderer.swift`:

```swift
// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
//  WebServerPageRenderer.swift
//  PVWebServer
//
//  Loads the bundled upload-page templates and renders `{{TOKEN}}` placeholders
//  at serve time. Templates are cached after the first load.

import Foundation

enum WebServerPageRenderer {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    static func uploadPage(appName: String, ipAddress: String, portSuffix: String,
                           fileRows: String, currentPath: String) -> String {
        guard let html = loadResource(name: "upload-page", ext: "html"),
              let css = loadResource(name: "upload-page", ext: "css"),
              let js = loadResource(name: "upload-page", ext: "js"),
              let nav = loadResource(name: "nav-fragment", ext: "html") else {
            return errorPage(missing: "upload-page.html/css/js or nav-fragment.html")
        }
        let uploadTarget = currentPath.isEmpty ? "/upload" : "/upload?path=\(currentPath.urlPathEscaped)"
        let locationLabel = currentPath.isEmpty ? "base folder" : currentPath.htmlEscaped
        let clientScript = render(js, variables: [
            "UPLOAD_TARGET": uploadTarget,
            "CURRENT_PATH": currentPath.jsEscaped
        ])
        return render(html, variables: [
            "APP_NAME": appName.htmlEscaped,
            "STYLESHEET": css,
            "CLIENT_SCRIPT": clientScript,
            "IP_ADDRESS": ipAddress.htmlEscaped,
            "PORT_SUFFIX": portSuffix.htmlEscaped,
            "LOCATION_LABEL": locationLabel,
            "FILE_ROWS": fileRows,
            "NAV": render(nav, variables: ["ACTIVE_FILES": " is-active"])
        ])
    }

    /// Shown instead of crashing when a template is missing from the bundle.
    static func errorPage(missing: String) -> String {
        "<!DOCTYPE html><html><body><h1>Upload page unavailable</h1><p>Missing resource: \(missing.htmlEscaped)</p></body></html>"
    }

    static func render(_ template: String, variables: [String: String]) -> String {
        var result = template
        for (key, value) in variables {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }

    static func loadResource(name: String, ext: String) -> String? {
        let key = "\(name).\(ext)"
        lock.lock()
        if let cached = cache[key] { lock.unlock(); return cached }
        lock.unlock()
        guard let url = Bundle.module.url(forResource: name, withExtension: ext),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            NSLog("[ROMUploadServer] missing web resource \(key)")
            return nil
        }
        lock.lock()
        cache[key] = text
        lock.unlock()
        return text
    }
}
```

The `htmlEscaped` / `urlPathEscaped` / `jsEscaped` helpers already exist as a `private extension String` at the bottom of `ROMUploadServer.swift`. Change that extension from `private extension String` to `extension String` (internal) and add one more member:

```swift
    var htmlAttrEscaped: String { htmlEscaped }
```

- [ ] **Step 5: Serve through the renderer and emit iFly's row markup**

In `SRC/ROMUploadServer.swift`:

1. Delete the whole `// MARK: - HTML Upload Page` extension at the end of the file (`extension ROMUploadServer { static func uploadPageHTML(...) ... }`).
2. In `serveHTML`, replace the `rows.append("""...""")` for the ".." row with:

```swift
                rows.append("""
                <tr class="dir-row uprow" data-dir="1" data-path="\(parent.htmlAttrEscaped)">
                  <td><a href="\(parentQuery)">&#x2B05;&#xFE0F; ..</a></td>
                  <td></td>
                  <td></td>
                </tr>
                """)
```

3. Change the empty message colspan from `4` to `3`.
4. Delete the `entriesPayload`/`initialEntriesJSON` block (the new page fetches `/api/list` itself) and replace the `let html = Self.uploadPageHTML(...)` call with:

```swift
            let html = WebServerPageRenderer.uploadPage(
                appName: self.pageTitle, ipAddress: ip, portSuffix: portSuffix,
                fileRows: rows.isEmpty ? emptyMessage : rows.joined(separator: "\n"),
                currentPath: currentSub
            )
```

5. Remove `let davPortStr = "\(webDAVPort)"` from `serveHTML` (unused now).
6. Replace `fileRowHTML(entry:currentSub:)` with:

```swift
    private func fileRowHTML(entry: FileEntry, currentSub: String) -> String {
        let childSub = currentSub.isEmpty ? entry.name : "\(currentSub)/\(entry.name)"
        let escapedName = entry.name.htmlEscaped
        let pathAttr = childSub.htmlAttrEscaped
        let nameAttr = entry.name.htmlAttrEscaped
        if entry.isDirectory {
            return """
            <tr class="dir-row" draggable="true" data-dir="1" data-path="\(pathAttr)" data-name="\(nameAttr)">
              <td><a href="/?path=\(childSub.urlPathEscaped)">&#x1F4C1; \(escapedName)</a></td>
              <td>&mdash;</td>
              <td class="actions">
                <button onclick="renameItem(this)" class="btn btn-sm">Rename</button>
                <button onclick="moveItem(this)" class="btn btn-sm">Move</button>
                <button onclick="deleteItem(this)" class="btn btn-sm btn-danger">Delete</button>
              </td>
            </tr>
            """
        }
        let sizeStr = ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
        return """
        <tr class="file-row" draggable="true" data-dir="0" data-path="\(pathAttr)" data-name="\(nameAttr)">
          <td><a href="/files/\(childSub.urlPathEscaped)" download>\(escapedName)</a></td>
          <td>\(sizeStr)</td>
          <td class="actions">
            <a href="/files/\(childSub.urlPathEscaped)" download class="btn btn-sm">Download</a>
            <button onclick="renameItem(this)" class="btn btn-sm">Rename</button>
            <button onclick="moveItem(this)" class="btn btn-sm">Move</button>
            <button onclick="deleteItem(this)" class="btn btn-sm btn-danger">Delete</button>
          </td>
        </tr>
        """
    }
```

7. `formatFileDate` becomes unused. Delete it.

- [ ] **Step 6: Run all tests**

Run: `cd Source/iOS/PVWebServer && swift test 2>&1 | tail -4`
Expected: `Executed 34 tests, with 0 failures`.

- [ ] **Step 7: Build the app so Tuist picks up the package resources**

Run: `cd Source/iOS/App && tuist generate --no-open && xcodebuild -workspace iCube.xcworkspace -scheme "iCube (NJB)" -configuration "Debug (Non-Jailbroken)" -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E ' error: |BUILD (SUCCEEDED|FAILED)' | sort -u`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Lint and commit**

```bash
swiftlint lint --config .swiftlint.yml Source/iOS/PVWebServer/Sources/PVWebServer/WebServerPageRenderer.swift Source/iOS/PVWebServer/Sources/PVWebServer/ROMUploadServer.swift
git add Source/iOS/PVWebServer/Package.swift Source/iOS/PVWebServer/Sources/PVWebServer/Resources Source/iOS/PVWebServer/Sources/PVWebServer/WebServerPageRenderer.swift Source/iOS/PVWebServer/Sources/PVWebServer/ROMUploadServer.swift Source/iOS/PVWebServer/Tests/PVWebServerTests/WebServerPageRendererTests.swift
git commit -m "feat(webserver): upload page moves to package resources with iFly's transfer UI

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Browser routes: PUT /files/, /move, /mkdir, /api/health

**Files:**
- Modify: `SRC/ROMUploadServer.swift` (`handleRequestWithBody`, `routeHTTP`, new handlers)
- Modify: `SRC/Resources/upload-page.js` (health flag check)

**Interfaces:**
- Consumes: `openPutTarget`, `streamPutChunks`, `completeStreamingPut`, `PutFinish` (Task 4); `resolvedPath` (Task 2).
- Produces: routes listed in the spec table, section 4.3. `GET /api/health` body: `{"ok":true,"app":<pageTitle>,"version":<CFBundleShortVersionString or "">,"features":{"move":true,"mkdir":true,"stats":false}}`.

- [ ] **Step 1: Stream a browser PUT before buffering**

In `handleRequestWithBody`, insert before the `if isWebDAV && request.method == "PUT"` block:

```swift
        if !isWebDAV && request.method == "PUT" && request.path.hasPrefix("/files/") {
            let beginPut: () -> Void = { [weak self] in
                self?.streamBrowserFilePut(on: connection, request: request,
                                           initialBody: initialBody, remaining: remaining)
            }
            if request.expectsContinue {
                sendContinue(on: connection, isWebDAV: false, request: request, then: beginPut)
            } else {
                beginPut()
            }
            return
        }
```

- [ ] **Step 2: Add the handlers**

Insert after `uploadDirectory(for:)`:

```swift
    // MARK: - Browser PUT /files/<path>

    private func streamBrowserFilePut(on connection: NWConnection, request: HTTPRequest,
                                      initialBody: Data, remaining: Int) {
        let rel = String(request.path.dropFirst("/files/".count))
        let decoded = (rel.removingPercentEncoding ?? rel)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !decoded.isEmpty, let target = resolvedPath(decoded, within: romsDirectory) else {
            sendJSON(on: connection, status: 403, json: ["ok": false, "error": "Path traversal denied"],
                     request: request, isWebDAV: false, forceClose: true)
            return
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue {
            sendJSON(on: connection, status: 405, json: ["ok": false, "error": "Target is a folder"],
                     request: request, isWebDAV: false, forceClose: true)
            return
        }
        guard let writer = openPutTarget(target) else {
            sendJSON(on: connection, status: 500, json: ["ok": false, "error": "Cannot create file"],
                     request: request, isWebDAV: false, forceClose: true)
            return
        }
        postUploadStarted(path: target.path)
        writer.write(initialBody)
        let finish: PutFinish = { [weak self] failure in
            guard let self else { return }
            if let failure {
                self.sendJSON(on: connection, status: failure.httpStatus,
                              json: ["ok": false, "error": failure.logReason],
                              request: request, isWebDAV: false, forceClose: true)
            } else {
                self.sendResponse(on: connection, status: 204, statusText: "No Content", body: "",
                                  request: request, isWebDAV: false)
            }
        }
        streamPutChunks(on: connection, writer: writer, target: target, remaining: remaining, finish: finish)
    }

    // MARK: - Browser move / mkdir / health

    private func handleHTTPMove(on connection: NWConnection, request: HTTPRequest, body: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let src = obj["src"] as? String, let dst = obj["dst"] as? String,
              !src.isEmpty, !dst.isEmpty else {
            sendJSON(on: connection, status: 400, json: ["ok": false, "error": "Missing src/dst"],
                     request: request, isWebDAV: false)
            return
        }
        let cleanSrc = src.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanDst = dst.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let source = resolvedPath(cleanSrc, within: romsDirectory),
              let target = resolvedPath(cleanDst, within: romsDirectory) else {
            sendJSON(on: connection, status: 403, json: ["ok": false, "error": "Path traversal denied"],
                     request: request, isWebDAV: false)
            return
        }
        if target.path == source.path || target.path.hasPrefix(source.path + "/") {
            sendJSON(on: connection, status: 409, json: ["ok": false, "error": "Cannot move into itself"],
                     request: request, isWebDAV: false)
            return
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) {
                sendJSON(on: connection, status: 409, json: ["ok": false, "error": "Destination already exists"],
                         request: request, isWebDAV: false)
                return
            }
            try fm.moveItem(at: source, to: target)
            sendJSON(on: connection, status: 200, json: ["ok": true], request: request, isWebDAV: false)
        } catch {
            sendJSON(on: connection, status: 500, json: ["ok": false, "error": error.localizedDescription],
                     request: request, isWebDAV: false)
        }
    }

    private func handleHTTPMkdir(on connection: NWConnection, request: HTTPRequest, body: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let path = obj["path"] as? String, !path.isEmpty else {
            sendJSON(on: connection, status: 400, json: ["ok": false, "error": "Missing path"],
                     request: request, isWebDAV: false)
            return
        }
        let clean = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let resolved = resolvedPath(clean, within: romsDirectory) else {
            sendJSON(on: connection, status: 403, json: ["ok": false, "error": "Path traversal denied"],
                     request: request, isWebDAV: false)
            return
        }
        do {
            try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
            sendJSON(on: connection, status: 200, json: ["ok": true], request: request, isWebDAV: false)
        } catch {
            sendJSON(on: connection, status: 500, json: ["ok": false, "error": error.localizedDescription],
                     request: request, isWebDAV: false)
        }
    }

    private func serveHealth(on connection: NWConnection, request: HTTPRequest) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        sendJSON(on: connection, status: 200, json: [
            "ok": true,
            "app": pageTitle,
            "version": version,
            "features": ["move": true, "mkdir": true, "stats": false]
        ], request: request, isWebDAV: false)
    }
```

- [ ] **Step 3: Register the routes**

In `routeHTTP`, add cases before `default:`:

```swift
        case ("GET", "/api/health"):
            serveHealth(on: connection, request: request)
        case ("PUT", _) where path.hasPrefix("/files/"):
            // Small bodies that arrived fully buffered; large ones streamed in handleRequestWithBody.
            streamBrowserFilePut(on: connection, request: request, initialBody: body, remaining: 0)
        case ("POST", "/move"):
            handleHTTPMove(on: connection, request: request, body: body)
        case ("POST", "/mkdir"):
            handleHTTPMkdir(on: connection, request: request, body: body)
```

- [ ] **Step 4: Make the JS honour the health feature flag**

In `SRC/Resources/upload-page.js`, find `syncDebugStatsNav` (near the end). Its fetch success branch reveals `.debug-stats-nav` when `response.ok`. Change the condition so it also requires the flag:

```js
      const response = await fetch('/api/health', { cache: 'no-store' });
      let visible = response.ok;
      if (visible) {
        try { const j = await response.json(); visible = !!(j && j.features && j.features.stats); } catch (_) { visible = false; }
      }
```

and use `visible` where the existing code used `response.ok` for the show/hide decision (keep the rest of the function as is).

- [ ] **Step 5: Build, test, and exercise with curl on the simulator**

Run: `cd Source/iOS/PVWebServer && swift build 2>&1 | grep -E 'error' ; swift test 2>&1 | tail -3`
Expected: no errors, 34 tests pass.

Then build and run the app on a simulator (`xcodebuild ... -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`, open Settings so the server starts) and:

```bash
curl -s http://127.0.0.1:8080/api/health
curl -s -o /dev/null -w '%{http_code}\n' -T /bin/ls http://127.0.0.1:8080/files/Wii/ls.bin     # 204
curl -s -o /dev/null -w '%{http_code}\n' -T /bin/ls http://127.0.0.1:8080/files/../x            # 403
curl -s -X POST -d '{"path":"NewFolder"}' http://127.0.0.1:8080/mkdir                          # {"ok":true}
curl -s -X POST -d '{"src":"Wii/ls.bin","dst":"NewFolder/ls.bin"}' http://127.0.0.1:8080/move  # {"ok":true}
```

- [ ] **Step 6: Lint and commit**

```bash
swiftlint lint --config .swiftlint.yml Source/iOS/PVWebServer/Sources/PVWebServer/ROMUploadServer.swift
git add Source/iOS/PVWebServer/Sources/PVWebServer/ROMUploadServer.swift Source/iOS/PVWebServer/Sources/PVWebServer/Resources/upload-page.js
git commit -m "feat(webserver): raw PUT /files/, move, mkdir and health routes for the upload page

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Client-mode classification

**Files:**
- Create: `SRC/WebServerClientMode.swift`
- Test: `TESTS/WebServerClientModeTests.swift`

**Interfaces:**
- Produces: `enum WebServerClientMode: Equatable { case unknown, browser, webDAV; static func resolve(_ request: HTTPRequest, stored: WebServerClientMode) -> WebServerClientMode }`. Never returns `.unknown`. Task 8 stores the result per connection and passes it back as `stored` on the next request.

- [ ] **Step 1: Write the failing tests**

Create `TESTS/WebServerClientModeTests.swift`:

```swift
import XCTest
@testable import PVWebServer

final class WebServerClientModeTests: XCTestCase {
    private func req(_ line: String, _ headers: [String: String] = [:]) -> HTTPRequest {
        var text = line + " HTTP/1.1"
        for (k, v) in headers { text += "\r\n\(k): \(v)" }
        return HTTPRequest.parse(text)!
    }

    private func resolve(_ r: HTTPRequest, stored: WebServerClientMode = .unknown) -> WebServerClientMode {
        WebServerClientMode.resolve(r, stored: stored)
    }

    func testUploadUIRoutesAreBrowserRegardlessOfUserAgent() {
        let dav = ["User-Agent": "WebDAVFS/3.0.0 (03008000) Darwin/24.0.0"]
        XCTAssertEqual(resolve(req("PUT /files/a.iso", dav)), .browser)
        XCTAssertEqual(resolve(req("POST /upload", dav)), .browser)
        XCTAssertEqual(resolve(req("POST /move", dav)), .browser)
        XCTAssertEqual(resolve(req("POST /mkdir", dav)), .browser)
        XCTAssertEqual(resolve(req("GET /files/a.iso", dav)), .browser)
        XCTAssertEqual(resolve(req("DELETE /files/a.iso", dav)), .browser)
        XCTAssertEqual(resolve(req("GET /api/health", dav)), .browser)
    }

    func testWebDAVOnlyMethodsAreWebDAV() {
        for m in ["PROPFIND", "PROPPATCH", "MKCOL", "MOVE", "COPY", "LOCK", "UNLOCK"] {
            XCTAssertEqual(resolve(req("\(m) /x", ["User-Agent": "Mozilla/5.0"])), .webDAV, m)
        }
        XCTAssertEqual(resolve(req("PUT /Games/a.iso")), .webDAV)
    }

    func testStoredModeIsSticky() {
        // A headerless GET on a connection already classified as WebDAV stays WebDAV.
        XCTAssertEqual(resolve(req("GET /Games/a.iso"), stored: .webDAV), .webDAV)
        XCTAssertEqual(resolve(req("GET /"), stored: .webDAV), .webDAV)
        // And a browser connection stays browser for a bare OPTIONS.
        XCTAssertEqual(resolve(req("OPTIONS /"), stored: .browser), .browser)
    }

    func testWebDAVSignalHeaders() {
        XCTAssertEqual(resolve(req("GET /", ["Depth": "1"])), .webDAV)
        XCTAssertEqual(resolve(req("OPTIONS /", ["Translate": "f", "User-Agent": "Mozilla/5.0"])), .webDAV)
        XCTAssertEqual(resolve(req("GET /", ["Destination": "/y"])), .webDAV)
        XCTAssertEqual(resolve(req("GET /", ["Lock-Token": "<x>"])), .webDAV)
        XCTAssertEqual(resolve(req("GET /", ["Overwrite": "T"])), .webDAV)
        XCTAssertEqual(resolve(req("GET /", ["If": "(<opaquelocktoken:abc>)"])), .webDAV)
    }

    func testUserAgentLists() {
        XCTAssertEqual(resolve(req("GET /", ["User-Agent": "rclone/v1.66"])), .webDAV)
        XCTAssertEqual(resolve(req("GET /", ["User-Agent": "Cyberduck/9.0"])), .webDAV)
        XCTAssertEqual(resolve(req("GET /", ["User-Agent": "Microsoft-WebDAV-MiniRedir/10.0"])), .webDAV)
        XCTAssertEqual(resolve(req("GET /", ["User-Agent": "Mozilla/5.0 (iPhone) AppleWebKit/605"])), .browser)
        XCTAssertEqual(resolve(req("GET /", ["User-Agent": "Opera/9.80"])), .browser)
    }

    func testMethodHeuristicForHeaderlessClients() {
        XCTAssertEqual(resolve(req("OPTIONS /")), .webDAV)
        XCTAssertEqual(resolve(req("GET /Games/a.iso")), .webDAV)
        XCTAssertEqual(resolve(req("HEAD /Games/a.iso")), .webDAV)
        XCTAssertEqual(resolve(req("DELETE /Games/a.iso")), .webDAV)
        XCTAssertEqual(resolve(req("GET /")), .browser)
        XCTAssertEqual(resolve(req("GET /?path=Wii")), .browser)
        XCTAssertEqual(resolve(req("POST /something")), .browser)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Source/iOS/PVWebServer && swift test --filter WebServerClientModeTests 2>&1 | tail -3`
Expected: `cannot find 'WebServerClientMode' in scope`.

- [ ] **Step 3: Implement**

Create `SRC/WebServerClientMode.swift`:

```swift
// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
//  WebServerClientMode.swift
//  PVWebServer
//
//  One port serves both the browser upload UI and WebDAV. This decides, per request,
//  which one a client is. The result is stored per connection so a keep-alive socket
//  (Finder pipelines many requests) never flips mode mid-session.

import Foundation

enum WebServerClientMode: Equatable {
    case unknown
    case browser
    case webDAV

    /// Order of precedence matches the spec, section 4.1. Never returns `.unknown`.
    static func resolve(_ request: HTTPRequest, stored: WebServerClientMode) -> WebServerClientMode {
        if isDefinitelyBrowserRequest(request) { return .browser }
        if isDefinitelyWebDAVMethod(request.method) { return .webDAV }
        if stored != .unknown { return stored }
        if hasWebDAVSignalHeaders(request) { return .webDAV }
        if let ua = request.headers["user-agent"] {
            if isWebDAVUserAgent(ua) { return .webDAV }
            if isBrowserUserAgent(ua) { return .browser }
        }
        return methodHeuristicSaysWebDAV(request) ? .webDAV : .browser
    }

    /// Upload UI endpoints always route to the browser handler, whatever the User-Agent.
    private static func isDefinitelyBrowserRequest(_ request: HTTPRequest) -> Bool {
        switch request.method {
        case "POST":
            return ["/upload", "/move", "/mkdir"].contains { request.path.hasPrefix($0) }
        case "GET", "HEAD":
            return request.path.hasPrefix("/files/") || request.path.hasPrefix("/api/")
        case "PUT", "DELETE":
            return request.path.hasPrefix("/files/")
        default:
            return false
        }
    }

    private static func isDefinitelyWebDAVMethod(_ method: String) -> Bool {
        switch method {
        case "PROPFIND", "PROPPATCH", "MKCOL", "MOVE", "COPY", "LOCK", "UNLOCK", "PUT":
            return true
        default:
            return false
        }
    }

    private static func hasWebDAVSignalHeaders(_ request: HTTPRequest) -> Bool {
        let h = request.headers
        if h["depth"] != nil || h["destination"] != nil || h["lock-token"] != nil || h["overwrite"] != nil {
            return true
        }
        if let translate = h["translate"], !translate.isEmpty { return true } // Windows WebClient
        if let ifHeader = h["if"]?.lowercased(), ifHeader.contains("locktoken") { return true }
        return false
    }

    private static let webDAVUserAgentMarkers = [
        "webdavfs/", "webdavlib/", "microsoft-webdav-miniredir",
        "microsoft data access internet publishing provider",
        "cyberduck/", "davfs2/", "rclone/", "cadaver/", "netdrive/", "sardine/", "transmit/",
        "forklift/", "gvfs/", "litmus/", "mountain duck/", "mountainduck/", "bitkinex/",
        "owncloud-client", "nextcloud-android", "winscp/"
    ]

    private static func isWebDAVUserAgent(_ userAgent: String) -> Bool {
        let ua = userAgent.lowercased()
        return webDAVUserAgentMarkers.contains { ua.hasPrefix($0) || ua.contains($0) }
    }

    private static func isBrowserUserAgent(_ userAgent: String) -> Bool {
        let ua = userAgent.lowercased()
        return ua.hasPrefix("mozilla/") || ua.hasPrefix("opera/") || ua.contains("applewebkit/")
    }

    /// curl and scripts send no useful headers. Anything that is not the page or a
    /// browser download looks like a WebDAV filesystem walk.
    private static func methodHeuristicSaysWebDAV(_ request: HTTPRequest) -> Bool {
        switch request.method {
        case "OPTIONS":
            return true
        case "GET", "HEAD":
            if request.path == "/" { return false }
            if request.path.hasPrefix("/files/") { return false }
            return true
        case "DELETE":
            return !request.path.hasPrefix("/files/")
        default:
            return false
        }
    }
}
```

- [ ] **Step 4: Run all tests**

Run: `cd Source/iOS/PVWebServer && swift test 2>&1 | tail -3`
Expected: `Executed 40 tests, with 0 failures`.

- [ ] **Step 5: Lint and commit**

```bash
swiftlint lint --config .swiftlint.yml Source/iOS/PVWebServer/Sources/PVWebServer/WebServerClientMode.swift
git add Source/iOS/PVWebServer/Sources/PVWebServer/WebServerClientMode.swift Source/iOS/PVWebServer/Tests/PVWebServerTests/WebServerClientModeTests.swift
git commit -m "feat(webserver): per-request browser vs WebDAV classification

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: One listener, one port

**Files:**
- Modify: `SRC/ROMUploadServer.swift` (configuration, `start`, `stop`, `handleNewConnection`, `scheduleReceive`, `processIncomingBuffer`, `finishResponse`, `serveWebDAVFile`, `streamFileData`)
- Modify: `SRC/PVWebServer.swift` (facade URLs)
- Modify: `Source/iOS/App/Common/UI/Settings/SwiftUI/SettingsRootView.swift`, `Source/iOS/App/Common/Swift/LibraryWebImportView.swift`

**Interfaces:**
- Consumes: `WebServerClientMode.resolve(_:stored:)` (Task 7).
- Produces: `ROMUploadServer.port: UInt16` (bound port, 0 until started), `isRunning: Bool`, `serverURL: URL?`. `httpPort`, `webDAVPort`, `isHTTPRunning`, `isWebDAVRunning`, `webDAVURL` are removed from the engine; the facade maps its unchanged public API onto the new members.

- [ ] **Step 1: Configuration and state**

Replace:

```swift
    let httpPort: UInt16
    let webDAVPort: UInt16
```

with:

```swift
    /// Ports tried in order until one binds. Port 80 keeps the URL short on device.
    #if targetEnvironment(simulator)
    static let preferredPorts: [UInt16] = [8080, 8000, 8888, 9000]
    #else
    static let preferredPorts: [UInt16] = [80, 8080, 8000, 8888, 9000]
    #endif
    /// The port the listener bound, 0 while stopped.
    private(set) var port: UInt16 = 0
    /// A socket that connects but never delivers a request within this window is cancelled
    /// so `mount_webdav` retries on a fresh connection instead of hanging.
    private static let firstRequestGraceSeconds: TimeInterval = 12
```

In `ConnectionContext` replace `let isWebDAV: Bool` with:

```swift
        var clientMode: WebServerClientMode = .unknown
        var firstRequestSeen = false
        var didArmInitialReceive = false
        var watchdog: DispatchSourceTimer?
```

Replace `private var httpListener: NWListener?` and `private var webdavListener: NWListener?` with `private var listener: NWListener?` and add `private var bonjourWebDAV: NetService?`.

Remove the `init` port assignments (keep `self.romsDirectory = romsDirectory` and the `createDirectory`).

Replace `isWebDAVRunningUnlocked`, `isHTTPRunning`, `isWebDAVRunning`, `serverURL`, `webDAVURL` with:

```swift
    private var isRunningUnlocked: Bool { listener?.state == .ready }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return isRunningUnlocked
    }

    var serverURL: URL? {
        guard isRunning, let ip = getLocalIPAddress() else { return nil }
        return URL(string: "http://\(ip)\(Self.portSuffix(for: port))/")
    }

    static func portSuffix(for port: UInt16) -> String { port == 80 ? "" : ":\(port)" }
```

and in `bonjourServerURL` replace `isWebDAVRunningUnlocked` with `isRunningUnlocked` and `":\(webDAVPort)/"` with `"\(Self.portSuffix(for: port))/"`.

In `serveHTML`, replace `let portSuffix = httpPort == 80 ? "" : ":\(httpPort)"` with `let portSuffix = Self.portSuffix(for: port)`. The `NSLog` in the old `start()` that printed both ports goes away with it.

- [ ] **Step 2: Start with port fallback, stop everything**

Replace `start()` and `stop()`:

```swift
    /// Bind one listener on the first free port in `preferredPorts` and wait for `.ready`.
    /// Advertises `_http._tcp` through the listener and `_webdav._tcp` through NetService on
    /// the same name and port; mDNSResponder coalesces them.
    func start() async throws {
        guard !isRunning else { return }
        var lastError: Error?
        for candidate in Self.preferredPorts {
            do {
                try await startListener(on: candidate)
                port = candidate
                advertiseWebDAV(on: candidate)
                let root = romsDirectory
                Self.diskIOQueue.async {
                    _ = try? FileManager.default.contentsOfDirectory(
                        at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                        options: [.skipsHiddenFiles])
                }
                NSLog("[ROMUploadServer] started on :\(candidate)")
                return
            } catch {
                lastError = error
                NSLog("[ROMUploadServer] port \(candidate) unavailable (\(error)), trying next")
                stop()
            }
        }
        throw lastError ?? ROMUploadServerError.initializationFailed
    }

    private func startListener(on candidate: UInt16) async throws {
        let listener = try NWListener(using: Self.makeTCPParameters(), on: NWEndpoint.Port(rawValue: candidate)!)
        listener.newConnectionHandler = { [weak self] conn in self?.handleNewConnection(conn) }
        listener.service = NWListener.Service(name: pageTitle, type: "_http._tcp")
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            guard let self, case let .add(endpoint) = change, case let .hostPort(host, port) = endpoint else { return }
            let hostStr: String
            switch host {
            case .name(let n, _): hostStr = n
            case .ipv4(let a): hostStr = "\(a)"
            case .ipv6(let a): hostStr = "\(a)"
            @unknown default: return
            }
            self.lock.lock()
            self._bonjourServerURL = URL(string: "http://\(hostStr)\(Self.portSuffix(for: port.rawValue))/")
            self.lock.unlock()
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if !resumed { resumed = true; continuation.resume() }
                case .failed(let error):
                    NSLog("[ROMUploadServer] listener failed on :\(candidate): \(error)")
                    self?.stop()
                    if !resumed { resumed = true; continuation.resume(throwing: error) }
                case .cancelled:
                    if !resumed { resumed = true; continuation.resume(throwing: ROMUploadServerError.initializationFailed) }
                default:
                    break
                }
            }
            listener.start(queue: self.listenerQueue)
        }
        self.listener = listener
    }

    private func advertiseWebDAV(on candidate: UInt16) {
        let service = NetService(domain: "", type: "_webdav._tcp.", name: pageTitle, port: Int32(candidate))
        service.publish()
        bonjourWebDAV = service
    }

    func stop() {
        lock.lock()
        let conns = activeConnections
        let contexts = connectionContexts
        activeConnections.removeAll()
        connectionContexts.removeAll()
        _bonjourServerURL = nil
        lock.unlock()

        for ctx in contexts.values { ctx.watchdog?.cancel() }
        for conn in conns.values { conn.cancel() }
        listener?.cancel()
        listener = nil
        bonjourWebDAV?.stop()
        bonjourWebDAV = nil
        port = 0
        cachedIPAddress = nil
        NSLog("[ROMUploadServer] stopped")
    }
```

- [ ] **Step 3: Accept with a watchdog, read on `.ready`**

Replace `handleNewConnection(_:isWebDAV:)`:

```swift
    private func handleNewConnection(_ connection: NWConnection) {
        let connID = ObjectIdentifier(connection)
        let ioQueue = DispatchQueue(label: "org.dolphin.iCube.uploadserver.conn.\(connID)")

        let watchdog = DispatchSource.makeTimerSource(queue: ioQueue)
        watchdog.schedule(deadline: .now() + Self.firstRequestGraceSeconds)
        watchdog.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let seen = self.connectionContexts[connID]?.firstRequestSeen ?? true
            self.lock.unlock()
            guard !seen else { return }
            NSLog("[ROMUploadServer] connection stalled at establishment; cancelling so the client retries")
            connection.cancel()
        }

        lock.lock()
        activeConnections[connID] = connection
        var ctx = ConnectionContext(ioQueue: ioQueue, activeRequest: nil)
        ctx.watchdog = watchdog
        connectionContexts[connID] = ctx
        lock.unlock()
        watchdog.resume()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.armInitialReceiveIfNeeded(on: connection)
            case .waiting(let error):
                NSLog("[ROMUploadServer] inbound connection waiting: \(error)")
            case .cancelled, .failed:
                self.lock.lock()
                self.activeConnections.removeValue(forKey: connID)
                let dead = self.connectionContexts.removeValue(forKey: connID)
                self.lock.unlock()
                dead?.watchdog?.cancel()
            default:
                break
            }
        }
        connection.start(queue: ioQueue)
    }

    private func armInitialReceiveIfNeeded(on connection: NWConnection) {
        let connID = ObjectIdentifier(connection)
        lock.lock()
        guard var ctx = connectionContexts[connID], !ctx.didArmInitialReceive else { lock.unlock(); return }
        ctx.didArmInitialReceive = true
        let ioQueue = ctx.ioQueue
        connectionContexts[connID] = ctx
        lock.unlock()
        ioQueue.async { [weak self] in self?.scheduleReceive(on: connection, accumulated: Data()) }
    }

    private func noteFirstRequest(on connection: NWConnection) {
        let connID = ObjectIdentifier(connection)
        lock.lock()
        guard var ctx = connectionContexts[connID], !ctx.firstRequestSeen else { lock.unlock(); return }
        ctx.firstRequestSeen = true
        let watchdog = ctx.watchdog
        ctx.watchdog = nil
        connectionContexts[connID] = ctx
        lock.unlock()
        watchdog?.cancel()
    }

    /// Classify and remember this connection's mode.
    private func isWebDAVRequest(_ request: HTTPRequest, connection: NWConnection) -> Bool {
        let connID = ObjectIdentifier(connection)
        lock.lock()
        let stored = connectionContexts[connID]?.clientMode ?? .unknown
        let mode = WebServerClientMode.resolve(request, stored: stored)
        if var ctx = connectionContexts[connID] {
            ctx.clientMode = mode
            connectionContexts[connID] = ctx
        }
        lock.unlock()
        return mode == .webDAV
    }
```

- [ ] **Step 4: Drop `isWebDAV` from the pre-parse path**

Mechanical edits in `scheduleReceive` and `processIncomingBuffer`:

1. `scheduleReceive(on:isWebDAV:accumulated:)` → `scheduleReceive(on:accumulated:)`. Remove the parameter and every `isWebDAV: isWebDAV,` inside it (three call sites: the early `processIncomingBuffer`, the `asyncAfter` retry, and the receive completion).
2. `processIncomingBuffer(on:isWebDAV:buffer:)` → `processIncomingBuffer(on:buffer:)`. Inside, after `let request = HTTPRequest.parse(headersStr)` succeeds and before `let connID`, add:

```swift
            noteFirstRequest(on: connection)
            let isWebDAV = isWebDAVRequest(request, connection: connection)
```

   The 400 (bad request) and 413 (headers too large) responses in this function have no request yet; pass `isWebDAV: false` to them. The recursive call at the bottom drops its `isWebDAV:` argument.
3. `finishResponse`: replace `self?.processIncomingBuffer(on: connection, isWebDAV: ctx.isWebDAV, buffer: pipelined)` with `self?.processIncomingBuffer(on: connection, buffer: pipelined)` and the final `scheduleReceive(on: connection, isWebDAV: isWebDAV, accumulated: Data())` with `scheduleReceive(on: connection, accumulated: Data())`.
4. `handleRequestWithBody`, `beginChunkedBody`, `routeRequest` keep their `isWebDAV:` parameters; they now receive the classified value.

Build to catch every leftover: `cd Source/iOS/PVWebServer && swift build 2>&1 | grep error:` and fix each `extra argument 'isWebDAV'` / `missing argument` until clean.

- [ ] **Step 5: Keep-alive on WebDAV file GET**

Change `streamFileData` to take `forceClose: Bool = true` and finish through `finishResponse` when the body completed:

```swift
    private func streamFileData(handle: FileHandle, on connection: NWConnection,
                                remaining: Int, ioQueue: DispatchQueue? = nil,
                                forceClose: Bool = true) {
        let chunkSize = 256 * 1024
        guard remaining > 0 else {
            handle.closeFile()
            finishResponse(on: connection, request: nil, isWebDAV: true, forceClose: forceClose)
            return
        }
```

and pass `forceClose: forceClose` in the recursive call. A short read still calls `connection.cancel()` (truncated body, never reuse). In `serveWebDAVFile`, compute keep-alive from the context and use it in the header and the stream call:

```swift
        lock.lock()
        let keepAlive = connectionContexts[ObjectIdentifier(connection)]?.activeRequest?.wantsKeepAlive == true
        lock.unlock()
        header += keepAlive ? "Connection: keep-alive\r\n" : "Connection: close\r\n"
```

(replace the existing `Connection: close` line) and call `streamFileData(..., forceClose: !keepAlive)` there. The browser `serveFile` path keeps the default `forceClose: true`.

- [ ] **Step 6: Facade**

In `SRC/PVWebServer.swift`:

```swift
    @objc public var isWWWUploadServerRunning: Bool { server.isRunning }
    @objc public var isWebDavServerRunning: Bool { server.isRunning }
    @objc(WebDavURLString)
    public var webDavURLString: String? { server.serverURL?.absoluteString }
```

and in `startServers()` replace the log line with `NSLog("[PVWebServer] Started web server at \(self.server.serverURL?.absoluteString ?? "?") (HTTP + WebDAV on one port)")`. `startServers()`'s guard becomes `guard !server.isRunning else { return true }`.

- [ ] **Step 7: Settings copy**

`LibraryWebImportView.swift`: replace `urlRow(title: L("WebDAV"), url: webDavURL)` with `urlRow(title: L("Finder / WebDAV"), url: webDavURL)` and the footer text with:

```swift
          Text(L("Drop GameCube and Wii files onto iCube from a computer or phone on the same Wi-Fi. Open the address in a browser, or in Finder choose Go › Connect to Server and enter the same address as Guest."))
```

`SettingsRootView.swift`: same footer sentence in `webImportFooter`. Both views keep reading `webDavURLString`; it now equals the web URL.

- [ ] **Step 8: Build, test, device**

Run: `cd Source/iOS/PVWebServer && swift test 2>&1 | tail -3` → 40 tests pass.

Build to the iPhone and install:

```bash
cd Source/iOS/App && xcodebuild -workspace iCube.xcworkspace -scheme "iCube (NJB)" -configuration "Debug (Non-Jailbroken)" -destination "id=5BD0518D-E8D9-5115-919A-A7C12481E82D" -allowProvisioningUpdates -derivedDataPath ~/Library/Developer/Xcode/DerivedData/iCube-device build 2>&1 | grep -E ' error: |BUILD (SUCCEEDED|FAILED)' | sort -u
xcrun devicectl device install app --device 5BD0518D-E8D9-5115-919A-A7C12481E82D "$HOME/Library/Developer/Xcode/DerivedData/iCube-device/Build/Products/Debug (Non-Jailbroken)-iphoneos/iCube.app"
xcrun devicectl device process launch --device 5BD0518D-E8D9-5115-919A-A7C12481E82D com.joemattiello.iCube-debug
```

Open Settings on the phone (starts the server), note the URL, then on the Mac:

1. Finder › Go › Connect to Server › `http://<ip>/` as Guest: browse, drag a file in, rename it, delete it.
2. `dns-sd -B _webdav._tcp local` and `dns-sd -B _http._tcp local` both list iCube.
3. Safari: open `http://<ip>/`, drag a folder with two files, watch the transfer panel, confirm both land and the library snackbar fires.
4. `curl -s http://<ip>/api/health` and `curl -X PROPFIND -H 'Depth: 1' http://<ip>/ | head -c 300` (multistatus XML).
5. `rclone lsd :webdav:/ --webdav-url http://<ip>/` if rclone is installed.

- [ ] **Step 9: Lint and commit**

```bash
swiftlint lint --config .swiftlint.yml Source/iOS/PVWebServer/Sources/PVWebServer/ROMUploadServer.swift Source/iOS/PVWebServer/Sources/PVWebServer/PVWebServer.swift Source/iOS/App/Common/UI/Settings/SwiftUI/SettingsRootView.swift Source/iOS/App/Common/Swift/LibraryWebImportView.swift
git add Source/iOS/PVWebServer/Sources/PVWebServer/ROMUploadServer.swift Source/iOS/PVWebServer/Sources/PVWebServer/PVWebServer.swift Source/iOS/App/Common/UI/Settings/SwiftUI/SettingsRootView.swift Source/iOS/App/Common/Swift/LibraryWebImportView.swift
git commit -m "feat(webserver): one listener serves WebDAV and the upload UI on one port

Sticky per-connection client mode, port fallback 80→8080→8000→8888→9000,
establishment watchdog, keep-alive on WebDAV GET, Bonjour for both types
on the same port.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Benchmark script, Makefile target, final gates

**Files:**
- Create: `Source/iOS/App/Scripts/webserver_transfer_bench.sh`
- Modify: `Source/iOS/App/Makefile`

- [ ] **Step 1: Port the bench script**

```bash
cp "$IFLY/Scripts/webserver_transfer_bench.sh" Source/iOS/App/Scripts/webserver_transfer_bench.sh
chmod +x Source/iOS/App/Scripts/webserver_transfer_bench.sh
sed -i '' -e 's/SERVICE_NAME="iFly EMU"/SERVICE_NAME="iCube"/' \
          -e 's/Discovers iFly EMU via Bonjour (_http._tcp "iFly EMU")/Discovers iCube via Bonjour (_http._tcp "iCube")/' \
          -e 's/Start the iFly web server first/Open iCube Settings so the upload server starts/' \
          Source/iOS/App/Scripts/webserver_transfer_bench.sh
grep -n -i 'ifly' Source/iOS/App/Scripts/webserver_transfer_bench.sh ; echo "(expect no output)"
```

The script's `webdav` method PUTs to `/<name>`, `http_put` to `/files/<name>`, and `http_post` multipart to `/upload`. All three exist after Task 6. If the copied script names the WebDAV port separately anywhere (search for `81`), point it at the single URL.

- [ ] **Step 2: Makefile target**

In `Source/iOS/App/Makefile`, add `webserver-bench` to `.PHONY`, add to `help`:

```make
	@echo "  make webserver-bench — WebDAV vs browser PUT vs multipart upload throughput (Bonjour or URL=http://ip/)"
```

and the rule:

```make
# --- Upload server benchmark ----------------------------------------------
# Open Settings on the device first so the server is up. URL=http://ip/ skips Bonjour.
webserver-bench:
	./Scripts/webserver_transfer_bench.sh $(if $(URL),--url $(URL),)
```

- [ ] **Step 3: Run it against the device from Task 8**

Run: `cd Source/iOS/App && make webserver-bench URL=http://<ip>/`
Expected: a `SUMMARY (median)` line with three methods. Record the numbers in the commit message.

- [ ] **Step 4: Disk-full gate**

On the device, fill storage (upload a file larger than free space via Safari). Expected: the transfer panel shows the failure, the partial file is absent from Documents/Software, and no library snackbar appears. Then delete uploads to free space.

- [ ] **Step 5: Final checks and commit**

```bash
cd Source/iOS/PVWebServer && swift test 2>&1 | tail -3
cd ../../.. && swiftlint lint --config .swiftlint.yml Source/iOS/PVWebServer/Sources/PVWebServer
git add Source/iOS/App/Scripts/webserver_transfer_bench.sh Source/iOS/App/Makefile
git commit -m "build(webserver): transfer benchmark script and make webserver-bench

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

Then bump the Provenance gitlink from the parent repo (`cd ../../.. ` to `Provenance/`, `git add Cores/Dolphin/dolphin-ios`, commit) only when the user asks to push.
