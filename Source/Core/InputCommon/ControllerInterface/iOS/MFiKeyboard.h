// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#if TARGET_OS_MACCATALYST
#import <GameController/GCController.h>
#import <GameController/GCExtendedGamepad.h>
#import <GameController/GCMicroGamepad.h>
#import <GameController/GCKeyboard.h>
#import <GameController/GCDeviceHaptics.h>
#import <GameController/GCDualShockGamepad.h>
#import <GameController/GCDualSenseGamepad.h>
#import <GameController/GCXboxGamepad.h>
#else
#import <GameController/GameController.h>
#endif

#include "InputCommon/ControllerInterface/CoreDevice.h"

namespace ciface::iOS
{
class MFiKeyboard : public Core::Device
{
private:
  class Key : public Core::Device::Input
  {
  public:
    Key(GCControllerButtonInput* input, const std::string name)
        : m_input(input), m_name(name) {}
    std::string GetName() const override;
    ControlState GetState() const override;

  private:
    GCControllerButtonInput* m_input;
    const std::string m_name;
  };

public:
  MFiKeyboard(GCKeyboard* keyboard);

  std::string GetName() const final override;
  std::string GetSource() const final override;

private:
  GCKeyboard* m_keyboard;
};
}  // namespace ciface::iOS
