// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
// TARGET PATH (when integrated):
//   Source/iOS/App/Common/Swift/Debug/DebugBenchmarkManager.swift
//
// Loads a save state, samples g_perf_metrics (via DOLPerfBridge) at the
// display refresh rate for N seconds, and computes a frame-time distribution.
//
// 1%-LOW: the bench samples DOLPerfBridge.rawFrameTimeMs — the last raw
// per-frame dt exposed by the core accessor PerformanceMetrics::
// GetLastRawFrameTimeMs() (added for this bench). A high-rate poll of that
// atomic oversamples identical values between frames, so sample() DE-DUPS on a
// changed value: only a new raw dt is recorded. That yields a genuine per-frame
// distribution and a real `onePercentLowMs` (mean of the slowest 1% of frames),
// not the smoothed-FPS approximation.
//
// BOOT-TIME KEYS AND REBOOTING: `DOLSettingsKeyBridge.isHotSwappable` tags
// each key. A hot-swappable key is re-read live by the core, so a save-state
// reload is enough to re-measure it. A boot-time key (e.g. the CIR
// specialization flags read once in `CachedInterpreter::Init`, or anything
// `EmulationCoordinator` bridges into Config before `BootManager::BootCore`)
// is only ever read at core init — a save-state reload does NOT re-run that
// init, so changing the value and reloading a state silently measures the
// SAME configuration again. For those keys `runSweep` performs a real
// stop -> boot -> load-state cycle per value, reusing the exact primitives
// `POST /api/debug/stop` / `POST /api/debug/boot` use (TVEmulationBridge.stop
// + the exit-to-library notification, then the DOLLaunchGameByGameID
// notification), not a loopback HTTP call.

import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Models

struct BenchSummary: Codable, Sendable {
  let totalSamples: Int
  let meanMs: Double
  let minMs: Double
  let maxMs: Double
  let p95Ms: Double
  /// Mean of the slowest 1% of frames (real per-frame 1%-low; see header note).
  let onePercentLowMs: Double
  let stdevMs: Double
  let meanFps: Double
  let meanSpeed: Double
}
// BenchSummary(from: FrameTimeStats) is defined in FrameTimeStats.swift, which owns the
// shared frame-time distribution math; this file only builds a BenchSummary from it.

struct BenchResult: Codable, Sendable {
  let timestamp: Date
  let slot: Int
  let seconds: Double
  let thermalState: String
  let deviceModel: String
  let summary: BenchSummary
  /// Settings captured immediately before sampling started (post-boot/post-load/post-settle),
  /// not at whatever later moment a caller happens to read this result — so a reader can trust
  /// that this is what was actually in force while the samples below were taken.
  let settings: [String: String]
  /// Non-nil when this run's `summary` should NOT be trusted as a real measurement (e.g. too
  /// few samples were captured, or the core wasn't in "running" state throughout). The numeric
  /// fields are still populated for forensics, but callers must not use them for an A/B delta.
  let warning: String?
}

struct SweepRunResult: Codable, Sendable {
  let value: String
  /// Whether DOLSettingsKeyBridge.setKey actually wrote the value.
  let applied: Bool
  /// Whether a stop -> boot -> load-state cycle was performed before this run to make a
  /// boot-time value take effect. Always false for hot-swappable keys (no reboot needed —
  /// a save-state reload is sufficient).
  let rebooted: Bool
  /// The resolved value of the swept key, read back from Config right alongside `settings`
  /// in the underlying `result` (nil when there is no result to read it from). Lets a reader
  /// confirm the intended `value` above and the config that was actually in force agree.
  let observedValue: String?
  /// Non-nil when this value could not be validly measured: `setKey` failed, the reboot never
  /// reached "running", or the run came back with an insufficient-samples warning. `result` is
  /// still populated when there is forensic data to look at (e.g. an under-sampled run), and nil
  /// when the run never happened at all.
  let error: String?
  let result: BenchResult?
}

struct SweepResult: Codable, Sendable {
  let key: String
  let hotSwappable: Bool
  /// Sweep-level issue that stopped every value from being measured (e.g. no game is running
  /// to reboot into, for a boot-time key). Per-value issues are reported in each run's `error`.
  let warning: String?
  let runs: [SweepRunResult]
}

// MARK: - DebugBenchmarkManager

@MainActor
final class DebugBenchmarkManager {
  static let shared = DebugBenchmarkManager()
  private init() {}

  private(set) var isRunning = false
  private(set) var lastResult: BenchResult?

  /// Set for the whole duration of `runSweep` (distinct from `isRunning`, which only covers a
  /// single `runBenchmark` call at a time) so a second overlapping sweep request is rejected
  /// instead of interleaving with an in-progress one.
  private(set) var isSweeping = false
  /// The most recently completed (or in-progress-until-this-is-updated) sweep. `POST
  /// /api/bench/sweep` starts a sweep fire-and-forget; this is how a caller reads the per-value
  /// results back out (see `GET /api/bench/sweep/result`).
  private(set) var lastSweepResult: SweepResult?

  // MARK: - Tuning constants

  /// How long to wait for the core to leave "running"/"stopping" after `TVEmulationBridge.stop()`.
  private static let stopTimeout: TimeInterval = 10
  /// The `DOLLaunchGameByGameID` notification is observed only by `TVLibraryView` while it is
  /// mounted, and a post made before an observer registers is dropped — NotificationCenter does
  /// not queue for latecomers. The library view re-mounts asynchronously after
  /// `DOLEmulationRequestExitToLibrary`, so a single post can race it. Repost on an interval
  /// until the boot has visibly started (state leaves "uninitialized") instead of posting once.
  private static let bootPostTimeout: TimeInterval = 15
  private static let bootPostInterval: TimeInterval = 0.5
  /// How long to wait for the core to reach "running" once a boot has visibly started.
  private static let bootRunningTimeout: TimeInterval = 30

  /// Run a single benchmark: wait for the core to be running, load `slot`, let it settle, then
  /// sample for `seconds` at display rate. Returns nil if a run is already in progress, the core
  /// never reached "running", or the state load failed.
  @discardableResult
  func runBenchmark(slot: Int, seconds: Double) async -> BenchResult? {
    guard !isRunning else { return nil }
    isRunning = true
    defer { isRunning = false }

    guard await Self.waitForCoreState(["running"], timeout: Self.bootRunningTimeout) else {
      NSLog("[Bench] runBenchmark: core never reached 'running' (state=\(DOLDebugBridge.coreState()))")
      return nil
    }
    // DOLDebugBridge.loadStateSlot blocks (on the host thread) until State::Load actually
    // completes and returns NO if the core isn't running — unlike
    // TVEmulationBridge.loadState(fromSlot:), which only queues an async host job with no
    // completion signal, so sampling could start before the state was actually in memory.
    guard DOLDebugBridge.loadStateSlot(slot) else {
      NSLog("[Bench] runBenchmark: loadStateSlot(\(slot)) failed (state=\(DOLDebugBridge.coreState()))")
      return nil
    }
    // Let frame pacing settle after the state reload before sampling.
    try? await Task.sleep(for: .seconds(1.0))

    // Settings as of the moment sampling actually begins — this is what a reader should trust
    // as "in force during this run", not whatever Config holds by the time the HTTP response
    // for GET /api/bench/result is read (which could be well after the next value was set).
    let settingsAtSampleTime = Self.currentSettings()

    let samples = await sample(forSeconds: seconds)
    let finalState = DOLDebugBridge.coreState()
    let summary = BenchSummary(from: FrameTimeStats.from(samples.frameTimes, fps: samples.fps, speed: samples.speed))
    let warning = Self.sampleValidityWarning(totalSamples: summary.totalSamples, seconds: seconds, finalCoreState: finalState)
    if let warning {
      NSLog("[Bench] runBenchmark: \(warning)")
    }

    let result = BenchResult(
      timestamp: Date(),
      slot: slot,
      seconds: seconds,
      thermalState: Self.thermalStateName(),
      deviceModel: Self.deviceModel(),
      summary: summary,
      settings: settingsAtSampleTime,
      warning: warning)
    lastResult = result
    return result
  }

  /// Sweep a single setting across `values`, benchmarking each.
  ///
  /// HOT-SWAPPABLE keys: the change is applied live before each run, then runBenchmark reloads
  /// the slot so every run starts from an identical state. These deltas are valid without a
  /// reboot.
  ///
  /// BOOT-TIME keys: the value is only read once, at core init. Each value therefore gets a
  /// real stop -> boot -> load-state cycle (see `rebootTitle`) before it is measured — a
  /// save-state reload alone would silently re-measure whatever configuration the core already
  /// booted with.
  func runSweep(key: String, values: [String], slot: Int, seconds: Double) async -> SweepResult {
    let hot = DOLSettingsKeyBridge.isHotSwappable(key)
    guard !isSweeping else {
      return SweepResult(key: key, hotSwappable: hot, warning: "a sweep is already running", runs: [])
    }
    isSweeping = true
    defer { isSweeping = false }

    let sweepResult: SweepResult
    if hot {
      sweepResult = await runHotSwappableSweep(key: key, values: values, slot: slot, seconds: seconds)
    } else {
      sweepResult = await runBootTimeSweep(key: key, values: values, slot: slot, seconds: seconds)
    }
    lastSweepResult = sweepResult
    return sweepResult
  }

  private func runHotSwappableSweep(key: String, values: [String], slot: Int, seconds: Double) async -> SweepResult {
    var runs: [SweepRunResult] = []
    for value in values {
      let applied = DOLSettingsKeyBridge.setKey(key, value: value)
      guard let result = await runBenchmark(slot: slot, seconds: seconds) else {
        runs.append(SweepRunResult(
          value: value, applied: applied, rebooted: false,
          observedValue: Self.resolvedValue(for: key),
          error: "benchmark run failed to start or load state (see device log)", result: nil))
        continue
      }
      runs.append(SweepRunResult(
        value: value, applied: applied, rebooted: false,
        observedValue: result.settings[key], error: result.warning, result: result))
    }
    return SweepResult(key: key, hotSwappable: true, warning: nil, runs: runs)
  }

  private func runBootTimeSweep(key: String, values: [String], slot: Int, seconds: Double) async -> SweepResult {
    // Capture the game to reboot into BEFORE anything is stopped — currentGameID() reads
    // SConfig's live GameID and returns "" once nothing is running.
    let gameID = TVEmulationBridge.currentGameID()
    guard !gameID.isEmpty else {
      return SweepResult(
        key: key, hotSwappable: false,
        warning: "boot-time setting requires a running game to reboot into; none is running "
          + "(POST /api/debug/boot a title first)",
        runs: [])
    }

    var runs: [SweepRunResult] = []
    for value in values {
      let applied = DOLSettingsKeyBridge.setKey(key, value: value)
      guard applied else {
        runs.append(SweepRunResult(
          value: value, applied: false, rebooted: false,
          observedValue: Self.resolvedValue(for: key),
          error: "DOLSettingsKeyBridge.setKey failed for '\(key)'", result: nil))
        continue
      }

      guard await rebootTitle(gameID: gameID) else {
        runs.append(SweepRunResult(
          value: value, applied: true, rebooted: false,
          observedValue: Self.resolvedValue(for: key),
          error: "reboot did not reach 'running' in time (state=\(DOLDebugBridge.coreState())); "
            + "the value was written but never actually measured",
          result: nil))
        continue
      }

      guard let result = await runBenchmark(slot: slot, seconds: seconds) else {
        runs.append(SweepRunResult(
          value: value, applied: true, rebooted: true,
          observedValue: Self.resolvedValue(for: key),
          error: "benchmark run failed after reboot (see device log)", result: nil))
        continue
      }
      runs.append(SweepRunResult(
        value: value, applied: true, rebooted: true,
        observedValue: result.settings[key], error: result.warning, result: result))
    }
    return SweepResult(key: key, hotSwappable: false, warning: nil, runs: runs)
  }

  /// Stops the running core and boots `gameID` fresh, so a boot-time config value is actually
  /// read by the next `BootManager::BootCore` / `CachedInterpreter::Init`. Reuses the exact same
  /// primitives `POST /api/debug/stop` and `POST /api/debug/boot` call (TVEmulationBridge.stop +
  /// the exit-to-library notification, then the DOLLaunchGameByGameID notification + the
  /// noJIT-skip flag), not a loopback HTTP request.
  private func rebootTitle(gameID: String) async -> Bool {
    TVEmulationBridge.stop()
    NotificationCenter.default.post(name: Notification.Name("DOLEmulationRequestExitToLibrary"), object: nil)

    guard await Self.waitForCoreState(["uninitialized", "unknown"], timeout: Self.stopTimeout) else {
      NSLog("[Bench] rebootTitle: stop did not reach 'uninitialized' within \(Self.stopTimeout)s "
        + "(state=\(DOLDebugBridge.coreState()))")
      return false
    }

    // Repost until the boot has visibly started (state leaves uninitialized) instead of posting
    // once — see the `bootPostTimeout` doc comment for why a single post can race the library
    // view remounting its observer.
    let postDeadline = Date().addingTimeInterval(Self.bootPostTimeout)
    while ["uninitialized", "unknown"].contains(DOLDebugBridge.coreState()) {
      guard Date() < postDeadline else {
        NSLog("[Bench] rebootTitle: no boot observer picked up gameID=\(gameID) within \(Self.bootPostTimeout)s")
        return false
      }
      // Same as POST /api/debug/boot's noJIT default: never let a reboot the harness triggers
      // block on an unattended "Waiting for JIT" dialog. Consumed once per actual boot, so it
      // must be set again on every repost.
      DebugServerManager.skipJITPromptOnce = true
      NotificationCenter.default.post(
        name: NSNotification.Name("DOLLaunchGameByGameID"), object: nil, userInfo: ["gameID": gameID])
      try? await Task.sleep(for: .seconds(Self.bootPostInterval))
    }

    guard await Self.waitForCoreState(["running"], timeout: Self.bootRunningTimeout) else {
      NSLog("[Bench] rebootTitle: boot did not reach 'running' within \(Self.bootRunningTimeout)s "
        + "(state=\(DOLDebugBridge.coreState()))")
      return false
    }
    return true
  }

  /// Polls `DOLDebugBridge.coreState()` until it is one of `targets`, or `timeout` elapses.
  private static func waitForCoreState(_ targets: Set<String>, timeout: TimeInterval, pollInterval: TimeInterval = 0.1) async -> Bool {
    if targets.contains(DOLDebugBridge.coreState()) { return true }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      try? await Task.sleep(for: .seconds(pollInterval))
      if targets.contains(DOLDebugBridge.coreState()) { return true }
    }
    return targets.contains(DOLDebugBridge.coreState())
  }

  // MARK: - Sampling

  private struct SampleSet {
    var frameTimes: [Double] = []
    var fps: [Double] = []
    var speed: [Double] = []
  }

  /// Poll DOLPerfBridge faster than the display refresh for the duration, recording each *new*
  /// raw per-frame dt. The raw dt is a per-frame atomic; polling above frame rate sees the same
  /// value repeatedly between frames, so we DE-DUP: a sample is only recorded when
  /// rawFrameTimeMs changes. fps/speed are captured alongside each recorded frame for the mean
  /// rollups.
  ///
  /// Note: if the core is paused or stalled for the whole window, `rawFrameTimeMs` holds a
  /// stale-but-positive value from the last real frame before the stall. That value differs
  /// from the initial `lastRaw = -1` sentinel on the very first poll, gets recorded once, and
  /// then never changes again — producing exactly the `totalSamples: 1` signature this harness
  /// has been seen to return. `runBenchmark` guards against reporting that as a real result via
  /// `sampleValidityWarning`.
  private func sample(forSeconds seconds: Double) async -> SampleSet {
    var set = SampleSet()

    // Sample a touch faster than the display so no frame's raw dt is missed.
    let refreshHz = Self.displayRefreshHz()
    let intervalMs = max(1.0, 1000.0 / (refreshHz * 2.0))

    var lastRaw: Double = -1
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      let snap = DOLPerfBridge.snapshot()
      let fps = snap["fps"]?.doubleValue ?? 0
      let raw = snap["rawFrameTimeMs"]?.doubleValue ?? 0
      let speed = snap["speed"]?.doubleValue ?? 0
      // De-dup: only record when the per-frame raw dt advanced to a new value.
      if raw > 0 && raw != lastRaw {
        lastRaw = raw
        set.frameTimes.append(raw)
        set.fps.append(fps)
        set.speed.append(speed)
      }
      try? await Task.sleep(for: .milliseconds(Int(intervalMs)))
    }
    return set
  }

  /// A run below this many samples (scaled by how long it sampled for) is not a measurement —
  /// it is the signature of the core being paused/stalled/not-yet-running for the whole window
  /// (see the `sample(forSeconds:)` doc comment). `seconds * 5` requires only 5fps sustained,
  /// well below any real (even thermally throttled) frame rate, with an absolute floor so a
  /// very short `seconds` sweep isn't required to hit an unreasonably high bar.
  private static func sampleValidityWarning(totalSamples: Int, seconds: Double, finalCoreState: String) -> String? {
    let minRequired = max(30, Int((seconds * 5).rounded()))
    if totalSamples < minRequired {
      return "only \(totalSamples) frame sample(s) captured in \(seconds)s (need >= \(minRequired)); "
        + "core state at end of sampling was '\(finalCoreState)'. This is not a valid measurement — "
        + "the core was likely paused, stalled, or not actually running for the sampling window."
    }
    if finalCoreState != "running" {
      return "core state was '\(finalCoreState)' (not 'running') at the end of sampling; "
        + "\(totalSamples) samples were captured but may not reflect steady-state emulation."
    }
    return nil
  }

  // MARK: - Environment helpers

  private static func displayRefreshHz() -> Double {
    #if canImport(UIKit)
    let hz = UIScreen.main.maximumFramesPerSecond
    return hz > 0 ? Double(hz) : 60.0
    #else
    return 60.0
    #endif
  }

  // Also surfaced by /api/health and /api/perf/live (server queue) so a soak can wait for a cool
  // device. nonisolated: ProcessInfo.thermalState is safe from any thread.
  nonisolated static func thermalStateName() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
  }

  private static func deviceModel() -> String {
    var sysinfo = utsname()
    uname(&sysinfo)
    let machine = withUnsafePointer(to: &sysinfo.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }
    return machine
  }

  /// Flatten the settings snapshot into string values for the result record.
  private static func currentSettings() -> [String: String] {
    let all = DOLSettingsKeyBridge.snapshotAll()
    var out: [String: String] = [:]
    for (key, meta) in all {
      if let v = meta["value"] { out[key] = "\(v)" }
    }
    return out
  }

  /// The single resolved value of `key`, for diagnostics on a run that never produced a full
  /// settings snapshot (e.g. a failed reboot).
  private static func resolvedValue(for key: String) -> String? {
    guard let meta = DOLSettingsKeyBridge.snapshotAll()[key], let value = meta["value"] else { return nil }
    return "\(value)"
  }
}
