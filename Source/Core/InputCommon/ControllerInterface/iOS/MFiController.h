// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <atomic>
#include <chrono>
#include <mutex>

#include <GameController/GameController.h>

#include "InputCommon/ControllerInterface/CoreDevice.h"
#include "InputCommon/ControllerInterface/iOS/ControllerInputGate.h"
#include "InputCommon/ControllerInterface/iOS/PhysicalProfileMapping.h"

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
    Button(GCControllerButtonInput* input, const std::string name, std::shared_ptr<ControllerInputGate> gate)
        : m_gate(std::move(gate)), m_input(input), m_name(name) {}
    std::string GetName() const override;
    ControlState GetState() const override;

  private:
    std::shared_ptr<ControllerInputGate> m_gate;
    GCControllerButtonInput* m_input;
    const std::string m_name;
  };

  class PressureSensitiveButton : public Core::Device::Input
  {
  public:
    PressureSensitiveButton(GCControllerButtonInput* input, const std::string name, std::shared_ptr<ControllerInputGate> gate)
        : m_gate(std::move(gate)), m_input(input), m_name(name)
    {
    }
    std::string GetName() const override;
    ControlState GetState() const override;

  private:
    std::shared_ptr<ControllerInputGate> m_gate;
    GCControllerButtonInput* m_input;
    const std::string m_name;
  };

  class Axis : public Core::Device::Input
  {
  public:
    Axis(GCControllerAxisInput* input, const float multiplier, const std::string name, std::shared_ptr<ControllerInputGate> gate)
        : m_gate(std::move(gate)), m_input(input), m_multiplier(multiplier), m_name(name)
    {
    }
    std::string GetName() const override;
    ControlState GetState() const override;

  private:
    std::shared_ptr<ControllerInputGate> m_gate;
    GCControllerAxisInput* m_input;
    float m_multiplier;
    const std::string m_name;
  };

  // A trigger the pad reports as an axis rather than a button (PhysicalProfile::
  // TriggerValueFromAxis): 0...1 whether the axis rests at 0 or at -1.
  class TriggerAxis : public Core::Device::Input
  {
  public:
    TriggerAxis(GCControllerAxisInput* input, const std::string name,
                std::shared_ptr<ControllerInputGate> gate)
        : m_gate(std::move(gate)), m_input(input), m_name(name)
    {
    }
    std::string GetName() const override;
    ControlState GetState() const override;

  private:
    std::shared_ptr<ControllerInputGate> m_gate;
    GCControllerAxisInput* m_input;
    const std::string m_name;
    // GetState runs on the input thread and, while a binding is being captured, on others.
    mutable std::atomic<bool> m_rests_at_minus_one{false};
  };

  // What the four DPadStickAxis inputs of one D-pad share: when each axis last changed direction.
  struct DPadStickState
  {
    std::mutex mutex;
    int x_sign = 0;
    int y_sign = 0;
    std::chrono::steady_clock::time_point x_since{};
    std::chrono::steady_clock::time_point y_since{};
  };

  // One half of one axis of a stick driven from a D-pad (PhysicalProfile::DPadStickPosition),
  // for a pad with a D-pad and no stick: "D-Pad Stick X+" and so on. A held direction starts as
  // a partial push and grows to a full one.
  class DPadStickAxis : public Core::Device::Input
  {
  public:
    DPadStickAxis(GCControllerDirectionPad* pad, bool is_x, const float multiplier,
                  const std::string name, std::shared_ptr<DPadStickState> state,
                  std::shared_ptr<ControllerInputGate> gate)
        : m_gate(std::move(gate)), m_state(std::move(state)), m_pad(pad), m_is_x(is_x),
          m_multiplier(multiplier), m_name(name)
    {
    }
    std::string GetName() const override;
    ControlState GetState() const override;

  private:
    std::shared_ptr<ControllerInputGate> m_gate;
    std::shared_ptr<DPadStickState> m_state;
    GCControllerDirectionPad* m_pad;
    bool m_is_x;
    float m_multiplier;
    const std::string m_name;
  };

  class AccelerometerAxis : public Core::Device::Input
  {
  public:
    AccelerometerAxis(GCMotion* motion, MotionPlane plane, const double multiplier,
                      const std::string name, std::shared_ptr<ControllerInputGate> gate);
    std::string GetName() const override;
    ControlState GetState() const override;

  private:
    std::shared_ptr<ControllerInputGate> m_gate;
    GCMotion* m_motion;
    MotionPlane m_plane;
    double m_multiplier;
    const std::string m_name;
  };

  class GyroscopeAxis : public Core::Device::Input
  {
  public:
    GyroscopeAxis(GCMotion* motion, MotionPlane plane, const double multiplier,
                  const std::string name, std::shared_ptr<ControllerInputGate> gate);
    std::string GetName() const override;
    ControlState GetState() const override;

  private:
    std::shared_ptr<ControllerInputGate> m_gate;
    GCMotion* m_motion;
    MotionPlane m_plane;
    double m_multiplier;
    const std::string m_name;
  };

public:
  MFiController(GCController* controller);

  Core::DeviceRemoval UpdateInput() override;
  // Shared by all wrappers and UI leases for this exact GCController identity.
  static std::shared_ptr<ControllerInputGate> GetInputGate(GCController* controller);
  static bool AreControlsNeutral(GCController* controller);
  // UI leases pass their stored gate: stale teardown must never remove a replacement entry.
  // A confirmed backend disconnect omits expected_gate to retire the current identity entry.
  static void DisconnectInputGate(
      GCController* controller, const std::shared_ptr<ControllerInputGate>& expected_gate = {});

  std::string GetName() const final override;
  // The device name of `controller`: its vendor name, or for a pad that reports none,
  // "Unknown Controller", except that a pad with no gamepad profile at all (bound through its
  // physical profile) is named by its kind, PhysicalProfile::FallbackName.
  static std::string NameFor(GCController* controller);
  // What the physical profile of `controller` binds (PhysicalProfile::ResolveForPad), with every
  // element reduced to one name first (PhysicalProfile::PreferredName). The app's wrapper reads
  // the same bindings through DOLPhysicalProfileBridge.
  static PhysicalProfile::Bindings PhysicalBindingsFor(GCController* controller);
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
  // Binds a pad with no extended / micro gamepad (a plain HID pad included), or a Switch Online
  // pad with no extended one, through its physical input profile (PhysicalProfileMapping.h).
  // Returns false, adding nothing, when the profile has nothing usable.
  bool AddPhysicalProfileInputs(GCController* controller);

  std::shared_ptr<ControllerInputGate> m_gate;
  GCController* m_controller;
  bool m_supports_accelerometer;
  bool m_supports_gyroscope;
};
}  // namespace ciface::iOS
