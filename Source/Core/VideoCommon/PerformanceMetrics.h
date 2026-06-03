// Copyright 2022 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <atomic>
#include <deque>

#include "Common/CommonTypes.h"
#include "Core/Core.h"
#include "VideoCommon/PerformanceTracker.h"

namespace Core
{
class System;
}

class PerformanceMetrics
{
public:
  PerformanceMetrics() = default;
  ~PerformanceMetrics() = default;

  PerformanceMetrics(const PerformanceMetrics&) = delete;
  PerformanceMetrics& operator=(const PerformanceMetrics&) = delete;
  PerformanceMetrics(PerformanceMetrics&&) = delete;
  PerformanceMetrics& operator=(PerformanceMetrics&&) = delete;

  void Reset();

  void CountFrame();
  void CountVBlank();
  void OnEmulationStateChanged(Core::State state);

  // Call from CPU thread.
  void CountThrottleSleep(DT sleep);
  void AdjustClockSpeed(s64 ticks, u32 new_ppc_clock, u32 old_ppc_clock);
  void CountPerformanceMarker(s64 ticks, u32 ticks_per_second);

  // Getter Functions. May be called from any thread.
  double GetFPS() const;
  double GetVPS() const;
  double GetSpeed() const;
  double GetMaxSpeed() const;

  // Last raw frame time in ms (per-frame, atomic, any thread). For 1%-low capture.
  double GetLastRawFrameTimeMs() const;

  // --- iCube adaptive-controller sensors ---
  // Frame-time stability of the *presented* stream (host-thread frame counter), in seconds.
  // Both are flushed every present by DrawImGuiStats() -> UpdateStats(), which runs
  // unconditionally regardless of overlay visibility, so these are safe to poll from the
  // adaptive clock loop even when no on-screen stats are shown. May be called from any thread.
  double GetFrameDtAvgSeconds() const;
  double GetFrameDtStdSeconds() const;
  // Same, for the emulated v-blank (VPS) stream.
  double GetVBlankDtAvgSeconds() const;
  double GetVBlankDtStdSeconds() const;

  // Duplicate-present counter: incremented from the GPU thread (Callback_FramePresented) each
  // time VideoInterface presents a duplicate (repeated) frame. A high dup-present rate relative
  // to total presents means the emulated core is producing fields slower than the host refresh
  // (slow-motion game logic) — the lower-bound signal the clock loop watches. Monotonic counter;
  // callers diff successive reads. Any thread.
  static u64 GetDuplicatePresentCount();
  // Total presents (unique + duplicate) since boot. Any thread.
  static u64 GetTotalPresentCount();
  static void CountDuplicatePresent();
  static void CountAnyPresent();

  // Audio underrun counter: incremented from the audio (mixer) thread whenever the DMA mixer
  // FIFO starves (queue empty at dequeue). Monotonic; callers diff successive reads. Any thread.
  static u64 GetAudioUnderrunCount();
  static void CountAudioUnderrun();

  // Shared CPU-vs-GPU-bound classification, published by the resolution controller (which owns
  // the EFB-scale probe) and consumed by the clock loop so the two controllers never fight over
  // the same lever. Any thread.
  enum class Bound : int { Unknown = 0, CpuBound = 1, GpuBound = 2 };
  static Bound GetBound();
  static void SetBound(Bound b);

  // Shared CPU-vs-GPU-bound probe, decoupled from Auto-IR so the adaptive clock can classify the
  // bottleneck even when Auto-IR is OFF (the default). Inputs are the two speed sensors already
  // published every performance marker:
  //   speed    = achieved emulation speed vs realtime (throttle-capped at ~1.0)
  //   maxSpeed = speed with throttle sleep removed (the host's true headroom at the current clock)
  // Logic (delta probe, no EFB-scale nudge — the IR lever stays Auto-IR's alone):
  //   - maxSpeed below the keep-up threshold => the host genuinely can't keep up even with zero
  //     throttle sleep at this clock => CPU-bound (lowering CPU clock is the lever).
  //   - maxSpeed comfortably >= 1.0 (real headroom) while the presented speed is still short of
  //     target => the CPU is NOT the wall; the GPU/resolution is => GPU-bound (drop EFB scale).
  //   - otherwise inconclusive => Unknown (don't act; let the next window probe).
  // `speed_threshold` is the same f* GO/NO-GO threshold the clock loop uses. Returns the classified
  // bound; callers publish it via SetBound. Pure function (no global state), any thread.
  static Bound ClassifyBound(double speed, double max_speed, double speed_threshold);

  // Whether the iCube adaptive clock controller is currently running. Set by EmulationCoordinator
  // when it starts/stops the controller. Consulted by CoreTiming::GetVISkip so VI-skip can be
  // forced Off while the adaptive clock is on (step #4): VI-skip drops vblank IRQs to catch up,
  // which corrupts the adaptive clock's GetSpeed sensor (it reads "keeping up" only because frames
  // were dropped). The two catch-up mechanisms must not overlap. Any thread.
  static bool GetAdaptiveClockActive();
  static void SetAdaptiveClockActive(bool active);

  // ImGui Functions
  void DrawImGuiStats(const float backbuffer_scale);

private:
  PerformanceTracker m_fps_counter{"render_times.txt"};
  PerformanceTracker m_vps_counter{"vblank_times.txt"};

  double m_graph_max_time = 0.0;

  std::atomic<double> m_speed{};
  std::atomic<double> m_max_speed{};

  struct PerfSample
  {
    TimePoint clock_time;
    TimePoint work_time;
    s64 core_ticks;
  };

  std::deque<PerfSample> m_samples;
  DT m_time_sleeping{};
};

extern PerformanceMetrics g_perf_metrics;
