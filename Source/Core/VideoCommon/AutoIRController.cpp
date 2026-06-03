// Copyright 2025
// SPDX-License-Identifier: GPL-2.0-or-later

#include "VideoCommon/AutoIRController.h"

#include <algorithm>
#include <cmath>

#include "Common/Logging/Log.h"
#include "Common/Config/Config.h"
#include "Core/HW/VideoInterface.h"
#include "Core/System.h"
#include "VideoCommon/PerformanceMetrics.h"
#include "VideoCommon/VideoConfig.h"
#include "VideoCommon/FramebufferManager.h"
#include "VideoCommon/OnScreenDisplay.h"
#include <fmt/format.h>

namespace VideoCommon
{

static void EnsureEnabledFromConfig(AutoIRController& c)
{
  const bool want_enabled = Config::Get(Config::GFX_AUTO_IR_ENABLE);
  if (want_enabled)
    c.Enable();
  else
    c.Disable();
}

AutoIRController& AutoIRController::Get()
{
  static AutoIRController s_instance;
  static bool s_inited = false;
  if (!s_inited)
  {
    s_inited = true;

    // Initial settings snapshot
    s_instance.RefreshSettings();

    // Hook AfterPresent to run per presented frame
    s_instance.m_after_present_hook = AfterPresentEvent::Register(
        [](PresentInfo& info) {
          AutoIRController::Get().OnAfterPresent(info);
        },
        "AutoIRController");

    // Sync enabled state from config at startup
    EnsureEnabledFromConfig(s_instance);

    // Also refresh settings when any config changes
    static Common::EventHook s_cfg_changed = ConfigChangedEvent::Register(
        [](u32) {
          auto& inst = AutoIRController::Get();
          inst.RefreshSettings();
          EnsureEnabledFromConfig(inst);
        },
        "AutoIRController_ConfigChanged");
  }
  return s_instance;
}

void AutoIRController::Enable()
{
  if (m_enabled)
    return;
  m_enabled = true;
  m_frames_since_change = 0;
  m_phase = Phase::Settled;
}

void AutoIRController::Disable()
{
  if (!m_enabled)
    return;
  m_enabled = false;
}

void AutoIRController::RefreshSettings()
{
  // NOTE: GFX_AUTO_IR_TARGET_FPS is intentionally no longer used as the setpoint. v2 targets the
  // title's NATIVE refresh rate (GetTargetVPS) so 30/50/60Hz titles are each held at their own
  // cadence instead of all being driven toward a fixed 60. The config key still exists (the
  // settings bridge reads it) but does not drive the controller.
  m_min_scale = Config::Get(Config::GFX_AUTO_IR_MIN_SCALE);
  m_max_scale = Config::Get(Config::GFX_AUTO_IR_MAX_SCALE);
  m_cooldown_frames = Config::Get(Config::GFX_AUTO_IR_COOLDOWN_FRAMES);
  m_hysteresis_pct = Config::Get(Config::GFX_AUTO_IR_HYSTERESIS_PERCENT);
  // clamp sanity
  m_min_scale = std::max(1, m_min_scale);
  m_max_scale = std::max(m_min_scale, m_max_scale);
  m_cooldown_frames = std::max(1, m_cooldown_frames);
  m_hysteresis_pct = std::clamp(m_hysteresis_pct, 0, 50);
}

double AutoIRController::GetTargetVPS() const
{
  // The emulated console's intended field rate. ~59.94 (NTSC), ~50 (PAL), ~60 (progressive), or
  // lower for titles that natively run their game logic at 30. We target *this*, not a fixed 60.
  double rr = Core::System::GetInstance().GetVideoInterface().GetTargetRefreshRate();
  if (!(rr > 1.0) || !std::isfinite(rr))
    rr = 60.0;  // not warmed up / unknown — fall back to 60
  return std::clamp(rr, 20.0, 240.0);
}

void AutoIRController::OnAfterPresent(PresentInfo& info)
{
  (void)info;
  // Live-read the enable flag every frame (see v1 note): toggling Auto-IR off mid-game must take
  // effect immediately regardless of the ConfigChangedEvent plumbing.
  const bool enabled = Config::Get(Config::GFX_AUTO_IR_ENABLE);
  if (!enabled)
  {
    m_enabled = false;
    return;
  }
  if (!m_enabled)
  {
    m_enabled = true;
    m_frames_since_change = 0;
    m_phase = Phase::Settled;
  }

  Step();
}

void AutoIRController::Step()
{
  // Cooldown between actions so each change has time to settle into the smoothed VPS before we
  // grade it. The probe phase uses the same window to measure the VPS response.
  if (m_frames_since_change < m_cooldown_frames)
  {
    ++m_frames_since_change;
    return;
  }

  const double vps = g_perf_metrics.GetVPS();
  if (vps <= 0.0)
    return;  // metrics not warmed up

  const double target = GetTargetVPS();
  const double low_thresh = target * (1.0 - (m_hysteresis_pct / 100.0));
  const double high_thresh = target * (1.0 + (m_hysteresis_pct / 100.0));
  const int current_scale = g_ActiveConfig.iEFBScale;

  // --- Probe resolution: grade the deliberate one-step downscale we did last window. ---
  if (m_phase == Phase::ProbingDown)
  {
    m_phase = Phase::Settled;
    // Did dropping internal resolution materially lift VPS? If so the title is GPU-bound and the
    // resolution lever works here — keep the lower scale and own the bound classification. If VPS
    // didn't move, lowering resolution is inert => CPU-bound. Restore the scale (don't pay the
    // visual cost for nothing) and hand off to the clock loop.
    const double improvement = vps - m_probe_vps_before;
    const double need = std::max(0.5, target * 0.02);  // ~2% of target, min 0.5 VPS, to clear noise
    if (improvement >= need)
    {
      PerformanceMetrics::SetBound(PerformanceMetrics::Bound::GpuBound);
      INFO_LOG_FMT(VIDEO, "AutoIR: GPU-bound (probe +{:.1f} VPS); held scale {}", improvement,
                   current_scale);
      // Stay at the lowered scale; fall through to normal regulation below.
    }
    else
    {
      PerformanceMetrics::SetBound(PerformanceMetrics::Bound::CpuBound);
      if (current_scale != m_probe_prev_scale &&
          m_probe_prev_scale >= m_min_scale && m_probe_prev_scale <= m_max_scale)
      {
        Config::Set(Config::LayerType::CurrentRun, Config::GFX_EFB_SCALE, m_probe_prev_scale);
      }
      INFO_LOG_FMT(VIDEO, "AutoIR: CPU-bound (probe {:+.1f} VPS); restored scale {} -> clock loop",
                   improvement, m_probe_prev_scale);
      m_frames_since_change = 0;
      return;  // CPU-bound: the clock loop owns it from here.
    }
  }

  // --- Settled regulation ---

  // Underspeed: VPS below the target band.
  if (vps < low_thresh)
  {
    if (current_scale > m_min_scale)
    {
      // If we haven't classified the bottleneck (or it's marked GPU-bound), step down to regulate.
      // But before crawling, if we're unsure, run a single-step PROBE to confirm the lever works.
      const auto bound = PerformanceMetrics::GetBound();
      if (bound == PerformanceMetrics::Bound::Unknown)
      {
        // Start a probe: drop one step and measure next window.
        m_probe_prev_scale = current_scale;
        m_probe_vps_before = vps;
        Config::Set(Config::LayerType::CurrentRun, Config::GFX_EFB_SCALE, current_scale - 1);
        m_phase = Phase::ProbingDown;
        m_frames_since_change = 0;
        return;
      }
      if (bound == PerformanceMetrics::Bound::CpuBound)
      {
        // CPU-bound: resolution is inert. Don't touch it; the clock loop handles speed. Re-arm a
        // probe occasionally in case the scene shifts to a GPU-bound one.
        PerformanceMetrics::SetBound(PerformanceMetrics::Bound::Unknown);
        m_frames_since_change = 0;
        return;
      }

      // GPU-bound: lower resolution, multi-step when far below target.
      const double deficit_ratio = (low_thresh - vps) / std::max(1.0, target);  // 0..1
      const int steps = std::clamp(static_cast<int>(std::lround(deficit_ratio * 3.0)), 1, 3);
      const int new_scale = std::max(m_min_scale, current_scale - steps);
      if (new_scale != current_scale)
      {
        Config::Set(Config::LayerType::CurrentRun, Config::GFX_EFB_SCALE, new_scale);
        INFO_LOG_FMT(VIDEO, "AutoIR: vps={:.1f} target={:.1f} (GPU-bound) scale {} -> {}", vps,
                     target, current_scale, new_scale);
        if (Config::Get(Config::GFX_AUTO_IR_SHOW_OSD))
        {
          OSD::AddMessage(fmt::format("Auto IR: Internal Resolution {}→{} (VPS {:.1f})",
                                      current_scale, new_scale, vps),
                          OSD::Duration::NORMAL);
        }
        m_frames_since_change = 0;
        return;
      }
    }
    else
    {
      // Already at the floor and still underspeed: this is the clock loop's job now.
      PerformanceMetrics::SetBound(PerformanceMetrics::Bound::CpuBound);
    }
    ++m_frames_since_change;
    return;
  }

  // Comfortably above target with visual headroom: raise resolution, multi-step when far above.
  if (vps > high_thresh && current_scale < m_max_scale)
  {
    const double surplus_ratio = (vps - high_thresh) / std::max(1.0, target);
    const int steps = std::clamp(static_cast<int>(std::lround(surplus_ratio * 3.0)), 1, 2);
    const int new_scale = std::min(m_max_scale, current_scale + steps);
    if (new_scale != current_scale)
    {
      Config::Set(Config::LayerType::CurrentRun, Config::GFX_EFB_SCALE, new_scale);
      INFO_LOG_FMT(VIDEO, "AutoIR: vps={:.1f} target={:.1f} headroom; scale {} -> {}", vps, target,
                   current_scale, new_scale);
      if (Config::Get(Config::GFX_AUTO_IR_SHOW_OSD))
      {
        OSD::AddMessage(fmt::format("Auto IR: Internal Resolution {}→{} (VPS {:.1f})",
                                    current_scale, new_scale, vps),
                        OSD::Duration::NORMAL);
      }
      m_frames_since_change = 0;
      return;
    }
  }

  // Holding target within the band: stable. Don't claim a bound here (leave it for the probe/clock
  // loop to decide); just keep waiting.
  ++m_frames_since_change;
}

// Force-link the singleton early by referencing from a TU
static struct AutoIRBootstrap
{
  AutoIRBootstrap() { (void)AutoIRController::Get(); }
} s_auto_ir_bootstrap;

}  // namespace VideoCommon
