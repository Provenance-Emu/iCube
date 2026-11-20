// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Cumulative exit counters for one scope (foreground or background).
///
/// SDK-free model of MetricKit's `MXAppExitMetric`, the one first-party count of the exits no
/// crash handler can observe: watchdog and memory kills are SIGKILL. Field names mirror
/// `MXForegroundExitData` / `MXBackgroundExitData`; counters only the background variant has are
/// `0` for foreground.
struct AppExitCounts: Equatable, Sendable {
  /// Clean exits: the user swiped the app away, or the system reclaimed it normally.
  let normal: Int
  /// Exceeded the per-process memory limit.
  let memoryResourceLimit: Int
  /// Killed because the whole device was under memory pressure. Background only.
  let memoryPressure: Int
  /// Exceeded the background CPU budget. Background only.
  let cpuResourceLimit: Int
  let badAccess: Int
  /// Uncaught ObjC/C++ exception or `abort()`.
  let abnormal: Int
  let illegalInstruction: Int
  /// Took too long to launch, resume, suspend or answer a system event.
  let watchdog: Int
  /// `0xdead10cc`: suspended while holding a file or sqlite lock. Background only.
  let suspendedWithLockedFile: Int
  /// Began a background task and never ended it. Background only.
  let backgroundTaskAssertionTimeout: Int

  init(
    normal: Int, memoryResourceLimit: Int, memoryPressure: Int = 0, cpuResourceLimit: Int = 0, badAccess: Int,
    abnormal: Int, illegalInstruction: Int, watchdog: Int, suspendedWithLockedFile: Int = 0,
    backgroundTaskAssertionTimeout: Int = 0
  ) {
    self.normal = normal
    self.memoryResourceLimit = memoryResourceLimit
    self.memoryPressure = memoryPressure
    self.cpuResourceLimit = cpuResourceLimit
    self.badAccess = badAccess
    self.abnormal = abnormal
    self.illegalInstruction = illegalInstruction
    self.watchdog = watchdog
    self.suspendedWithLockedFile = suspendedWithLockedFile
    self.backgroundTaskAssertionTimeout = backgroundTaskAssertionTimeout
  }

  /// Every exit that was not a clean shutdown.
  var abnormalTotal: Int { nonZeroCounters.reduce(0) { $0 + $1.count } }

  var memoryKillTotal: Int { memoryResourceLimit + memoryPressure }

  var hasAbnormalExits: Bool { abnormalTotal > 0 }

  /// The counters above zero, in a fixed order.
  var nonZeroCounters: [(name: String, count: Int)] {
    let all: [(String, Int)] = [
      ("memoryResourceLimit", memoryResourceLimit),
      ("memoryPressure", memoryPressure),
      ("cpuResourceLimit", cpuResourceLimit),
      ("badAccess", badAccess),
      ("abnormal", abnormal),
      ("illegalInstruction", illegalInstruction),
      ("watchdog", watchdog),
      ("suspendedWithLockedFile", suspendedWithLockedFile),
      ("backgroundTaskAssertionTimeout", backgroundTaskAssertionTimeout),
    ]
    return all.filter { $0.1 > 0 }.map { (name: $0.0, count: $0.1) }
  }

  /// `normal=12 memoryResourceLimit=3`.
  var summaryLine: String {
    (["normal=\(normal)"] + nonZeroCounters.map { "\($0.name)=\($0.count)" }).joined(separator: " ")
  }
}

/// Foreground and background exit counters from one `MXMetricPayload`.
struct AppExitSummary: Equatable, Sendable {
  let foreground: AppExitCounts
  let background: AppExitCounts

  var hasAbnormalExits: Bool { foreground.hasAbnormalExits || background.hasAbnormalExits }

  /// Whether a payload is worth an event. The system ending a suspended app to free memory or
  /// CPU is the normal life of a background app on every device every day; everything else is
  /// not: any abnormal exit in the foreground, and a background crash, watchdog, locked file or
  /// unfinished background task.
  var isWorthReporting: Bool {
    foreground.hasAbnormalExits
      || background.abnormalTotal > background.memoryKillTotal + background.cpuResourceLimit
  }

  var title: String { "MetricKit app exits: \(dominantClass)" }

  /// Low-cardinality counts, so the exit classes can be filtered on.
  var sentryTags: [String: String] {
    [
      "exit.foreground.watchdog": String(foreground.watchdog),
      "exit.foreground.memory": String(foreground.memoryKillTotal),
      "exit.foreground.abnormal_total": String(foreground.abnormalTotal),
      "exit.background.watchdog": String(background.watchdog),
      "exit.background.memory": String(background.memoryKillTotal),
      "exit.background.locked_file": String(background.suspendedWithLockedFile),
      "exit.background.abnormal_total": String(background.abnormalTotal),
      "exit.dominant_class": dominantClass,
    ]
  }

  /// The largest abnormal-exit bucket across both scopes, or `none`. Ties go to the name that
  /// sorts first, so the value is the same every time.
  var dominantClass: String {
    let combined = (foreground.nonZeroCounters + background.nonZeroCounters)
      .reduce(into: [String: Int]()) { $0[$1.name, default: 0] += $1.count }
    let best = combined.max { lhs, rhs in lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value }
    return best?.key ?? "none"
  }
}
