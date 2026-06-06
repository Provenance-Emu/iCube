// Copyright 2026 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

// iCube stall / wasted-time instrumentation. The performance investigation found the core
// UNDER-utilizes the CPU (28fps at <90% CPU; Wii faster than GameCube) — so the question is not
// "make the hot ops cheaper" but "where does the CPU thread sit BLOCKED instead of running emulated
// code". This module answers that: every place the CPU thread waits on the GPU thread / a blocking
// video event / an encoder flush is wrapped in a scoped guard that (a) emits an Instruments signpost
// interval and (b) accumulates count/total/max into a per-site bucket. At the PerformanceMetrics
// speed-window boundary the buckets snapshot into a published Window and FormatReport() renders a
// compact diffable table for capture tooling (callable from Obj-C++, any thread).
//
// Layering: this header is pulled into AsyncRequests.h (the BlockingEvent site lives in a template
// method there), so it is kept deliberately light — the Site enum, the inline ScopedStall timer, and
// plain function decls only. It does NOT include PerformanceMetrics.h; FormatReport pulls the speed/
// bound sensors in the .cpp. The signpost half is Common/StallSignpost.h (usable even from Common).

#include <array>
#include <atomic>
#include <cstdint>
#include <string>

#include "Common/CommonTypes.h"
#include "Common/StallSignpost.h"

#ifdef __APPLE__
#include <mach/mach_time.h>
#else
#include <chrono>
#endif

namespace StallMetrics
{
// The CPU-thread wait sites we instrument. ThrottleSleep is deliberately NOT a Site: the throttle
// idle is intentional pacing and its duration is already measured by PerformanceMetrics
// (m_time_sleeping) — double-counting it here would be wrong, so it is reported on its own line
// from the value the window boundary passes in.
enum class Site : int
{
  GpuFlushWait = 0,  // dual-core: CPU thread waits for the GPU thread to drain the FIFO
  GpuSyncWait,       // dual-core sync-GPU: CPU thread waits on the sync wakeup event
  GpuDetWait,        // deterministic GPU thread: CPU thread waits on the mainloop
  BlockingEvent,     // dual-core: CPU thread blocks on a video event (EFB peek / bbox / perfquery)
  BBoxFlushWait,     // single-core / Metal inline: bbox read waits for flushed encoders
  ThreadSleep,       // Common::SleepCurrentThread (peripheral/IO threads — see .cpp, signpost-only)
  COUNT
};

// Refreshed from Config::MAIN_STALL_METRICS at each window boundary; gates Record() caller-side so a
// disabled build pays only one relaxed load per wait. Defined in the .cpp.
extern std::atomic<bool> s_enabled;

// Accumulate one wait of `ns` nanoseconds into `site`. Cheap: early-out when disabled, then relaxed
// adds plus a CAS to track the max. Safe from any thread.
void Record(Site site, u64 ns);

// RAII timer paired with the signpost guard via the ICUBE_SCOPED_STALL macro below. Times with the
// monotonic clock on the calling thread and Records on destruction. Header-inline so it costs a
// mach_absolute_time() pair around the wrapped wait. Engine-portable: steady_clock off Apple.
struct ScopedStall
{
  Site site;
#ifdef __APPLE__
  u64 t0 = mach_absolute_time();
#else
  std::chrono::steady_clock::time_point t0 = std::chrono::steady_clock::now();
#endif

  explicit ScopedStall(Site s) : site(s) {}

  ~ScopedStall()
  {
#ifdef __APPLE__
    // Cached timebase: mach_absolute_time() ticks -> ns. mach_timebase_info is constant for the
    // life of the process, so resolve it once.
    static const mach_timebase_info_data_t tb = [] {
      mach_timebase_info_data_t t{};
      mach_timebase_info(&t);
      return t;
    }();
    const u64 ticks = mach_absolute_time() - t0;
    Record(site, ticks * tb.numer / tb.denom);
#else
    const auto dt = std::chrono::steady_clock::now() - t0;
    Record(site,
           static_cast<u64>(std::chrono::duration_cast<std::chrono::nanoseconds>(dt).count()));
#endif
  }

  ScopedStall(const ScopedStall&) = delete;
  ScopedStall& operator=(const ScopedStall&) = delete;
};

// Register the calling thread under a human role ("CPU thread" / "Video thread" / ...) so the window
// boundary can sample its kernel-reported CPU utilization (Apple only; no-op elsewhere). Called once
// per thread from Core.cpp where the threads are named. Stores the mach thread send-right and KEEPS
// it (never deallocated) so thread_info() stays valid for cross-thread sampling at every window.
void RegisterThread(const char* role);

// Roll the accumulators into the published Window. `window_wall_ns` is the wall time the window
// covered; `throttle_sleep_ns` is the CPU thread's throttle-sleep for THIS window (the caller diffs
// PerformanceMetrics' cumulative m_time_sleeping). Called from the PerformanceMetrics speed-window
// boundary, wall-gated to ~1s. Cold path: takes a tiny spinlock.
void OnWindowBoundary(u64 window_wall_ns, u64 throttle_sleep_ns);

// Complete multi-line report for the most recent window, first line "=== STALL REPORT ===".
// Returns a short "stall metrics off" line if the flag is disabled or no window has rolled yet.
// Callable from any thread (Obj-C++ included). Kept under ~1.5 KB.
std::string FormatReport();
}  // namespace StallMetrics

// Place tightly around JUST the wait call, in its own scope block, e.g.:
//   {
//     ICUBE_SCOPED_STALL(StallMetrics::Site::GpuFlushWait, "gpu.flush.wait");
//     m_gpu_mainloop.Wait();
//   }
// Emits the Instruments interval AND the accumulator timing for the same lexical scope.
#define ICUBE_SCOPED_STALL(site, name)                                                             \
  ::StallMetrics::ScopedStall _icube_scoped_stall{(site)};                                         \
  ICUBE_STALL_INTERVAL(name)
