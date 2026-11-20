// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One frame of an `MXCallStackTree`, innermost first.
struct MetricKitCrashFrame: Equatable, Sendable {
  let binaryName: String
  let binaryUUID: String
  let offset: UInt64

  /// `Binary +0xOFFSET`, the form `atos -l` symbolicates against a dSYM.
  var line: String { "\(binaryName) +0x\(String(offset, radix: 16))" }

  /// iCube's own code: the app, the Dolphin core and the PV* and skin frameworks.
  var isAppCode: Bool {
    binaryName.hasPrefix("iCube") || binaryName.hasPrefix("PV") || binaryName.hasPrefix("Skin")
  }
}

/// SDK-free model of one `MXCrashDiagnostic`, built from its call-stack JSON so the mapping is
/// testable on every platform (MetricKit is unavailable on tvOS).
///
/// Sentry's crash handler only sees a crash that raises a signal inside the process after the SDK
/// has started. The launch watchdog and the memory limit end the app with SIGKILL, and a crash
/// before `SentrySDK.start` has no handler yet; sentry-cocoa's MetricKit integration forwards
/// hangs, CPU and disk-write diagnostics but not crashes. The system's own crash diagnostic
/// covers all of those, a day later.
struct MetricKitCrashReport: Equatable, Sendable {
  enum Severity: Equatable, Sendable { case error, fatal }

  /// Frames of the crashed (attributed) thread, innermost first.
  let frames: [MetricKitCrashFrame]
  let exceptionType: Int?
  let exceptionCode: Int?
  let signal: Int?
  let terminationReason: String?
  let build: String?
  /// Why `frames` is empty when the call-stack JSON could not be read. The raw JSON still goes
  /// out as an attachment.
  let parseError: String?

  /// How many frames go into the event context; enough to see the caller chain.
  static let contextFrameLimit = 30

  /// - Parameter callStackTreeJSON: `MXCallStackTree.jsonRepresentation()`.
  init(
    callStackTreeJSON: Data, exceptionType: Int?, exceptionCode: Int?, signal: Int?,
    terminationReason: String?, build: String?
  ) {
    switch Self.attributedFrames(in: callStackTreeJSON) {
    case let .success(frames):
      self.frames = frames
      parseError = nil
    case let .failure(error):
      frames = []
      parseError = error.message
    }
    self.exceptionType = exceptionType
    self.exceptionCode = exceptionCode
    self.signal = signal
    self.terminationReason = terminationReason
    self.build = build
  }

  /// `SIGSEGV / EXC_BAD_ACCESS`, falling back to the raw numbers.
  var exceptionLabel: String {
    let signalName = signal.map { Self.signalNames[$0] ?? "signal \($0)" } ?? "no signal"
    let typeName = exceptionType.map { Self.exceptionTypeNames[$0] ?? "exception \($0)" } ?? "no exception"
    return "\(signalName) / \(typeName)"
  }

  /// What the system's termination code means, for the codes that are not a signal number:
  /// `watchdog` (0x8badf00d: too slow to launch, resume or suspend), `locked file` (0xdead10cc)
  /// and `thermal` (0xc00010ff).
  var terminationKind: String? {
    guard let reason = terminationReason, let range = reason.range(of: "Code ") else { return nil }
    let token = reason[range.upperBound...].prefix { $0.isHexDigit || $0 == "x" || $0 == "X" }
    let code = token.lowercased().hasPrefix("0x") ? UInt64(token.dropFirst(2), radix: 16) : UInt64(token)
    return code.flatMap { Self.terminationKinds[$0] }
  }

  /// Whether a signal handler inside the process could have caught this. When it could, Sentry's
  /// crash handler has normally reported the same crash already.
  var isCatchableInProcess: Bool {
    signal.map(Self.catchableSignals.contains) ?? false
  }

  /// A kill only MetricKit reports is fatal; one Sentry probably has as well is filed lower so the
  /// same crash is not counted as two fatal ones.
  var severity: Severity { isCatchableInProcess ? .error : .fatal }

  /// The innermost frame in iCube's own code, else the innermost frame.
  var culprit: MetricKitCrashFrame? {
    frames.first(where: \.isAppCode) ?? frames.first
  }

  var title: String {
    let kind = terminationKind.map { " (\($0))" } ?? ""
    return "MetricKit crash: \(exceptionLabel)\(kind) in \(culprit?.binaryName ?? "unknown")"
  }

  /// Groups the same crash together across devices; offsets are stable per build.
  var fingerprint: [String] {
    ["metrickit-crash", exceptionLabel, culprit?.line ?? (parseError == nil ? "no-frames" : "unparsed-frames")]
  }

  var sentryTags: [String: String] {
    var tags = [
      "crash.source": "metrickit",
      "crash.exception": exceptionLabel,
      "crash.in_process_handler": isCatchableInProcess ? "catchable" : "blind",
    ]
    if let culprit { tags["crash.binary"] = culprit.binaryName }
    if let build { tags["crash.build"] = build }
    if let terminationKind { tags["crash.termination"] = terminationKind }
    if parseError != nil { tags["crash.frames"] = "unparsed" }
    return tags
  }

  /// Frame lines for the event context, innermost first.
  var contextFrames: [String] {
    frames.prefix(Self.contextFrameLimit).map(\.line)
  }

  // MARK: - Parsing

  struct ParseError: Error, Equatable {
    let message: String
  }

  /// The attributed thread's frames, or the first thread's when none is marked.
  ///
  /// `jsonRepresentation()` puts `callStacks` at the top level, but Apple documents it inside a
  /// `callStackTree` object, so both shapes are accepted. A stack-overflow crash nests one level
  /// per frame and can exceed `JSONSerialization`'s depth limit; that failure is reported rather
  /// than passed off as a frameless crash.
  static func attributedFrames(in json: Data) -> Result<[MetricKitCrashFrame], ParseError> {
    let parsed: Any
    do {
      parsed = try JSONSerialization.jsonObject(with: json)
    } catch {
      return .failure(ParseError(message: "JSON unreadable: \(error.localizedDescription)"))
    }
    guard let object = parsed as? [String: Any] else {
      return .failure(ParseError(message: "JSON root is not an object"))
    }
    let tree = object["callStackTree"] as? [String: Any] ?? object
    guard let stacks = tree["callStacks"] as? [[String: Any]] else {
      return .failure(ParseError(message: "no callStacks"))
    }
    let stack = stacks.first { $0["threadAttributed"] as? Bool == true } ?? stacks.first
    guard let roots = stack?["callStackRootFrames"] as? [[String: Any]] else {
      return .failure(ParseError(message: "no callStackRootFrames"))
    }
    return .success(flatten(roots))
  }

  /// A root frame is the innermost call; its `subFrames` are its callers. Iterative, depth-first
  /// in document order: MetricKit delivers on a background queue, and recursing once per frame of
  /// a deep report could overflow that thread's stack.
  private static func flatten(_ roots: [[String: Any]]) -> [MetricKitCrashFrame] {
    var frames: [MetricKitCrashFrame] = []
    var pending = Array(roots.reversed())
    while let node = pending.popLast() {
      frames.append(MetricKitCrashFrame(
        binaryName: node["binaryName"] as? String ?? "??",
        binaryUUID: node["binaryUUID"] as? String ?? "",
        offset: (node["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value ?? 0))
      if let callers = node["subFrames"] as? [[String: Any]] {
        pending.append(contentsOf: callers.reversed())
      }
    }
    return frames
  }

  private static let signalNames: [Int: String] = [
    4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV",
  ]

  /// The signals a crash handler installs for. SIGKILL (9) cannot be caught.
  private static let catchableSignals: Set<Int> = [4, 5, 6, 8, 10, 11]

  /// Mach exception numbers from `<mach/exception_types.h>`.
  private static let exceptionTypeNames: [Int: String] = [
    1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC",
    6: "EXC_BREAKPOINT", 10: "EXC_CRASH", 11: "EXC_RESOURCE", 12: "EXC_GUARD",
  ]

  private static let terminationKinds: [UInt64: String] = [
    0x8BAD_F00D: "watchdog", 0xDEAD_10CC: "locked file", 0xC000_10FF: "thermal",
  ]
}
