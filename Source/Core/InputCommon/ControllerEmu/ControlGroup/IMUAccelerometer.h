// Copyright 2019 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <optional>
#include <string>

#include "Common/Matrix.h"
#include "InputCommon/ControllerEmu/ControlGroup/ControlGroup.h"
#include "InputCommon/ControllerEmu/Setting/NumericSetting.h"

namespace ControllerEmu
{
class IMUAccelerometer : public ControlGroup
{
public:
  using StateData = Common::Vec3;

  IMUAccelerometer(std::string name, std::string ui_name);

  std::optional<StateData> GetState() const;

  bool AreInputsBound() const;

private:
  // iCube: a per-axis escape hatch for a pad whose sensor reads an axis the other way round.
  SettingValue<bool> m_flip_left_right_setting;
  SettingValue<bool> m_flip_forward_back_setting;
  SettingValue<bool> m_flip_up_down_setting;
};
}  // namespace ControllerEmu
