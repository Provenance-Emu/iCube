// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Sentry

/// Lightweight emulation FPS aggregator that uploads one sampled Sentry transaction per session.
final class EmulationPerfSessionRecorder {
  static let shared = EmulationPerfSessionRecorder()

  private let queue = DispatchQueue(label: "org.icube.sentry.perf-session", qos: .utility)
  private let lock = NSLock()

  private var sessionID = UUID()
  private var shouldReport = false
  private var startedAt: Date?
  private var timer: DispatchSourceTimer?

  private var frameTimesMs: [Double] = []
  private var fpsSamples: [Double] = []
  private var speedSamples: [Double] = []
  private var lastRawFrameTimeMs: Double = -1

  private init() {}

  func begin() {
    lock.lock()
    defer { lock.unlock() }

    stopTimerLocked()

    sessionID = UUID()
    #if DEBUG
    shouldReport = true
    #else
    shouldReport = Double.random(in: 0..<1) < SentryTelemetryService.releaseSessionSampleRate
    #endif

    startedAt = Date()
    frameTimesMs.removeAll(keepingCapacity: true)
    fpsSamples.removeAll(keepingCapacity: true)
    speedSamples.removeAll(keepingCapacity: true)
    lastRawFrameTimeMs = -1

    guard shouldReport else { return }

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
    timer.setEventHandler { [weak self] in
      self?.sampleOnce()
    }
    timer.resume()
    self.timer = timer
  }

  func finishAndReportIfSampled() {
    lock.lock()
    let report = shouldReport
    let started = startedAt
    let frames = frameTimesMs
    let fps = fpsSamples
    let speed = speedSamples
    let id = sessionID
    stopTimerLocked()
    shouldReport = false
    startedAt = nil
    frameTimesMs.removeAll(keepingCapacity: false)
    fpsSamples.removeAll(keepingCapacity: false)
    speedSamples.removeAll(keepingCapacity: false)
    lastRawFrameTimeMs = -1
    lock.unlock()

    guard report, let started else { return }

    let stats = FrameTimeStats.from(frames, fps: fps, speed: speed)
    guard stats.totalSamples > 0 else { return }

    let gameID = TVEmulationBridge.currentGameID()
    let duration = Date().timeIntervalSince(started)

    let transaction = SentrySDK.startTransaction(
      name: "emulation.session",
      operation: "emulation.session",
      bindToScope: false)
    transaction.setTag(value: gameID.isEmpty ? "unknown" : gameID, key: "game_id")
    transaction.setTag(value: id.uuidString, key: "session_id")
    transaction.setTag(value: consoleTag(for: gameID), key: "platform")

    transaction.setMeasurement(name: "fps.mean", value: NSNumber(value: stats.meanFps))
    transaction.setMeasurement(name: "fps.p50", value: NSNumber(value: fpsFromMs(stats.p50Ms)))
    transaction.setMeasurement(name: "fps.p90", value: NSNumber(value: fpsFromMs(stats.p90Ms)))
    transaction.setMeasurement(name: "fps.p95", value: NSNumber(value: fpsFromMs(stats.p95Ms)))
    transaction.setMeasurement(name: "frametime.p50_ms", value: NSNumber(value: stats.p50Ms))
    transaction.setMeasurement(name: "frametime.p90_ms", value: NSNumber(value: stats.p90Ms))
    transaction.setMeasurement(name: "frametime.p95_ms", value: NSNumber(value: stats.p95Ms))
    transaction.setMeasurement(name: "speed.mean", value: NSNumber(value: stats.meanSpeed))
    transaction.setMeasurement(name: "session.duration_s", value: NSNumber(value: duration))
    transaction.setMeasurement(name: "session.samples", value: NSNumber(value: stats.totalSamples))

    transaction.finish(status: .ok)
  }

  // MARK: - Private

  private func sampleOnce() {
    let snap = DOLPerfBridge.snapshot()
    let fps = snap["fps"]?.doubleValue ?? 0
    let raw = snap["rawFrameTimeMs"]?.doubleValue ?? 0
    let speed = snap["speed"]?.doubleValue ?? 0

    lock.lock()
    defer { lock.unlock() }
    guard shouldReport else { return }

    if raw > 0, raw != lastRawFrameTimeMs {
      lastRawFrameTimeMs = raw
      frameTimesMs.append(raw)
      fpsSamples.append(fps)
      speedSamples.append(speed)
    }
  }

  private func stopTimerLocked() {
    timer?.setEventHandler {}
    timer?.cancel()
    timer = nil
  }

  private func fpsFromMs(_ ms: Double) -> Double {
    guard ms > 0 else { return 0 }
    return 1000.0 / ms
  }

  private func consoleTag(for gameID: String) -> String {
    guard gameID.count >= 4 else { return "unknown" }
    if gameID.hasPrefix("R") || gameID.hasPrefix("S") || gameID.hasPrefix("W") {
      return "wii"
    }
    if gameID.hasPrefix("G") {
      return "gamecube"
    }
    return "unknown"
  }
}
