// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <GameController/GameController.h>

#include "InputCommon/ControllerInterface/CoreDevice.h"

namespace ciface::iOS
{
enum MotionPlane
{
  X,
  Y,
  Z
};

class MFiController : public Core::Device
{
private:
  class Button : public Core::Device::Input
  {
  public:
    Button(GCControllerButtonInput* input, const std::string name)
        : m_input(input), m_name(name) {}
    std::string GetName() const override;
    ControlState GetState() const override;

  private:
    GCControllerButtonInput* m_input;
    const std::string m_name;
  };

  class PressureSensitiveButton : public Core::Device::Input
  {
  public:
    PressureSensitiveButton(GCControllerButtonInput* input, const std::string name)
        : m_input(input), m_name(name)
    {
    }
    std::string GetName() const override;
    ControlState GetState() const override;

  private:
    GCControllerButtonInput* m_input;
    const std::string m_name;
  };

  class Axis : public Core::Device::Input
  {
  public:
    Axis(GCControllerAxisInput* input, const float multiplier, const std::string name)
        : m_input(input), m_multiplier(multiplier), m_name(name)
    {
    }
    std::string GetName() const override;
    ControlState GetState() const override;

  private:
    GCControllerAxisInput* m_input;
    float m_multiplier;
    const std::string m_name;
  };

  class AccelerometerAxis : public Core::Device::Input
  {
  public:
    AccelerometerAxis(GCMotion* motion, MotionPlane plane, const double multiplier,
                      const std::string name);
    std::string GetName() const override;
    ControlState GetState() const override;

  private:
    GCMotion* m_motion;
    MotionPlane m_plane;
    double m_multiplier;
    const std::string m_name;
  };

  class GyroscopeAxis : public Core::Device::Input
  {
  public:
    GyroscopeAxis(GCMotion* motion, MotionPlane plane, const double multiplier,
                  const std::string name);
    std::string GetName() const override;
    ControlState GetState() const override;

  private:
    GCMotion* m_motion;
    MotionPlane m_plane;
    double m_multiplier;
    const std::string m_name;
  };

public:
  MFiController(GCController* controller);

  std::string GetName() const final override;
  std::string GetSource() const final override;
  bool SupportsAccelerometer() const;
  bool SupportsGyroscope() const;
  bool IsSameController(GCController* controller) const;
  std::optional<int> GetPreferredId() const final override;

  // Id-stability bookkeeping. See the comment above s_assigned_ids in MFiController.mm for the
  // full explanation; in short, GetPreferredId() hands out a per-vendor-name ordinal (0, 1, 2...)
  // that is remembered by GCController identity for as long as this process runs, so:
  //  - two simultaneously-connected identical pads never trade ids just because a later device
  //    refresh happens to enumerate [GCController controllers] in a different order, and
  //  - a single pad that disconnects and reconnects gets its old ordinal back (nothing else is
  //    holding it), even though iOS hands out a brand-new GCController object on reconnect.
  // It is NOT stable across an app relaunch -- iOS gives third-party apps no persistent hardware
  // identity for MFi controllers to remember across process launches.
  //
  // ReleaseId() must be called exactly when a GCController is known to have disconnected (see
  // MFiControllerScanner.mm's controllerDisconnected:) so its ordinal becomes free again.
  // PruneStaleIds() is a safety net called once per full device population pass (see iOS.mm's
  // PopulateDevices) that reclaims ordinals for any GCController missing from the live list, in
  // case a disconnect notification was ever missed.
  static void ReleaseId(GCController* controller);
  static void PruneStaleIds(NSArray<GCController*>* live_controllers);

private:
  GCController* m_controller;
  bool m_supports_accelerometer;
  bool m_supports_gyroscope;
};
}  // namespace ciface::iOS
