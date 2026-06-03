// Copyright 2025
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <cstdint>
#include <optional>

#include "Common/HookableEvent.h"
#include "Core/Core.h"
#include "Core/Config/GraphicsSettings.h"
#include "VideoCommon/VideoEvents.h"

namespace VideoCommon
{
// Auto-resolution controller v2 (iCube).
//
// Redesign goals (see research/2026-06-03-jitless-miracle-synthesis.md §#1):
//   - Target VPS (emulated v-blanks/sec) at the TITLE'S NATIVE refresh rate, not a hard-coded 60.
//     The old controller used FPS — which counts duplicate presents — and a fixed 60 target, so a
//     30fps-native title was ratcheted to the minimum scale even though it was running perfectly.
//   - Act ONLY when the title is GPU-bound. iCube's whole space is CPU-bound (jitless), where the
//     resolution lever is inert; pulling it there is the "switches res, does nothing" bug. When
//     CPU-bound we publish that to PerformanceMetrics::SetBound() and hand off to the clock loop.
//   - This controller OWNS the EFB-scale probe: lowering one step and watching VPS is the
//     authoritative CPU-vs-GPU-bound discriminator (the maxSpeed/speed gap collapses to ~0 in the
//     underspeed regime, so it cannot classify there). Only this controller mutates EFB scale, so
//     the clock loop never thrashes the resolution lever.
//   - Allow multi-step scale jumps when far from target instead of one-step-per-cooldown crawling.
class AutoIRController
{
public:
  static AutoIRController& Get();

  void Enable();
  void Disable();
  bool IsEnabled() const { return m_enabled; }

  // Called on config changes to refresh parameters
  void RefreshSettings();

private:
  AutoIRController() = default;
  ~AutoIRController() = default;

  void OnAfterPresent(PresentInfo& info);
  void Step();

  // Returns the title's native refresh rate (e.g. ~59.94 or ~50), clamped to a sane range.
  double GetTargetVPS() const;

  bool m_enabled = false;

  // Settings (re-read from config)
  int m_min_scale = 1;
  int m_max_scale = 4;
  int m_cooldown_frames = 60;
  int m_hysteresis_pct = 12;  // percentage band around target VPS before adjusting

  // State machine for the probe-based bound classification.
  enum class Phase
  {
    Settled,     // holding a scale; watching VPS for drift
    ProbingDown  // dropped scale one step on purpose; measuring whether VPS recovered (GPU-bound)
  };
  Phase m_phase = Phase::Settled;
  int m_frames_since_change = 0;
  int m_probe_prev_scale = 0;     // scale before the probe, to restore if it didn't help
  double m_probe_vps_before = 0;  // VPS captured just before the probe step

  // Hook registration (AfterPresent)
  Common::EventHook m_after_present_hook;
};
}  // namespace VideoCommon
