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

  static func from(_ frameTimesMs: [Double], fps: [Double], speed: [Double]) -> BenchSummary {
    guard !frameTimesMs.isEmpty else {
      return BenchSummary(totalSamples: 0, meanMs: 0, minMs: 0, maxMs: 0, p95Ms: 0,
                          onePercentLowMs: 0, stdevMs: 0, meanFps: 0, meanSpeed: 0)
    }

    let count = Double(frameTimesMs.count)
    let mean = frameTimesMs.reduce(0, +) / count
    let sorted = frameTimesMs.sorted()
    let minVal = sorted.first ?? 0
    let maxVal = sorted.last ?? 0

    let p95idx = max(0, min(sorted.count - 1, Int(count * 0.95) - 1))
    let p95 = sorted[p95idx]

    // 1%-low: the mean of the slowest 1% of frames (largest frame times).
    // This is the standard "1% low" framing (worst 1% of frame pacing).
    let onePercentCount = max(1, Int((count * 0.01).rounded(.up)))
    let worst = sorted.suffix(onePercentCount)
    let onePercentLow = worst.reduce(0, +) / Double(worst.count)

    let variance = frameTimesMs.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / count
    let stdev = variance.squareRoot()

    let meanFps = fps.isEmpty ? 0 : fps.reduce(0, +) / Double(fps.count)
    let meanSpeed = speed.isEmpty ? 0 : speed.reduce(0, +) / Double(speed.count)

    func r3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
    return BenchSummary(
      totalSamples: frameTimesMs.count,
      meanMs: r3(mean), minMs: r3(minVal), maxMs: r3(maxVal),
      p95Ms: r3(p95), onePercentLowMs: r3(onePercentLow),
      stdevMs: r3(stdev), meanFps: r3(meanFps), meanSpeed: r3(meanSpeed))
  }
}

struct BenchResult: Codable, Sendable {
  let timestamp: Date
  let slot: Int
  let seconds: Double
  let thermalState: String
  let deviceModel: String
  let summary: BenchSummary
  /// Settings captured at the moment the run finished.
  let settings: [String: String]
}

struct SweepRunResult: Codable, Sendable {
  let value: String
  /// Whether the setting actually took effect for this run. For boot-time keys
  /// this is false unless a title-reboot primitive exists (see note in runSweep).
  let applied: Bool
  let result: BenchResult
}

struct SweepResult: Codable, Sendable {
  let key: String
  let hotSwappable: Bool
  /// Non-nil when the sweep could not validly measure the key.
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

  /// Run a single benchmark: load `slot`, let it settle, then sample for
  /// `seconds` at display rate. Returns nil if a run is already in progress.
  @discardableResult
  func runBenchmark(slot: Int, seconds: Double) async -> BenchResult? {
    guard !isRunning else { return nil }
    isRunning = true
    defer { isRunning = false }

    // Load the save state and let emulation settle before sampling.
    TVEmulationBridge.loadState(fromSlot: slot)
    try? await Task.sleep(for: .seconds(1.0))

    let samples = await sample(forSeconds: seconds)
    let summary = BenchSummary.from(samples.frameTimes, fps: samples.fps, speed: samples.speed)

    let result = BenchResult(
      timestamp: Date(),
      slot: slot,
      seconds: seconds,
      thermalState: Self.thermalStateName(),
      deviceModel: Self.deviceModel(),
      summary: summary,
      settings: Self.currentSettings())
    lastResult = result
    return result
  }

  /// Sweep a single setting across `values`, benchmarking each.
  ///
  /// HOT-SWAPPABLE keys: the change is applied live before each run, then
  /// runBenchmark reloads the slot so every run starts from an identical state.
  /// These deltas are valid.
  ///
  /// BOOT-TIME keys: a save-state load does NOT re-initialize the CPU core or
  /// video backend (Core/State.cpp LoadAs deserializes into the already-running
  /// core), so the new value is never read — the change is a silent no-op and
  /// any delta would be noise (the spec's "BIGGEST correctness risk"). Applying
  /// it correctly needs a title REBOOT (stop -> runWithBootParameter(current)
  /// -> loadState), but the app tree exposes no stored current boot parameter
  /// or reboot primitive (EmulationCoordinator has runEmulationWithBootParameter:
  /// but no current-param accessor; TVEmulationBridge has only stop /
  /// runWithBootParameter: / launchGameAtPath:). Until such a primitive is added
  /// (flagged in INTEGRATION.txt + CORE-HOOKS.patch.md PATCH 2), this method
  /// refuses to fake a delta: it marks boot-time runs `applied: false` with a
  /// warning and does not change the setting. An honest "cannot measure yet"
  /// beats a confident wrong number.
  func runSweep(key: String, values: [String], slot: Int, seconds: Double) async -> SweepResult {
    let hot = DOLSettingsKeyBridge.isHotSwappable(key)

    guard hot else {
      // Boot-time key: do not apply, do not pretend. Run a single baseline so
      // the caller still gets a sample, but flag every run as not-applied.
      let baseline = await runBenchmark(slot: slot, seconds: seconds)
      let runs: [SweepRunResult] = baseline.map {
        [SweepRunResult(value: "(unchanged)", applied: false, result: $0)]
      } ?? []
      return SweepResult(
        key: key,
        hotSwappable: false,
        warning: "boot-time setting requires a title reboot to take effect; "
          + "save-state reload does not re-init the core/backend, so a sweep "
          + "cannot validly measure this key without a reboot primitive (see "
          + "INTEGRATION.txt / CORE-HOOKS.patch.md PATCH 2). No values were applied.",
        runs: runs)
    }

    var runs: [SweepRunResult] = []
    for value in values {
      let applied = DOLSettingsKeyBridge.setKey(key, value: value)
      guard let result = await runBenchmark(slot: slot, seconds: seconds) else { continue }
      runs.append(SweepRunResult(value: value, applied: applied, result: result))
    }
    return SweepResult(key: key, hotSwappable: true, warning: nil, runs: runs)
  }

  // MARK: - Sampling

  private struct SampleSet {
    var frameTimes: [Double] = []
    var fps: [Double] = []
    var speed: [Double] = []
  }

  /// Poll DOLPerfBridge faster than the display refresh for the duration,
  /// recording each *new* raw per-frame dt. The raw dt is a per-frame atomic;
  /// polling above frame rate sees the same value repeatedly between frames, so
  /// we DE-DUP: a sample is only recorded when rawFrameTimeMs changes. fps/speed
  /// are captured alongside each recorded frame for the mean rollups.
  private func sample(forSeconds seconds: Double) async -> SampleSet {
    var set = SampleSet()

    // Sample a touch faster than the display so no frame's raw dt is missed.
    let refreshHz = Self.displayRefreshHz()
    let intervalMs = max(1.0, 1000.0 / (refreshHz * 2.0))

    var lastRaw: Double = -1
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      let snap = DOLPerfBridge.snapshot()
      let fps = (snap["fps"] as? NSNumber)?.doubleValue ?? 0
      let raw = (snap["rawFrameTimeMs"] as? NSNumber)?.doubleValue ?? 0
      let speed = (snap["speed"] as? NSNumber)?.doubleValue ?? 0
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

  // MARK: - Environment helpers

  private static func displayRefreshHz() -> Double {
    #if canImport(UIKit)
    let hz = UIScreen.main.maximumFramesPerSecond
    return hz > 0 ? Double(hz) : 60.0
    #else
    return 60.0
    #endif
  }

  private static func thermalStateName() -> String {
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
}
