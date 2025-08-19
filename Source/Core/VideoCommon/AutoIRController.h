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
  void AdjustScaleIfNeeded(double fps);

  bool m_enabled = false;

  // Settings
  int m_target_fps = 60;
  int m_min_scale = 1;
  int m_max_scale = 4;
  int m_cooldown_frames = 60;
  int m_hysteresis_pct = 12; // percentage around target before adjusting

  // State
  int m_frames_since_change = 0;
  // We use a moving estimate; if present time accuracy is unknown, caller provides FPS=0 and we will skip

  // Hook registrations
  Common::EventHook m_after_present_hook;
};
}  // namespace VideoCommon
