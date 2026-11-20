// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

final class MetricKitCrashReportTests: XCTestCase {
  /// Shaped like `MXCallStackTree.jsonRepresentation()`: a root frame is the innermost call and
  /// `subFrames` are its callers.
  private let segfaultJSON = Data("""
  {
    "callStackPerThread": true,
    "callStacks": [
      {
        "threadAttributed": false,
        "callStackRootFrames": [
          {"binaryName": "libsystem_kernel.dylib", "binaryUUID": "K", "offsetIntoBinaryTextSegment": 3476, "address": 1}
        ]
      },
      {
        "threadAttributed": true,
        "callStackRootFrames": [
          {
            "binaryName": "libsystem_platform.dylib", "binaryUUID": "P", "offsetIntoBinaryTextSegment": 2808, "address": 2,
            "subFrames": [
              {
                "binaryName": "PVlibDolphin-ios", "binaryUUID": "D", "offsetIntoBinaryTextSegment": 347584, "address": 3,
                "subFrames": [
                  {"binaryName": "iCube", "binaryUUID": "A", "offsetIntoBinaryTextSegment": 317520, "address": 4}
                ]
              }
            ]
          }
        ]
      }
    ]
  }
  """.utf8)

  private func report(
    json: Data? = nil, exceptionType: Int? = 1, signal: Int? = 11,
    terminationReason: String? = "Namespace SIGNAL, Code 11", build: String? = "1794551144"
  ) -> MetricKitCrashReport {
    MetricKitCrashReport(
      callStackTreeJSON: json ?? segfaultJSON, exceptionType: exceptionType, exceptionCode: nil,
      signal: signal, terminationReason: terminationReason, build: build)
  }

  func testUsesTheAttributedThreadInnermostFrameFirst() {
    XCTAssertEqual(report().frames.map(\.binaryName), ["libsystem_platform.dylib", "PVlibDolphin-ios", "iCube"])
  }

  func testReadsTheDocumentedShapeWithACallStackTreeWrapper() throws {
    let tree = try JSONSerialization.jsonObject(with: segfaultJSON)
    let wrapped = try JSONSerialization.data(withJSONObject: ["callStackTree": tree])
    XCTAssertEqual(report(json: wrapped).frames, report().frames)
  }

  func testCulpritIsTheInnermostFrameInTheAppsOwnCode() {
    XCTAssertEqual(report().culprit?.binaryName, "PVlibDolphin-ios")
    XCTAssertEqual(report().culprit?.line, "PVlibDolphin-ios +0x54dc0")
  }

  func testNamesTheSignalAndMachException() {
    XCTAssertEqual(report().exceptionLabel, "SIGSEGV / EXC_BAD_ACCESS")
    XCTAssertEqual(report().title, "MetricKit crash: SIGSEGV / EXC_BAD_ACCESS in PVlibDolphin-ios")
  }

  func testFingerprintAndTagsIdentifyTheCrashSiteAndBuild() {
    let report = report()
    XCTAssertEqual(report.fingerprint, ["metrickit-crash", "SIGSEGV / EXC_BAD_ACCESS", "PVlibDolphin-ios +0x54dc0"])
    XCTAssertEqual(report.sentryTags["crash.binary"], "PVlibDolphin-ios")
    XCTAssertEqual(report.sentryTags["crash.build"], "1794551144")
    XCTAssertEqual(report.sentryTags["crash.source"], "metrickit")
  }

  /// Sentry's own handler catches these in the process, so the same crash usually has a Sentry
  /// event too. The tag and the lower level keep the two from being counted as two crashes.
  func testASignalTheInProcessHandlerCatchesIsMarkedAsAnOverlap() {
    let report = report()
    XCTAssertTrue(report.isCatchableInProcess)
    XCTAssertEqual(report.sentryTags["crash.in_process_handler"], "catchable")
    XCTAssertEqual(report.severity, .error)
  }

  /// The launch watchdog ends the app with SIGKILL and code 0x8badf00d. No in-process handler
  /// sees it, so this is the only report of it.
  func testAWatchdogKillIsNamedAndFatal() {
    let report = report(
      exceptionType: 10, signal: 9, terminationReason: "Namespace FRONTBOARD, Code 2343432205")
    XCTAssertFalse(report.isCatchableInProcess)
    XCTAssertEqual(report.terminationKind, "watchdog")
    XCTAssertEqual(report.title, "MetricKit crash: SIGKILL / EXC_CRASH (watchdog) in PVlibDolphin-ios")
    XCTAssertEqual(report.sentryTags["crash.termination"], "watchdog")
    XCTAssertEqual(report.sentryTags["crash.in_process_handler"], "blind")
    XCTAssertEqual(report.severity, .fatal)
    XCTAssertEqual(report.fingerprint.first, "metrickit-crash")
  }

  func testTerminationCodesAreReadInDecimalAndHex() {
    XCTAssertEqual(report(terminationReason: "Namespace FRONTBOARD, Code 0x8badf00d").terminationKind, "watchdog")
    XCTAssertEqual(report(terminationReason: "Namespace RUNNINGBOARD, Code 3735883980").terminationKind, "locked file")
    XCTAssertEqual(report(terminationReason: "Namespace SPRINGBOARD, Code 0xc00010ff").terminationKind, "thermal")
    XCTAssertNil(report(terminationReason: "Namespace SIGNAL, Code 11").terminationKind)
    XCTAssertNil(report(terminationReason: nil).terminationKind)
  }

  func testUnknownNumbersAndUnparseableJSONStillProduceAReport() {
    let report = report(json: Data("not json".utf8), exceptionType: 99, signal: nil, terminationReason: nil, build: nil)
    XCTAssertTrue(report.frames.isEmpty)
    XCTAssertNil(report.culprit)
    XCTAssertEqual(report.exceptionLabel, "no signal / exception 99")
    XCTAssertEqual(report.parseError?.hasPrefix("JSON unreadable"), true)
    XCTAssertEqual(report.fingerprint.last, "unparsed-frames")
    XCTAssertEqual(report.sentryTags["crash.frames"], "unparsed")
    XCTAssertNil(report.sentryTags["crash.build"])
  }

  /// MetricKit's nesting for a `depth`-frame stack, built as text: Swift dictionaries this deep
  /// overflow the stack when serialized or freed.
  private func nestedStackJSON(depth: Int) -> Data {
    var frames = ""
    for level in 0 ..< depth {
      frames += "{\"binaryName\":\"PVFrame\",\"offsetIntoBinaryTextSegment\":\(level)"
      frames += level < depth - 1 ? ",\"subFrames\":[" : "}"
    }
    frames += String(repeating: "]}", count: depth - 1)
    return Data("{\"callStacks\":[{\"threadAttributed\":true,\"callStackRootFrames\":[\(frames)]}]}".utf8)
  }

  func testADeepStackFlattensInCallerOrder() {
    let depth = 200
    let report = report(json: nestedStackJSON(depth: depth))
    XCTAssertNil(report.parseError)
    XCTAssertEqual(report.frames.map(\.offset), (0 ..< UInt64(depth)).map { $0 })
  }

  /// `JSONSerialization` stops at 512 levels, about 250 frames: a stack-overflow crash must come
  /// out tagged, not as a frameless crash.
  func testAStackTooDeepForJSONSerializationIsReportedAsUnparsed() {
    let report = report(json: nestedStackJSON(depth: 2000))
    XCTAssertTrue(report.frames.isEmpty)
    XCTAssertEqual(report.parseError?.hasPrefix("JSON unreadable"), true)
    XCTAssertEqual(report.sentryTags["crash.frames"], "unparsed")
  }

  func testAPayloadWithoutCallStacksSaysSo() {
    let report = report(json: Data("{}".utf8))
    XCTAssertEqual(report.parseError, "no callStacks")
    XCTAssertTrue(report.frames.isEmpty)
  }
}
