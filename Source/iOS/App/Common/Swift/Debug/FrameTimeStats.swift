// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Shared frame-time distribution stats used by the debug benchmark and Sentry session recorder.
struct FrameTimeStats: Codable, Sendable {
  let totalSamples: Int
  let meanMs: Double
  let minMs: Double
  let maxMs: Double
  let p50Ms: Double
  let p90Ms: Double
  let p95Ms: Double
  /// Mean of the slowest 1% of frames (real per-frame 1%-low).
  let onePercentLowMs: Double
  let stdevMs: Double
  let meanFps: Double
  let meanSpeed: Double

  static func from(_ frameTimesMs: [Double], fps: [Double], speed: [Double]) -> FrameTimeStats {
    guard !frameTimesMs.isEmpty else {
      return FrameTimeStats(
        totalSamples: 0, meanMs: 0, minMs: 0, maxMs: 0,
        p50Ms: 0, p90Ms: 0, p95Ms: 0, onePercentLowMs: 0,
        stdevMs: 0, meanFps: 0, meanSpeed: 0)
    }

    let count = Double(frameTimesMs.count)
    let mean = frameTimesMs.reduce(0, +) / count
    let sorted = frameTimesMs.sorted()
    let minVal = sorted.first ?? 0
    let maxVal = sorted.last ?? 0

    func percentile(_ fraction: Double) -> Double {
      let idx = max(0, min(sorted.count - 1, Int((count * fraction).rounded(.up)) - 1))
      return sorted[idx]
    }

    let onePercentCount = max(1, Int((count * 0.01).rounded(.up)))
    let worst = sorted.suffix(onePercentCount)
    let onePercentLow = worst.reduce(0, +) / Double(worst.count)

    let variance = frameTimesMs.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / count
    let stdev = variance.squareRoot()

    let meanFps = fps.isEmpty ? 0 : fps.reduce(0, +) / Double(fps.count)
    let meanSpeed = speed.isEmpty ? 0 : speed.reduce(0, +) / Double(speed.count)

    func r3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
    return FrameTimeStats(
      totalSamples: frameTimesMs.count,
      meanMs: r3(mean),
      minMs: r3(minVal),
      maxMs: r3(maxVal),
      p50Ms: r3(percentile(0.50)),
      p90Ms: r3(percentile(0.90)),
      p95Ms: r3(percentile(0.95)),
      onePercentLowMs: r3(onePercentLow),
      stdevMs: r3(stdev),
      meanFps: r3(meanFps),
      meanSpeed: r3(meanSpeed))
  }
}

extension BenchSummary {
  init(from stats: FrameTimeStats) {
    totalSamples = stats.totalSamples
    meanMs = stats.meanMs
    minMs = stats.minMs
    maxMs = stats.maxMs
    p95Ms = stats.p95Ms
    onePercentLowMs = stats.onePercentLowMs
    stdevMs = stats.stdevMs
    meanFps = stats.meanFps
    meanSpeed = stats.meanSpeed
  }
}
