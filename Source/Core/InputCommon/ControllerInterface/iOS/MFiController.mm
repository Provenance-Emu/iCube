// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "InputCommon/ControllerInterface/iOS/MFiController.h"

#include <algorithm>
#include <mutex>
#include <string>
#include <vector>
#include <cmath>
#include <unordered_map>

#include "Common/Logging/Log.h"
#include "Common/MathUtil.h"
#include "InputCommon/ControllerInterface/iOS/Motor.h"
#include "InputCommon/ControllerInterface/iOS/PhysicalProfileMapping.h"
#include "InputCommon/ControllerInterface/ControllerInterface.h"

namespace ciface::iOS
{
namespace
{
// Defect #16 (docs/audits/2026-09-24-controller-system-audit.md): without this, AddDevice()
// (ControllerInterface.cpp) falls back to "first available id" purely from the order
// [GCController controllers] enumerates devices in, which the GameController framework does not
// document as stable. Two identical pads (same vendorName, so same GetSource()/GetName(), which
// is exactly what AddDevice scopes id uniqueness by) can therefore trade ids across an unrelated
// device refresh, silently moving every binding pointed at "MFi/<id>/<name>".
//
// This table remembers, for the lifetime of the process, which ordinal each *live* GCController
// object (identity, not content) holds within its vendor-name group. A refresh that tears down
// and rebuilds the C++ device wrappers (ControllerInterface::RefreshDevices ->
// ClearDevices()+PopulateDevices()) does NOT touch the underlying Objective-C GCController
// objects for pads that stayed connected, so looking them up by pointer identity here survives
// that churn regardless of enumeration order. A genuine disconnect hands the ordinal back (see
// ReleaseId/PruneStaleIds) so a reconnecting pad -- necessarily a new GCController object, since
// iOS gives us no persistent hardware id to recognize it by -- claims the lowest free ordinal,
// which in the common single-pad case is the one it just vacated.
struct AssignedId
{
  std::string vendor_name;
  const void* controller_ptr;
  int id;
};

std::mutex s_assigned_ids_mutex;
std::vector<AssignedId> s_assigned_ids;
struct GateEntry
{
  // Retain identity until disconnect/pruning; pointer reuse can never inherit another lease.
  GCController* controller;
  std::shared_ptr<ControllerInputGate> gate;
};
std::mutex s_gates_mutex;
std::unordered_map<const void*, GateEntry> s_gates;
}  // namespace

namespace
{
std::vector<std::string> PhysicalElementNames(GCController* controller)
{
  std::vector<std::string> names;
  for (NSString* key in controller.physicalInputProfile.elements)
    names.push_back(std::string([key UTF8String]));
  return names;
}

std::string JoinNames(const std::vector<std::string>& names)
{
  std::string joined;
  for (const auto& name : names)
  {
    if (!joined.empty())
      joined += ", ";
    joined += name;
  }
  return joined;
}
}  // namespace

MFiController::MFiController(GCController* controller)
    : m_gate(GetInputGate(controller)), m_controller(controller)
{
  // What the system exposes for this pad. A device log with extended=0 micro=0 and the element
  // list is how a pad the framework ships no gamepad profile for (the Nintendo Switch Online
  // N64 controller on tvOS 17) is diagnosed; see AddPhysicalProfileInputs.
  INFO_LOG_FMT(CONTROLLERINTERFACE,
               "MFi controller '{}' ({}): extended={} micro={} physical elements=[{}]",
               GetName(), std::string([controller.productCategory UTF8String]),
               controller.extendedGamepad != nil, controller.microGamepad != nil,
               JoinNames(PhysicalElementNames(controller)));

  if (controller.extendedGamepad != nil)
  {
    GCExtendedGamepad* gamepad = controller.extendedGamepad;
    AddInput(new Button(gamepad.buttonA, "Button A", m_gate));
    AddInput(new Button(gamepad.buttonB, "Button B", m_gate));
    AddInput(new Button(gamepad.buttonX, "Button X", m_gate));
    AddInput(new Button(gamepad.buttonY, "Button Y", m_gate));
    AddInput(new Button(gamepad.dpad.up, "D-Pad Up", m_gate));
    AddInput(new Button(gamepad.dpad.down, "D-Pad Down", m_gate));
    AddInput(new Button(gamepad.dpad.left, "D-Pad Left", m_gate));
    AddInput(new Button(gamepad.dpad.right, "D-Pad Right", m_gate));
    AddInput(new PressureSensitiveButton(gamepad.leftShoulder, "L Shoulder", m_gate));
    AddInput(new PressureSensitiveButton(gamepad.rightShoulder, "R Shoulder", m_gate));
    AddInput(new PressureSensitiveButton(gamepad.leftTrigger, "L Trigger", m_gate));
    AddInput(new PressureSensitiveButton(gamepad.rightTrigger, "R Trigger", m_gate));
    AddInput(new Axis(gamepad.leftThumbstick.xAxis, 1.0f, "L Stick X+", m_gate));
    AddInput(new Axis(gamepad.leftThumbstick.xAxis, -1.0f, "L Stick X-", m_gate));
    AddInput(new Axis(gamepad.leftThumbstick.yAxis, 1.0f, "L Stick Y+", m_gate));
    AddInput(new Axis(gamepad.leftThumbstick.yAxis, -1.0f, "L Stick Y-", m_gate));
    AddInput(new Axis(gamepad.rightThumbstick.xAxis, 1.0f, "R Stick X+", m_gate));
    AddInput(new Axis(gamepad.rightThumbstick.xAxis, -1.0f, "R Stick X-", m_gate));
    AddInput(new Axis(gamepad.rightThumbstick.yAxis, 1.0f, "R Stick Y+", m_gate));
    AddInput(new Axis(gamepad.rightThumbstick.yAxis, -1.0f, "R Stick Y-", m_gate));

    // Optionals and buttons only on newer iOS versions

    if (@available(iOS 14.5, *))
    {
      if ([gamepad isKindOfClass:[GCDualSenseGamepad class]])
      {
        GCDualSenseGamepad* ds_gamepad = (GCDualSenseGamepad*)gamepad;
        AddInput(new Button(ds_gamepad.touchpadButton, "Touchpad", m_gate));
        
        // The user's first finger on the touchpad.
        AddInput(new Axis(ds_gamepad.touchpadPrimary.xAxis, 1.0f, "Touchpad X+", m_gate));
        AddInput(new Axis(ds_gamepad.touchpadPrimary.xAxis, -1.0f, "Touchpad X-", m_gate));
        AddInput(new Axis(ds_gamepad.touchpadPrimary.yAxis, 1.0f, "Touchpad Y+", m_gate));
        AddInput(new Axis(ds_gamepad.touchpadPrimary.yAxis, -1.0f, "Touchpad Y-", m_gate));

        // The user's second finger on the touchpad.
        AddInput(new Axis(ds_gamepad.touchpadSecondary.xAxis, 1.0f, "Touchpad Secondary X+", m_gate));
        AddInput(new Axis(ds_gamepad.touchpadSecondary.xAxis, -1.0f, "Touchpad Secondary X-", m_gate));
        AddInput(new Axis(ds_gamepad.touchpadSecondary.yAxis, 1.0f, "Touchpad Secondary Y+", m_gate));
        AddInput(new Axis(ds_gamepad.touchpadSecondary.yAxis, -1.0f, "Touchpad Secondary Y-", m_gate));
      }
    }

    if (gamepad.buttonHome != nil)
    {
      AddInput(new Button(gamepad.buttonHome, "Home", m_gate));
    }
    
    if ([gamepad isKindOfClass:[GCDualShockGamepad class]])
    {
      GCDualShockGamepad* ds_gamepad = (GCDualShockGamepad*)gamepad;
      AddInput(new Button(ds_gamepad.touchpadButton, "Touchpad", m_gate));
      
      // The user's first finger on the touchpad.
      AddInput(new Axis(ds_gamepad.touchpadPrimary.xAxis, 1.0f, "Touchpad X+", m_gate));
      AddInput(new Axis(ds_gamepad.touchpadPrimary.xAxis, -1.0f, "Touchpad X-", m_gate));
      AddInput(new Axis(ds_gamepad.touchpadPrimary.yAxis, 1.0f, "Touchpad Y+", m_gate));
      AddInput(new Axis(ds_gamepad.touchpadPrimary.yAxis, -1.0f, "Touchpad Y-", m_gate));

      // The user's second finger on the touchpad.
      AddInput(new Axis(ds_gamepad.touchpadSecondary.xAxis, 1.0f, "Touchpad Secondary X+", m_gate));
      AddInput(new Axis(ds_gamepad.touchpadSecondary.xAxis, -1.0f, "Touchpad Secondary X-", m_gate));
      AddInput(new Axis(ds_gamepad.touchpadSecondary.yAxis, 1.0f, "Touchpad Secondary Y+", m_gate));
      AddInput(new Axis(ds_gamepad.touchpadSecondary.yAxis, -1.0f, "Touchpad Secondary Y-", m_gate));
    }
    else if ([gamepad isKindOfClass:[GCXboxGamepad class]])
    {
      GCXboxGamepad* xbox_gamepad = (GCXboxGamepad*)gamepad;
      AddInput(new Button(xbox_gamepad.paddleButton1, "Paddle 1", m_gate));
      AddInput(new Button(xbox_gamepad.paddleButton2, "Paddle 2", m_gate));
      AddInput(new Button(xbox_gamepad.paddleButton3, "Paddle 3", m_gate));
      AddInput(new Button(xbox_gamepad.paddleButton4, "Paddle 4", m_gate));
    }

    AddInput(new Button(gamepad.buttonMenu, "Menu", m_gate));

    if (gamepad.buttonOptions != nil)
    {
      AddInput(new Button(gamepad.buttonOptions, "Options", m_gate));
    }

    if (gamepad.leftThumbstickButton != nil)
    {
      AddInput(new Button(gamepad.leftThumbstickButton, "L Stick", m_gate));
    }

    if (gamepad.rightThumbstickButton != nil)
    {
      AddInput(new Button(gamepad.rightThumbstickButton, "R Stick", m_gate));
    }
  }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  else if (controller.gamepad != nil)
  {
    // Deprecated in iOS 10, but needed for some older controllers
    GCGamepad* gamepad = controller.gamepad;
    AddInput(new Button(gamepad.buttonA, "Button A", m_gate));
    AddInput(new Button(gamepad.buttonB, "Button B", m_gate));
    AddInput(new Button(gamepad.buttonX, "Button X", m_gate));
    AddInput(new Button(gamepad.buttonY, "Button Y", m_gate));
    AddInput(new Button(gamepad.dpad.up, "D-Pad Up", m_gate));
    AddInput(new Button(gamepad.dpad.down, "D-Pad Down", m_gate));
    AddInput(new Button(gamepad.dpad.left, "D-Pad Left", m_gate));
    AddInput(new Button(gamepad.dpad.right, "D-Pad Right", m_gate));
    AddInput(new PressureSensitiveButton(gamepad.leftShoulder, "L Shoulder", m_gate));
    AddInput(new PressureSensitiveButton(gamepad.rightShoulder, "R Shoulder", m_gate));
  }
#pragma clang diagnostic pop
  else if (controller.microGamepad != nil)  // Siri Remote
  {
    GCMicroGamepad* gamepad = controller.microGamepad;
    AddInput(new Button(gamepad.dpad.up, "D-Pad Up", m_gate));
    AddInput(new Button(gamepad.dpad.down, "D-Pad Down", m_gate));
    AddInput(new Button(gamepad.dpad.left, "D-Pad Left", m_gate));
    AddInput(new Button(gamepad.dpad.right, "D-Pad Right", m_gate));
    AddInput(new Button(gamepad.buttonA, "Button A", m_gate));
    AddInput(new Button(gamepad.buttonX, "Button X", m_gate));
    AddInput(new Button(gamepad.buttonMenu, "Menu", m_gate));
  }
  else if (!AddPhysicalProfileInputs(controller))
  {
    WARN_LOG_FMT(CONTROLLERINTERFACE,
                 "MFi controller '{}' exposes no gamepad profile and its physical profile has "
                 "no usable direction + face button; it will have no inputs",
                 GetName());
  }

  if (controller.motion != nil)
  {
    GCMotion* motion = controller.motion;

    // The DualShock 4 requires manual sensor activation
    if (motion.sensorsRequireManualActivation)
    {
      motion.sensorsActive = true;
    }
    
    AddInput(new AccelerometerAxis(motion, X, 1.0, "Accel Left", m_gate));
    AddInput(new AccelerometerAxis(motion, X, -1.0, "Accel Right", m_gate));
    AddInput(new AccelerometerAxis(motion, Y, -1.0, "Accel Forward", m_gate));
    AddInput(new AccelerometerAxis(motion, Y, 1.0, "Accel Back", m_gate));
    AddInput(new AccelerometerAxis(motion, Z, 1.0, "Accel Up", m_gate));
    AddInput(new AccelerometerAxis(motion, Z, -1.0, "Accel Down", m_gate));
    
    m_supports_accelerometer = true;
    m_supports_gyroscope = motion.hasRotationRate;

    if (m_supports_gyroscope)
    {
      AddInput(new GyroscopeAxis(motion, X, -1.0, "Gyro Pitch Up", m_gate));
      AddInput(new GyroscopeAxis(motion, X, 1.0, "Gyro Pitch Down", m_gate));
      AddInput(new GyroscopeAxis(motion, Y, 1.0, "Gyro Roll Left", m_gate));
      AddInput(new GyroscopeAxis(motion, Y, -1.0, "Gyro Roll Right", m_gate));
      AddInput(new GyroscopeAxis(motion, Z, 1.0, "Gyro Yaw Left", m_gate));
      AddInput(new GyroscopeAxis(motion, Z, -1.0, "Gyro Yaw Right", m_gate));
    }
  }
  else
  {
    m_supports_accelerometer = false;
  }

  GCDeviceHaptics* haptics = controller.haptics;
  if (haptics != nil)
  {
    // Prefer the handle (grip) motors, which carry rumble on DualSense/DualShock
    // and most extended controllers; fall back to the default locality otherwise.
    CHHapticEngine* engine = nil;
    if ([haptics.supportedLocalities containsObject:GCHapticsLocalityHandles])
      engine = [haptics createEngineWithLocality:GCHapticsLocalityHandles];
    if (engine == nil)
      engine = [haptics createEngineWithLocality:GCHapticsLocalityDefault];

    if (engine != nil)
      AddOutput(new Motor(engine, "Rumble"));
  }
}

// A pad the framework exposes without an extended or micro gamepad still publishes every
// physical element under `physicalInputProfile.elements`. Bind those straight to the MFi input
// names the default profiles read, with GameCube / Wii semantics (PhysicalProfileMapping.h), so
// the pad works without a core-side wrapper object. The C cluster publishes R Stick directions
// as digital buttons: a pressed C button is a full C-Stick deflection.
bool MFiController::AddPhysicalProfileInputs(GCController* controller)
{
  namespace PP = PhysicalProfile;

  const bool is_n64 = PP::IsN64Pad(GetName(), std::string([controller.productCategory UTF8String]));
  const PP::Bindings bindings = PP::ResolveBindings(PhysicalElementNames(controller), is_n64);
  if (!PP::IsUsable(bindings))
    return false;

  GCPhysicalInputProfile* profile = controller.physicalInputProfile;
  std::string summary;
  for (const auto& [name, input] : bindings)
  {
    GCControllerElement* element = profile.elements[[NSString stringWithUTF8String:name.c_str()]];
    if (element == nil)
      continue;

    if (PP::IsDirection(input))
    {
      if (![element isKindOfClass:[GCControllerDirectionPad class]])
        continue;
      GCControllerDirectionPad* pad = (GCControllerDirectionPad*)element;
      if (input == PP::Input::DPad)
      {
        AddInput(new Button(pad.up, "D-Pad Up", m_gate));
        AddInput(new Button(pad.down, "D-Pad Down", m_gate));
        AddInput(new Button(pad.left, "D-Pad Left", m_gate));
        AddInput(new Button(pad.right, "D-Pad Right", m_gate));
      }
      else
      {
        const char* side = input == PP::Input::LeftStick ? "L" : "R";
        AddInput(new Axis(pad.xAxis, 1.0f, std::string(side) + " Stick X+", m_gate));
        AddInput(new Axis(pad.xAxis, -1.0f, std::string(side) + " Stick X-", m_gate));
        AddInput(new Axis(pad.yAxis, 1.0f, std::string(side) + " Stick Y+", m_gate));
        AddInput(new Axis(pad.yAxis, -1.0f, std::string(side) + " Stick Y-", m_gate));
      }
    }
    else
    {
      if (![element isKindOfClass:[GCControllerButtonInput class]])
        continue;
      GCControllerButtonInput* button = (GCControllerButtonInput*)element;
      const std::string input_name = PP::InputName(input);
      const bool analog = input == PP::Input::LShoulder || input == PP::Input::RShoulder ||
                          input == PP::Input::LTrigger || input == PP::Input::RTrigger;
      if (analog)
        AddInput(new PressureSensitiveButton(button, input_name, m_gate));
      else
        AddInput(new Button(button, input_name, m_gate));
    }

    if (!summary.empty())
      summary += ", ";
    summary += name + " -> " + (PP::IsDirection(input) ? "(pad)" : PP::InputName(input));
  }

  INFO_LOG_FMT(CONTROLLERINTERFACE, "MFi controller '{}': synthesized inputs from physical profile{}: {}",
               GetName(), is_n64 ? " (N64 autoconfig)" : "", summary);
  return true;
}

std::shared_ptr<ControllerInputGate> MFiController::GetInputGate(GCController* controller)
{
  std::lock_guard lock(s_gates_mutex);
  const void* identity = (__bridge const void*)controller;
  auto [it, inserted] = s_gates.try_emplace(identity, GateEntry{controller, nullptr});
  if (inserted)
    it->second.gate = std::make_shared<ControllerInputGate>();
  return it->second.gate;
}

void MFiController::DisconnectInputGate(
    GCController* controller, const std::shared_ptr<ControllerInputGate>& expected_gate)
{
  std::lock_guard lock(s_gates_mutex);
  if (expected_gate)
    expected_gate->Disconnect();
  auto it = s_gates.find((__bridge const void*)controller);
  if (it != s_gates.end() && (!expected_gate || it->second.gate == expected_gate))
  {
    it->second.gate->Disconnect();
    s_gates.erase(it);
  }
}

bool MFiController::AreControlsNeutral(GCController* controller)
{
  // Read physical values, never gated GetState. Gravity/gyro do not participate: gravity is
  // nonzero at rest and motion should resume normally once the closing controls are released.
  GCPhysicalInputProfile* snapshot = [controller.physicalInputProfile capture];
  for (GCControllerElement* element in snapshot.elements.allValues)
  {
    if ([element isKindOfClass:[GCControllerButtonInput class]])
    {
      GCControllerButtonInput* button = (GCControllerButtonInput*)element;
      if (button.isPressed || std::abs(button.value) > 0.001f)
        return false;
    }
    else if ([element isKindOfClass:[GCControllerAxisInput class]])
    {
      if (std::abs(((GCControllerAxisInput*)element).value) > 0.001f)
        return false;
    }
    else if ([element isKindOfClass:[GCControllerDirectionPad class]])
    {
      GCControllerDirectionPad* pad = (GCControllerDirectionPad*)element;
      if (std::abs(pad.xAxis.value) > 0.001f || std::abs(pad.yAxis.value) > 0.001f ||
          pad.up.isPressed || pad.down.isPressed || pad.left.isPressed || pad.right.isPressed)
        return false;
    }
  }
  return true;
}

Core::DeviceRemoval MFiController::UpdateInput()
{
  if (m_gate->IsSuppressed())
    m_gate->PollNeutral([&] { return AreControlsNeutral(m_controller); });
  return Core::DeviceRemoval::Keep;
}

std::string MFiController::GetName() const
{
  NSString* vendor_name = [m_controller vendorName];
  if (vendor_name != nil)
  {
    return std::string([vendor_name UTF8String]);
  }
  else
  {
    return "Unknown Controller";
  }
}

std::string MFiController::GetSource() const
{
  return "MFi";
}

bool MFiController::SupportsAccelerometer() const
{
  return m_supports_accelerometer;
}

bool MFiController::SupportsGyroscope() const
{
  return m_supports_gyroscope;
}

bool MFiController::IsSameController(GCController* controller) const
{
  return m_controller == controller;
}

std::optional<int> MFiController::GetPreferredId() const
{
  const std::string name = GetName();
  const void* ptr = (__bridge const void*)m_controller;

  std::lock_guard<std::mutex> lock(s_assigned_ids_mutex);

  // Still-connected pad seen before (possibly under a different, now-destroyed wrapper object,
  // e.g. after a device-refresh rebuild) -- keep its ordinal no matter what order this pass
  // enumerated it in.
  for (const auto& entry : s_assigned_ids)
  {
    if (entry.controller_ptr == ptr)
      return entry.id;
  }

  // Either a genuinely new pad, or a reconnect of one that already had ReleaseId() called for it.
  // Claim the lowest ordinal not already held by another live controller sharing this vendor
  // name (the same scope AddDevice uses for id-uniqueness), so a lone pad reconnecting lands back
  // on the id it had before, and two identical pads never contend for the same slot.
  int id = 0;
  while (std::ranges::any_of(s_assigned_ids, [&](const AssignedId& entry) {
    return entry.vendor_name == name && entry.id == id;
  }))
  {
    ++id;
  }

  s_assigned_ids.push_back({name, ptr, id});
  return id;
}

void MFiController::ReleaseId(GCController* controller)
{
  DisconnectInputGate(controller);
  const void* ptr = (__bridge const void*)controller;
  std::lock_guard<std::mutex> lock(s_assigned_ids_mutex);
  std::erase_if(s_assigned_ids,
                [ptr](const AssignedId& entry) { return entry.controller_ptr == ptr; });
}

void MFiController::PruneStaleIds(NSArray<GCController*>* live_controllers)
{
  {
    std::lock_guard lock(s_gates_mutex);
    std::erase_if(s_gates, [&](const auto& entry) {
      for (GCController* controller in live_controllers)
        if (controller == entry.second.controller)
          return false;
      entry.second.gate->Disconnect();
      return true;
    });
  }
  std::lock_guard<std::mutex> lock(s_assigned_ids_mutex);
  std::erase_if(s_assigned_ids, [&live_controllers](const AssignedId& entry) {
    for (GCController* controller in live_controllers)
    {
      if ((__bridge const void*)controller == entry.controller_ptr)
        return false;
    }
    return true;
  });
}

std::string MFiController::Button::GetName() const
{
  return m_name;
}

ControlState MFiController::Button::GetState() const
{
  if (m_gate->IsSuppressed())
    return 0;
  return [m_input isPressed];
}

std::string MFiController::PressureSensitiveButton::GetName() const
{
  return m_name;
}

ControlState MFiController::PressureSensitiveButton::GetState() const
{
  if (m_gate->IsSuppressed())
    return 0;
  return [m_input value];
}

std::string MFiController::Axis::GetName() const
{
  return m_name;
}

ControlState MFiController::Axis::GetState() const
{
  if (m_gate->IsSuppressed())
    return 0;
  return [m_input value] * m_multiplier;
}

MFiController::AccelerometerAxis::AccelerometerAxis(GCMotion* motion, MotionPlane plane,
                                                    const double multiplier, const std::string name,
                                         std::shared_ptr<ControllerInputGate> gate)
    : m_gate(std::move(gate)), m_motion(motion), m_plane(plane), m_name(name)
{
  if (plane == X || plane == Y)
  {
    m_multiplier = -1.0;
  }
  else  // Z
  {
    m_multiplier = 1.0;
  }

  m_multiplier *= multiplier;
}

std::string MFiController::AccelerometerAxis::GetName() const
{
  return m_name;
}

ControlState MFiController::AccelerometerAxis::GetState() const
{
  if (m_gate->IsSuppressed())
    return 0;
  // `acceleration` is the total (gravity + user) acceleration on every controller, whether or
  // not it can also report the two parts separately. The IMU accelerometer group expects m/s^2
  // with gravity included (the DSU client and the touch overlay feed it that way); GCMotion
  // reports g. The old code multiplied userAcceleration by gravity component-wise on pads that
  // separate them (a near-zero, directionless vector at rest), and returned g on the others, so
  // the emulated Wii Remote never saw a plausible gravity vector from a PlayStation pad.
  const GCAcceleration total = [m_motion acceleration];
  const double scale = m_multiplier * MathUtil::GRAVITY_ACCELERATION;

  switch (m_plane)
  {
  case X:
    return total.x * scale;
  case Y:
    return total.y * scale;
  case Z:
    return total.z * scale;
  }
  return 0;
}

MFiController::GyroscopeAxis::GyroscopeAxis(GCMotion* motion, MotionPlane plane,
                                         const double multiplier, const std::string name,
                                         std::shared_ptr<ControllerInputGate> gate)
    : m_gate(std::move(gate)), m_motion(motion), m_plane(plane), m_name(name)
{
  if (plane == X || plane == Y)
  {
    m_multiplier = -1.0;
  }
  else  // Z
  {
    m_multiplier = 1.0;
  }

  m_multiplier *= multiplier;
}

std::string MFiController::GyroscopeAxis::GetName() const
{
  return m_name;
}

ControlState MFiController::GyroscopeAxis::GetState() const
{
  if (m_gate->IsSuppressed())
    return 0;
  switch (m_plane)
  {
  case X:
    return [m_motion rotationRate].x * m_multiplier;
  case Y:
    return [m_motion rotationRate].y * m_multiplier;
  case Z:
    return [m_motion rotationRate].z * m_multiplier;
  }
}
}  // namespace ciface::iOS
