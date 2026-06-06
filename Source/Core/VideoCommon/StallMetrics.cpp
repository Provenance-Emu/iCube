// Copyright 2026 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "VideoCommon/StallMetrics.h"

#include <array>
#include <atomic>
#include <cstdio>
#include <string_view>

#include "Core/Config/MainSettings.h"
#include "VideoCommon/PerformanceMetrics.h"

#ifdef __APPLE__
#include <mach/mach.h>
#include <mach/mach_init.h>
#include <mach/thread_act.h>
#endif

namespace StallMetrics
{
std::atomic<bool> s_enabled{true};

namespace
{
// --- Live accumulators (hot path) -------------------------------------------------------------
// One bucket per Site. Relaxed atomics: the numbers are diagnostic, exactness across the
// snapshot boundary is not required (a wait straddling the boundary lands in one window or the
// next — never lost, never double-counted within a window).
struct Accum
{
  std::atomic<u64> count{0};
  std::atomic<u64> total_ns{0};
  std::atomic<u64> max_ns{0};
};

constexpr std::size_t kNumSites = static_cast<std::size_t>(Site::COUNT);
std::array<Accum, kNumSites> s_accum;

// --- Published window (cold path, read by FormatReport) ---------------------------------------
struct SiteSnapshot
{
  u64 count = 0;
  u64 total_ns = 0;
  u64 max_ns = 0;
};

#ifdef __APPLE__
constexpr int kMaxThreads = 8;
struct ThreadEntry
{
  const char* role = nullptr;
  thread_act_t port = MACH_PORT_NULL;
  // Cumulative kernel-reported CPU time at the last window boundary (user+system), nanoseconds.
  u64 last_cpu_ns = 0;
  bool have_last = false;
};

struct ThreadUtilSnapshot
{
  const char* role = nullptr;
  double util_pct = 0.0;        // (user+system) delta / wall, from THREAD_BASIC_INFO
  int kern_est_pct = 0;         // THREAD_EXTENDED_INFO pth_cpu_usage cross-check (0..1000 -> %)
  int run_state = 0;            // THREAD_EXTENDED_INFO pth_run_state
  bool valid = false;
};
#endif

struct Window
{
  u64 window_wall_ns = 0;
  u64 throttle_sleep_ns = 0;
  std::array<SiteSnapshot, kNumSites> sites{};
  double speed = 0.0;
  double max_speed = 0.0;
  PerformanceMetrics::Bound bound = PerformanceMetrics::Bound::Unknown;
  u64 audio_underrun_delta = 0;
  bool dual_core = false;
  bool valid = false;  // false until the first window rolls
#ifdef __APPLE__
  std::array<ThreadUtilSnapshot, kMaxThreads> threads{};
  int thread_count = 0;
#endif
};

// Tiny spinlock guarding the published window + the thread table. Both are touched only at the
// (≈1 Hz) window boundary and by the (rare) FormatReport reader, so a spinlock is cheaper than a
// mutex and there is no contention worth measuring.
std::atomic_flag s_lock = ATOMIC_FLAG_INIT;
Window s_window;

struct SpinGuard
{
  SpinGuard() { while (s_lock.test_and_set(std::memory_order_acquire)) {} }
  ~SpinGuard() { s_lock.clear(std::memory_order_release); }
};

#ifdef __APPLE__
std::array<ThreadEntry, kMaxThreads> s_threads;
std::atomic<int> s_thread_count{0};

// (user+system) CPU time for a thread port, in ns, via THREAD_BASIC_INFO. Returns false if the
// port is dead / the call fails.
bool ReadThreadCpuNs(thread_act_t port, u64* out_ns)
{
  thread_basic_info_data_t info{};
  mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
  if (thread_info(port, THREAD_BASIC_INFO, reinterpret_cast<thread_info_t>(&info), &count) !=
      KERN_SUCCESS)
  {
    return false;
  }
  const u64 user_ns = static_cast<u64>(info.user_time.seconds) * 1000000000ull +
                      static_cast<u64>(info.user_time.microseconds) * 1000ull;
  const u64 sys_ns = static_cast<u64>(info.system_time.seconds) * 1000000000ull +
                    static_cast<u64>(info.system_time.microseconds) * 1000ull;
  *out_ns = user_ns + sys_ns;
  return true;
}

// Cross-check fields from THREAD_EXTENDED_INFO. pth_cpu_usage is in TH_USAGE_SCALE units
// (0..1000 == 0..100%); pth_run_state is TH_STATE_RUNNING/WAITING/... Returns false on failure.
bool ReadThreadExtended(thread_act_t port, int* cpu_usage_pct, int* run_state)
{
  thread_extended_info_data_t info{};
  mach_msg_type_number_t count = THREAD_EXTENDED_INFO_COUNT;
  if (thread_info(port, THREAD_EXTENDED_INFO, reinterpret_cast<thread_info_t>(&info), &count) !=
      KERN_SUCCESS)
  {
    return false;
  }
  // TH_USAGE_SCALE is 1000; report as a 0..100 percent.
  *cpu_usage_pct = static_cast<int>(info.pth_cpu_usage) / 10;
  *run_state = info.pth_run_state;
  return true;
}
#endif  // __APPLE__
}  // namespace

void Record(Site site, u64 ns)
{
  if (!s_enabled.load(std::memory_order_relaxed))
    return;

  Accum& a = s_accum[static_cast<std::size_t>(site)];
  a.count.fetch_add(1, std::memory_order_relaxed);
  a.total_ns.fetch_add(ns, std::memory_order_relaxed);

  // CAS the running max upward.
  u64 prev = a.max_ns.load(std::memory_order_relaxed);
  while (ns > prev && !a.max_ns.compare_exchange_weak(prev, ns, std::memory_order_relaxed))
  {
  }
}

void RegisterThread([[maybe_unused]] const char* role)
{
#ifdef __APPLE__
  // mach_thread_self() returns a send right carrying a reference; we KEEP it (never deallocate) so
  // the stored port stays valid for cross-thread thread_info() at every later window boundary.
  const thread_act_t port = mach_thread_self();

  SpinGuard guard;
  // Replace an existing entry for the same role (e.g. single-core CPU-GPU re-register) in place.
  const int n = s_thread_count.load(std::memory_order_relaxed);
  for (int i = 0; i < n; ++i)
  {
    if (s_threads[i].role && role && std::string_view(s_threads[i].role) == role)
    {
      s_threads[i].port = port;
      s_threads[i].have_last = false;
      return;
    }
  }
  if (n < kMaxThreads)
  {
    s_threads[n] = ThreadEntry{role, port, 0, false};
    s_thread_count.store(n + 1, std::memory_order_relaxed);
  }
#endif
}

void OnWindowBoundary(u64 window_wall_ns, u64 throttle_sleep_ns)
{
  // Refresh the hot-path gate from Config once per window (cold path is the right place to touch
  // Config; the hot path only sees the cached atomic).
  const bool enabled = Config::Get(Config::MAIN_STALL_METRICS);
  s_enabled.store(enabled, std::memory_order_relaxed);

  // Exchange the live accumulators out regardless, so a disable->enable transition starts clean.
  std::array<SiteSnapshot, kNumSites> sites{};
  for (std::size_t i = 0; i < kNumSites; ++i)
  {
    sites[i].count = s_accum[i].count.exchange(0, std::memory_order_relaxed);
    sites[i].total_ns = s_accum[i].total_ns.exchange(0, std::memory_order_relaxed);
    sites[i].max_ns = s_accum[i].max_ns.exchange(0, std::memory_order_relaxed);
  }

  // Audio-underrun delta across the window (the counter is monotonic since boot).
  static u64 s_last_audio_underrun = 0;
  const u64 audio_now = PerformanceMetrics::GetAudioUnderrunCount();
  const u64 audio_delta = audio_now - s_last_audio_underrun;
  s_last_audio_underrun = audio_now;

  SpinGuard guard;
  s_window.window_wall_ns = window_wall_ns;
  s_window.throttle_sleep_ns = throttle_sleep_ns;
  s_window.sites = sites;
  s_window.speed = g_perf_metrics.GetSpeed();
  s_window.max_speed = g_perf_metrics.GetMaxSpeed();
  s_window.bound = PerformanceMetrics::GetBound();
  s_window.audio_underrun_delta = audio_delta;
  s_window.dual_core = Config::Get(Config::MAIN_CPU_THREAD);
  s_window.valid = true;

#ifdef __APPLE__
  const int n = s_thread_count.load(std::memory_order_relaxed);
  s_window.thread_count = 0;
  const double wall_ns = window_wall_ns > 0 ? static_cast<double>(window_wall_ns) : 1.0;
  for (int i = 0; i < n && i < kMaxThreads; ++i)
  {
    ThreadEntry& e = s_threads[i];
    ThreadUtilSnapshot snap{};
    snap.role = e.role;

    u64 cpu_ns = 0;
    if (ReadThreadCpuNs(e.port, &cpu_ns))
    {
      if (e.have_last)
        snap.util_pct = 100.0 * static_cast<double>(cpu_ns - e.last_cpu_ns) / wall_ns;
      e.last_cpu_ns = cpu_ns;
      e.have_last = true;

      int cpu_usage = 0, run_state = 0;
      if (ReadThreadExtended(e.port, &cpu_usage, &run_state))
      {
        snap.kern_est_pct = cpu_usage;
        snap.run_state = run_state;
      }
      snap.valid = true;
    }
    s_window.threads[i] = snap;
    s_window.thread_count = i + 1;
  }
#endif
}

std::string FormatReport()
{
  if (!s_enabled.load(std::memory_order_relaxed))
    return "=== STALL REPORT ===\nstall metrics off\n";

  Window w;
  {
    SpinGuard guard;
    w = s_window;
  }
  if (!w.valid || w.window_wall_ns == 0)
    return "=== STALL REPORT ===\nstall metrics off (no window yet)\n";

  const double wall_ms = w.window_wall_ns / 1.0e6;
  const double wall_ns_d = static_cast<double>(w.window_wall_ns);

  // Per-site label table, indexed by Site. Fixed width so captures diff row-for-row.
  static constexpr const char* kSiteName[kNumSites] = {
      "gpu.flush.wait", "gpu.sync.wait", "gpu.det.wait",
      "video.blocking", "bbox.flush",    "thread.sleep",
  };
  // Sites that count toward the CPU-thread blocked headline (the dual-core CPU-thread waits +
  // the single-core bbox inline wait). ThreadSleep (peripheral IO) and throttle (intentional
  // idle, reported on its own line) are excluded.
  static constexpr bool kCpuBlocking[kNumSites] = {
      true,   // GpuFlushWait
      true,   // GpuSyncWait
      true,   // GpuDetWait
      true,   // BlockingEvent
      true,   // BBoxFlushWait
      false,  // ThreadSleep
  };

  const char* bound_str = "unknown";
  switch (w.bound)
  {
  case PerformanceMetrics::Bound::CpuBound:
    bound_str = "cpu";
    break;
  case PerformanceMetrics::Bound::GpuBound:
    bound_str = "gpu";
    break;
  default:
    bound_str = "unknown";
    break;
  }

  std::string out;
  out.reserve(1024);
  char line[160];

  out += "=== STALL REPORT ===\n";
  std::snprintf(line, sizeof(line), "window_ms=%.1f speed=%.0f%% max_speed=%.0f%% bound=%s mode=%s\n",
                wall_ms, 100.0 * w.speed, 100.0 * w.max_speed, bound_str,
                w.dual_core ? "dual-core" : "single-core");
  out += line;

#ifdef __APPLE__
  // Per-thread utilization rows.
  for (int i = 0; i < w.thread_count; ++i)
  {
    const auto& t = w.threads[i];
    if (!t.valid)
      continue;
    std::snprintf(line, sizeof(line), "thread %-16s util=%5.1f%% kern_est=%3d%% run_state=%d\n",
                  t.role ? t.role : "?", t.util_pct, t.kern_est_pct, t.run_state);
    out += line;
  }
#endif

  // Per-site rows — EVERY site always printed (zeros included) for row-for-row diffs.
  double cpu_blocked_ns = 0.0;
  for (std::size_t i = 0; i < kNumSites; ++i)
  {
    const auto& s = w.sites[i];
    const double total_ms = s.total_ns / 1.0e6;
    const double max_us = s.max_ns / 1.0e3;
    const double pct = 100.0 * static_cast<double>(s.total_ns) / wall_ns_d;
    const char* annot = "";
    // GPU-thread waits only exist in dual-core; annotate so a single-core capture's zeros aren't
    // mistaken for "fixed".
    if (i == static_cast<std::size_t>(Site::GpuFlushWait) ||
        i == static_cast<std::size_t>(Site::GpuSyncWait) ||
        i == static_cast<std::size_t>(Site::GpuDetWait) ||
        i == static_cast<std::size_t>(Site::BlockingEvent))
    {
      annot = " (dual-core only)";
    }
    std::snprintf(line, sizeof(line), "%-15s n=%-6llu total_ms=%8.2f max_us=%9.1f %5.1f%%%s\n",
                  kSiteName[i], static_cast<unsigned long long>(s.count), total_ms, max_us, pct,
                  annot);
    out += line;
    if (kCpuBlocking[i])
      cpu_blocked_ns += static_cast<double>(s.total_ns);
  }

  const double throttle_pct = 100.0 * static_cast<double>(w.throttle_sleep_ns) / wall_ns_d;
  std::snprintf(line, sizeof(line), "throttle.sleep  total_ms=%8.2f %5.1f%% (intentional idle)\n",
                w.throttle_sleep_ns / 1.0e6, throttle_pct);
  out += line;

  const double cpu_blocked_pct = 100.0 * cpu_blocked_ns / wall_ns_d;
  std::snprintf(line, sizeof(line), "cpu_thread_blocked_total=%.1f%%\n", cpu_blocked_pct);
  out += line;

  std::snprintf(line, sizeof(line), "audio_underrun_delta=%llu\n",
                static_cast<unsigned long long>(w.audio_underrun_delta));
  out += line;

  return out;
}
}  // namespace StallMetrics
