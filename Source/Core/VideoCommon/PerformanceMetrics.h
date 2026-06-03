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
