// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "InputCommon/ControllerInterface/iOS/MFiController.h"

#include <algorithm>
#include <mutex>
#include <vector>

#include "InputCommon/ControllerInterface/iOS/Motor.h"
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
}  // namespace

MFiController::MFiController(GCController* controller) : m_controller(controller)
{
  if (controller.extendedGamepad != nil)
  {
    GCExtendedGamepad* gamepad = controller.extendedGamepad;
    AddInput(new Button(gamepad.buttonA, "Button A"));
    AddInput(new Button(gamepad.buttonB, "Button B"));
    AddInput(new Button(gamepad.buttonX, "Button X"));
    AddInput(new Button(gamepad.buttonY, "Button Y"));
    AddInput(new Button(gamepad.dpad.up, "D-Pad Up"));
    AddInput(new Button(gamepad.dpad.down, "D-Pad Down"));
    AddInput(new Button(gamepad.dpad.left, "D-Pad Left"));
    AddInput(new Button(gamepad.dpad.right, "D-Pad Right"));
    AddInput(new PressureSensitiveButton(gamepad.leftShoulder, "L Shoulder"));
    AddInput(new PressureSensitiveButton(gamepad.rightShoulder, "R Shoulder"));
    AddInput(new PressureSensitiveButton(gamepad.leftTrigger, "L Trigger"));
    AddInput(new PressureSensitiveButton(gamepad.rightTrigger, "R Trigger"));
    AddInput(new Axis(gamepad.leftThumbstick.xAxis, 1.0f, "L Stick X+"));
    AddInput(new Axis(gamepad.leftThumbstick.xAxis, -1.0f, "L Stick X-"));
    AddInput(new Axis(gamepad.leftThumbstick.yAxis, 1.0f, "L Stick Y+"));
    AddInput(new Axis(gamepad.leftThumbstick.yAxis, -1.0f, "L Stick Y-"));
    AddInput(new Axis(gamepad.rightThumbstick.xAxis, 1.0f, "R Stick X+"));
    AddInput(new Axis(gamepad.rightThumbstick.xAxis, -1.0f, "R Stick X-"));
    AddInput(new Axis(gamepad.rightThumbstick.yAxis, 1.0f, "R Stick Y+"));
    AddInput(new Axis(gamepad.rightThumbstick.yAxis, -1.0f, "R Stick Y-"));

    // Optionals and buttons only on newer iOS versions

    if (@available(iOS 14.5, *))
    {
      if ([gamepad isKindOfClass:[GCDualSenseGamepad class]])
      {
        GCDualSenseGamepad* ds_gamepad = (GCDualSenseGamepad*)gamepad;
        AddInput(new Button(ds_gamepad.touchpadButton, "Touchpad"));
        
        // The user's first finger on the touchpad.
        AddInput(new Axis(ds_gamepad.touchpadPrimary.xAxis, 1.0f, "Touchpad X+"));
        AddInput(new Axis(ds_gamepad.touchpadPrimary.xAxis, -1.0f, "Touchpad X-"));
        AddInput(new Axis(ds_gamepad.touchpadPrimary.yAxis, 1.0f, "Touchpad Y+"));
        AddInput(new Axis(ds_gamepad.touchpadPrimary.yAxis, -1.0f, "Touchpad Y-"));

        // The user's second finger on the touchpad.
        AddInput(new Axis(ds_gamepad.touchpadSecondary.xAxis, 1.0f, "Touchpad Secondary X+"));
        AddInput(new Axis(ds_gamepad.touchpadSecondary.xAxis, -1.0f, "Touchpad Secondary X-"));
        AddInput(new Axis(ds_gamepad.touchpadSecondary.yAxis, 1.0f, "Touchpad Secondary Y+"));
        AddInput(new Axis(ds_gamepad.touchpadSecondary.yAxis, -1.0f, "Touchpad Secondary Y-"));
      }
    }

    if (gamepad.buttonHome != nil)
    {
      AddInput(new Button(gamepad.buttonHome, "Home"));
    }
    
    if ([gamepad isKindOfClass:[GCDualShockGamepad class]])
    {
      GCDualShockGamepad* ds_gamepad = (GCDualShockGamepad*)gamepad;
      AddInput(new Button(ds_gamepad.touchpadButton, "Touchpad"));
      
      // The user's first finger on the touchpad.
      AddInput(new Axis(ds_gamepad.touchpadPrimary.xAxis, 1.0f, "Touchpad X+"));
      AddInput(new Axis(ds_gamepad.touchpadPrimary.xAxis, -1.0f, "Touchpad X-"));
      AddInput(new Axis(ds_gamepad.touchpadPrimary.yAxis, 1.0f, "Touchpad Y+"));
      AddInput(new Axis(ds_gamepad.touchpadPrimary.yAxis, -1.0f, "Touchpad Y-"));

      // The user's second finger on the touchpad.
      AddInput(new Axis(ds_gamepad.touchpadSecondary.xAxis, 1.0f, "Touchpad Secondary X+"));
      AddInput(new Axis(ds_gamepad.touchpadSecondary.xAxis, -1.0f, "Touchpad Secondary X-"));
      AddInput(new Axis(ds_gamepad.touchpadSecondary.yAxis, 1.0f, "Touchpad Secondary Y+"));
      AddInput(new Axis(ds_gamepad.touchpadSecondary.yAxis, -1.0f, "Touchpad Secondary Y-"));
    }
    else if ([gamepad isKindOfClass:[GCXboxGamepad class]])
    {
      GCXboxGamepad* xbox_gamepad = (GCXboxGamepad*)gamepad;
      AddInput(new Button(xbox_gamepad.paddleButton1, "Paddle 1"));
      AddInput(new Button(xbox_gamepad.paddleButton2, "Paddle 2"));
      AddInput(new Button(xbox_gamepad.paddleButton3, "Paddle 3"));
      AddInput(new Button(xbox_gamepad.paddleButton4, "Paddle 4"));
    }

    AddInput(new Button(gamepad.buttonMenu, "Menu"));

    if (gamepad.buttonOptions != nil)
    {
      AddInput(new Button(gamepad.buttonOptions, "Options"));
    }

    if (gamepad.leftThumbstickButton != nil)
    {
      AddInput(new Button(gamepad.leftThumbstickButton, "L Stick"));
    }

    if (gamepad.rightThumbstickButton != nil)
    {
      AddInput(new Button(gamepad.rightThumbstickButton, "R Stick"));
    }
  }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  else if (controller.gamepad != nil)
  {
    // Deprecated in iOS 10, but needed for some older controllers
    GCGamepad* gamepad = controller.gamepad;
    AddInput(new Button(gamepad.buttonA, "Button A"));
    AddInput(new Button(gamepad.buttonB, "Button B"));
    AddInput(new Button(gamepad.buttonX, "Button X"));
    AddInput(new Button(gamepad.buttonY, "Button Y"));
    AddInput(new Button(gamepad.dpad.up, "D-Pad Up"));
    AddInput(new Button(gamepad.dpad.down, "D-Pad Down"));
    AddInput(new Button(gamepad.dpad.left, "D-Pad Left"));
    AddInput(new Button(gamepad.dpad.right, "D-Pad Right"));
    AddInput(new PressureSensitiveButton(gamepad.leftShoulder, "L Shoulder"));
    AddInput(new PressureSensitiveButton(gamepad.rightShoulder, "R Shoulder"));
  }
#pragma clang diagnostic pop
  else if (controller.microGamepad != nil)  // Siri Remote
  {
    GCMicroGamepad* gamepad = controller.microGamepad;
    AddInput(new Button(gamepad.dpad.up, "D-Pad Up"));
    AddInput(new Button(gamepad.dpad.down, "D-Pad Down"));
    AddInput(new Button(gamepad.dpad.left, "D-Pad Left"));
    AddInput(new Button(gamepad.dpad.right, "D-Pad Right"));
    AddInput(new Button(gamepad.buttonA, "Button A"));
    AddInput(new Button(gamepad.buttonX, "Button X"));
    AddInput(new Button(gamepad.buttonMenu, "Menu"));
  }

  if (controller.motion != nil)
  {
    GCMotion* motion = controller.motion;

    // The DualShock 4 requires manual sensor activation
    if (motion.sensorsRequireManualActivation)
    {
      motion.sensorsActive = true;
    }
    
    AddInput(new AccelerometerAxis(motion, X, 1.0, "Accel Left"));
    AddInput(new AccelerometerAxis(motion, X, -1.0, "Accel Right"));
    AddInput(new AccelerometerAxis(motion, Y, -1.0, "Accel Forward"));
    AddInput(new AccelerometerAxis(motion, Y, 1.0, "Accel Back"));
    AddInput(new AccelerometerAxis(motion, Z, 1.0, "Accel Up"));
    AddInput(new AccelerometerAxis(motion, Z, -1.0, "Accel Down"));
    
    m_supports_accelerometer = true;
    m_supports_gyroscope = motion.hasRotationRate;

    if (m_supports_gyroscope)
    {
      AddInput(new GyroscopeAxis(motion, X, -1.0, "Gyro Pitch Up"));
      AddInput(new GyroscopeAxis(motion, X, 1.0, "Gyro Pitch Down"));
      AddInput(new GyroscopeAxis(motion, Y, 1.0, "Gyro Roll Left"));
      AddInput(new GyroscopeAxis(motion, Y, -1.0, "Gyro Roll Right"));
      AddInput(new GyroscopeAxis(motion, Z, 1.0, "Gyro Yaw Left"));
      AddInput(new GyroscopeAxis(motion, Z, -1.0, "Gyro Yaw Right"));
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
  const void* ptr = (__bridge const void*)controller;
  std::lock_guard<std::mutex> lock(s_assigned_ids_mutex);
  std::erase_if(s_assigned_ids,
                [ptr](const AssignedId& entry) { return entry.controller_ptr == ptr; });
}

void MFiController::PruneStaleIds(NSArray<GCController*>* live_controllers)
{
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
  return [m_input isPressed];
}

std::string MFiController::PressureSensitiveButton::GetName() const
{
  return m_name;
}

ControlState MFiController::PressureSensitiveButton::GetState() const
{
  return [m_input value];
}

std::string MFiController::Axis::GetName() const
{
  return m_name;
}

ControlState MFiController::Axis::GetState() const
{
  return [m_input value] * m_multiplier;
}

MFiController::AccelerometerAxis::AccelerometerAxis(GCMotion* motion, MotionPlane plane,
                                                    const double multiplier, const std::string name)
    : m_motion(motion), m_plane(plane), m_name(name)
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
  // The DualShock 4 only returns combined gravity + acceleration.
  if ([m_motion hasGravityAndUserAcceleration])
  {
    GCAcceleration totalAcceleration = [m_motion acceleration];
    
    switch (m_plane)
    {
    case X:
      return totalAcceleration.x * m_multiplier;
    case Y:
      return totalAcceleration.y * m_multiplier;
    case Z:
      return totalAcceleration.z * m_multiplier;
    }
  }
  
  GCAcceleration acceleration = [m_motion userAcceleration];
  GCAcceleration gravity = [m_motion gravity];

  switch (m_plane)
  {
  case X:
    return acceleration.x * gravity.x * m_multiplier;
  case Y:
    return acceleration.y * gravity.y * m_multiplier;
  case Z:
    return acceleration.z * gravity.z * m_multiplier;
  }
}

MFiController::GyroscopeAxis::GyroscopeAxis(GCMotion* motion, MotionPlane plane,
                                         const double multiplier, const std::string name)
    : m_motion(motion), m_plane(plane), m_name(name)
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
