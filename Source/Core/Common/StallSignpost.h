// Copyright 2026 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

// iCube stall-instrumentation signposts. This is the SIGNPOST half of the stall-metrics work
// (the accumulating counters live in VideoCommon/StallMetrics). It is split into Common so the
// peripheral/IO sleep sites in Common/Thread.cpp can emit signposts WITHOUT Common taking a
// dependency on VideoCommon (which would be a layering violation): a signpost is just an Apple
// os_log call, so it is safe at every layer. Header-only and a hard no-op off Apple, so it adds
// nothing to non-Apple builds and needs no CMake entry.
//
// Why os_signpost and not our own tracing: it shows up natively in Instruments' "Points of
// Interest" / custom-interval lanes lined up against the System Trace, so a capture can correlate
// a CPU-thread wait interval against what every core is doing at that instant — exactly the
// "where is the wasted time" question this instrumentation exists to answer.

#include <cstdint>

#ifdef __APPLE__
// os/signpost.h is a C API; including it from C++ is supported and intended.
#include <os/log.h>
#include <os/signpost.h>

namespace Common::StallSignpost
{
// One process-wide log handle per category. Lazily constructed on first use and leaked
// intentionally (process-lifetime), matching how os_log handles are normally held.
inline os_log_t WaitLog()
{
  static os_log_t log = os_log_create("com.icube.dol.stall", "wait");
  return log;
}

inline os_log_t PoiLog()
{
  static os_log_t log = os_log_create("com.icube.dol.stall", "PointsOfInterest");
  return log;
}

// RAII interval guard. `name` MUST be a static string literal: os_signpost format strings have to
// be literals, so the literal is passed straight through as the "%s" argument and as the signpost
// name. The os_signpost_enabled() fast-path means that with no Instruments capture attached this
// is a single predicted-not-taken branch plus a couple of cheap loads.
class IntervalGuard
{
public:
  explicit IntervalGuard(const char* name) : m_name(name)
  {
    m_log = WaitLog();
    m_enabled = os_signpost_enabled(m_log);
    if (!m_enabled)
      return;
    m_id = os_signpost_id_generate(m_log);
    os_signpost_interval_begin(m_log, m_id, "stall", "%s", m_name);
  }

  ~IntervalGuard()
  {
    if (!m_enabled)
      return;
    os_signpost_interval_end(m_log, m_id, "stall", "%s", m_name);
  }

  IntervalGuard(const IntervalGuard&) = delete;
  IntervalGuard& operator=(const IntervalGuard&) = delete;
  IntervalGuard(IntervalGuard&&) = delete;
  IntervalGuard& operator=(IntervalGuard&&) = delete;

private:
  const char* m_name;
  os_log_t m_log;
  os_signpost_id_t m_id;
  bool m_enabled;
};

// Instantaneous event on the Points-of-Interest category, carrying a single numeric payload.
// Uses OS_SIGNPOST_ID_EXCLUSIVE since these are fire-and-forget points with no matching end.
inline void Point(const char* name, uint64_t value)
{
  os_log_t log = PoiLog();
  if (!os_signpost_enabled(log))
    return;
  os_signpost_event_emit(log, OS_SIGNPOST_ID_EXCLUSIVE, "point", "%s %llu", name,
                         static_cast<unsigned long long>(value));
}
}  // namespace Common::StallSignpost

// Two-level paste so __LINE__ expands to its value before concatenation (unique guard var name).
#define ICUBE_STALL_SP_CAT2(a, b) a##b
#define ICUBE_STALL_SP_CAT(a, b) ICUBE_STALL_SP_CAT2(a, b)
// Place around just the wait call, in its own scope:  { ICUBE_STALL_INTERVAL("gpu.flush.wait"); ... }
#define ICUBE_STALL_INTERVAL(name)                                                                 \
  ::Common::StallSignpost::IntervalGuard ICUBE_STALL_SP_CAT(_icube_stall_sp_, __LINE__)(name)
#define ICUBE_STALL_POINT(name, v) ::Common::StallSignpost::Point((name), (v))

#else  // !__APPLE__ — hard no-ops, byte-neutral on non-Apple builds.

#define ICUBE_STALL_INTERVAL(name)                                                                 \
  do                                                                                               \
  {                                                                                                \
  } while (0)
#define ICUBE_STALL_POINT(name, v)                                                                 \
  do                                                                                               \
  {                                                                                                \
  } while (0)

#endif  // __APPLE__
