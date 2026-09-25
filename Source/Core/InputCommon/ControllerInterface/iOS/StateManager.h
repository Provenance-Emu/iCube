// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <map>
#include <mutex>
#include <vector>

#include "InputCommon/ControllerInterface/iOS/ButtonType.h"

namespace ciface::iOS
{
// Defect #12: setters (SetButtonPressed/SetAxisValue/ClearController) are called from the
// main thread (touch overlay, DSU input), while getters (GetButtonPressed/GetAxisValue) are
// polled from the CPU/input-sampling thread. m_controllers is a std::vector<std::map<...>>
// with no synchronization of its own, so a concurrent read/write pair is undefined behavior
// (torn reads of a std::map, or a read racing a rehash/insert). m_mutex now serializes every
// accessor, not just ClearController; contention is not a concern here (input rate is low
// relative to lock/unlock cost).
class StateManager
{
private:
  class ControllerState
  {
  public:
    std::map<ButtonType, bool> m_buttons;
    std::map<ButtonType, float> m_axes;

    void PopulateButton(ButtonType button);
    void PopulateAxis(ButtonType axis);
  };

  StateManager();

  static StateManager s_instance;

  std::vector<ControllerState> m_controllers;
  mutable std::mutex m_mutex;
public:
  static StateManager* GetInstance() { return &s_instance; }

  void Init();
  void DeInit();

  bool GetButtonPressed(int controller_id, ButtonType button) const;
  void SetButtonPressed(int controller_id, ButtonType button, bool pressed);
  float GetAxisValue(int controller_id, ButtonType axis) const;
  void SetAxisValue(int controller_id, ButtonType axis, float value);

  // Resets every known button (false) and axis (0.0f) for one touchscreen controller id.
  // Used when a touch overlay is torn down or rebuilt so a finger that was mid-press when
  // its view disappeared cannot leave the emulated pad stuck (audit defect #7).
  void ClearController(int controller_id);
};
}  // namespace ciface::iOS
