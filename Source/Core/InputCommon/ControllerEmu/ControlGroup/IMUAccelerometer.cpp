// Copyright 2019 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "InputCommon/ControllerEmu/ControlGroup/IMUAccelerometer.h"

#include <algorithm>

#include "Common/Common.h"
#include "Core/HW/WiimoteEmu/WiimoteEmu.h"
#include "InputCommon/ControllerEmu/Control/Control.h"

namespace ControllerEmu
{
IMUAccelerometer::IMUAccelerometer(std::string name_, std::string ui_name_)
    : ControlGroup(std::move(name_), std::move(ui_name_), GroupType::IMUAccelerometer)
{
  AddInput(Translatability::Translate, _trans("Up"));
  AddInput(Translatability::Translate, _trans("Down"));
  AddInput(Translatability::Translate, _trans("Left"));
  AddInput(Translatability::Translate, _trans("Right"));
  AddInput(Translatability::Translate, _trans("Forward"));
  AddInput(Translatability::Translate, _trans("Backward"));

  AddSetting(&m_flip_left_right_setting,
             {_trans("Flip Left and Right"), nullptr,
              _trans("Reverses the accelerometer's sideways axis: for a controller that reads a "
                     "tilt to the left as a tilt to the right.")},
             false);
  AddSetting(&m_flip_forward_back_setting,
             {_trans("Flip Forward and Back"), nullptr,
              _trans("Reverses the accelerometer's lengthwise axis: for a controller that reads "
                     "pointing up as pointing down.")},
             false);
  AddSetting(&m_flip_up_down_setting,
             {_trans("Flip Up and Down"), nullptr,
              _trans("Reverses the accelerometer's vertical axis: for a controller the game "
                     "treats as upside down.")},
             false);
}

bool IMUAccelerometer::AreInputsBound() const
{
  return std::ranges::any_of(
      controls, [](const auto& control) { return control->control_ref->BoundCount() > 0; });
}

std::optional<IMUAccelerometer::StateData> IMUAccelerometer::GetState() const
{
  if (!AreInputsBound())
    return std::nullopt;

  StateData state;
  state.x = (controls[2]->GetState() - controls[3]->GetState());
  state.y = (controls[5]->GetState() - controls[4]->GetState());
  state.z = (controls[0]->GetState() - controls[1]->GetState());
  if (m_flip_left_right_setting.GetValue())
    state.x = -state.x;
  if (m_flip_forward_back_setting.GetValue())
    state.y = -state.y;
  if (m_flip_up_down_setting.GetValue())
    state.z = -state.z;
  return state;
}

}  // namespace ControllerEmu
