// Copyright 2025
// SPDX-License-Identifier: GPL-2.0-or-later

#include "VideoCommon/AutoIRController.h"

#include <algorithm>

#include "Common/Logging/Log.h"
#include "Common/Config/Config.h"
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
}

void AutoIRController::Disable()
{
  if (!m_enabled)
    return;
  m_enabled = false;
}

void AutoIRController::RefreshSettings()
{
  m_target_fps = Config::Get(Config::GFX_AUTO_IR_TARGET_FPS);
  m_min_scale = Config::Get(Config::GFX_AUTO_IR_MIN_SCALE);
  m_max_scale = Config::Get(Config::GFX_AUTO_IR_MAX_SCALE);
  m_cooldown_frames = Config::Get(Config::GFX_AUTO_IR_COOLDOWN_FRAMES);
  m_hysteresis_pct = Config::Get(Config::GFX_AUTO_IR_HYSTERESIS_PERCENT);
  // clamp sanity
  m_min_scale = std::max(1, m_min_scale);
  m_max_scale = std::max(m_min_scale, m_max_scale);
  m_target_fps = std::max(24, m_target_fps);
  m_cooldown_frames = std::max(1, m_cooldown_frames);
  m_hysteresis_pct = std::clamp(m_hysteresis_pct, 0, 50);
}

void AutoIRController::OnAfterPresent(PresentInfo& info)
{
  (void)info;
  // Ensure singleton constructed and settings loaded
  // If disabled, do nothing
  if (!m_enabled)
    return;

  // Prefer emulation speed as it reflects CPU bottlenecks under vsync
  const double speed = g_perf_metrics.GetSpeed(); // 1.0 == full speed
  const double fps = g_perf_metrics.GetFPS();
  double effective = 0.0;
  if (speed > 0.0)
  {
    effective = static_cast<double>(m_target_fps) * speed;
  }
  else if (fps > 0.0)
  {
    effective = fps;
  }
  else
  {
    return; // no signal yet
  }

  AdjustScaleIfNeeded(effective);
}

void AutoIRController::AdjustScaleIfNeeded(double effective_fps)
{
  // Cooldown handling
  if (m_frames_since_change < m_cooldown_frames)
  {
    ++m_frames_since_change;
    return;
  }

  const int current_scale = g_ActiveConfig.iEFBScale;
  const double low_thresh = static_cast<double>(m_target_fps) * (1.0 - (m_hysteresis_pct / 100.0));
  const double high_thresh = static_cast<double>(m_target_fps) * (1.0 + (m_hysteresis_pct / 100.0));

  int new_scale = current_scale;

  if (effective_fps < low_thresh && current_scale > m_min_scale)
  {
    // If we are far below target, step by 2 for faster convergence
    const bool far_below = effective_fps < (low_thresh * 0.85);
    new_scale = std::max(m_min_scale, current_scale - (far_below ? 2 : 1));
  }
  else if (effective_fps > high_thresh && current_scale < m_max_scale)
  {
    const bool far_above = effective_fps > (high_thresh * 1.10);
    new_scale = std::min(m_max_scale, current_scale + (far_above ? 2 : 1));
  }

  if (new_scale != current_scale)
  {
    // Apply change via Config system so all subsystems react properly
    Config::Set(Config::LayerType::CurrentRun, Config::GFX_EFB_SCALE, new_scale);
    INFO_LOG_FMT(VIDEO, "AutoIR: eff_fps={:.1f} target={} hyst={}%% scale {} -> {}",
                 effective_fps, m_target_fps, m_hysteresis_pct, current_scale, new_scale);
    if (Config::Get(Config::GFX_AUTO_IR_SHOW_OSD))
    {
      OSD::AddMessage(
          fmt::format("Auto IR: Internal Resolution {}→{} (eff {:.1f})", current_scale,
                      new_scale, effective_fps),
          OSD::Duration::NORMAL);
    }
    m_frames_since_change = 0;
  }
  else
  {
    // Not changed; keep waiting
    ++m_frames_since_change;
  }
}

// Force-link the singleton early by referencing from a TU
static struct AutoIRBootstrap
{
  AutoIRBootstrap() { (void)AutoIRController::Get(); }
} s_auto_ir_bootstrap;

}  // namespace VideoCommon
