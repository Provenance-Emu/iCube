// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "TVControllerMappingBridge.h"

// Dolphin includes
#include "InputCommon/ControllerInterface/ControllerInterface.h"
#include "InputCommon/ControllerInterface/iOS/MFiController.h"
#include "Core/HW/GCPad.h"
#include "InputCommon/InputConfig.h"
#include "InputCommon/ControllerEmu/ControllerEmu.h"
#include "Core/ConfigManager.h"
#include "Common/FileUtil.h"
#include "Common/IniFile.h"
#include <unordered_set>

@implementation TVControllerMappingBridge

+ (NSString*)qualifiedNameForController:(GCController*)controller
{
  std::string qualifier;
  const auto devices = g_controller_interface.GetAllDevices();
  for (const auto& dev : devices)
  {
    if (!dev || dev->GetSource() != "MFi")
      continue;
    const auto* mfi = dynamic_cast<const ciface::iOS::MFiController*>(dev.get());
    if (mfi && mfi->IsSameController(controller))
    {
      qualifier = dev->GetQualifiedName();
      break;
    }
  }
  return [NSString stringWithUTF8String:qualifier.c_str()];
}

+ (void)assignController:(GCController*)controller toGCPort:(NSInteger)portOneBased
{
  if (portOneBased < 1 || portOneBased > 4)
    return;

  const NSString* q = [self qualifiedNameForController:controller];
  if (q.length == 0)
    return;

  auto* cfg = Pad::GetConfig();
  if (!cfg)
    return;
  const int port = static_cast<int>(portOneBased - 1);
  auto* pad = cfg->GetController(port);
  if (!pad)
    return;
  pad->SetDefaultDevice([q UTF8String]);
  pad->UpdateReferences(g_controller_interface);

  controller.playerIndex = (GCControllerPlayerIndex)port;
}

+ (NSString*)defaultDeviceForGCPort:(NSInteger)portOneBased
{
  auto* cfg = Pad::GetConfig();
  if (!cfg)
    return @"";
  const int port = static_cast<int>(portOneBased - 1);
  auto* pad = cfg->GetController(port);
  if (!pad)
    return @"";
  const auto def = pad->GetDefaultDevice().ToString();
  return [NSString stringWithUTF8String:def.c_str()];
}

+ (void)clearDefaultDeviceForGCPort:(NSInteger)portOneBased
{
  auto* cfg = Pad::GetConfig();
  if (!cfg)
    return;
  const int port = static_cast<int>(portOneBased - 1);
  auto* pad = cfg->GetController(port);
  if (!pad)
    return;
  pad->SetDefaultDevice("");
  pad->UpdateReferences(g_controller_interface);
}

+ (void)reconcileAssignments
{
  auto* cfg = Pad::GetConfig();
  if (!cfg)
    return;

  // Build set of qualified names for currently enumerated MFi devices
  std::unordered_set<std::string> connected_qnames;
  const auto devices = g_controller_interface.GetAllDevices();
  for (const auto& dev : devices)
  {
    if (!dev || dev->GetSource() != "MFi")
      continue;
    connected_qnames.insert(dev->GetQualifiedName());
  }

  // Clear phantom defaults
  const int count = cfg->GetControllerCount();
  for (int i = 0; i < count; ++i)
  {
    auto* pad = cfg->GetController(i);
    if (!pad) continue;
    const auto dq = pad->GetDefaultDevice();
    const auto q = dq.ToString();
    if (!q.empty() && connected_qnames.find(q) == connected_qnames.end())
    {
      if (!(dq.source == "iOS" && dq.name == "Touchscreen"))
      {
        pad->SetDefaultDevice("");
        pad->UpdateReferences(g_controller_interface);
      }
    }
  }

  // Assign first connected controller to first free port (ignoring touchscreen and occupied physicals)
  for (const auto& dev : devices)
  {
    if (!dev || dev->GetSource() != "MFi")
      continue;

    ciface::Core::DeviceQualifier dq_new; dq_new.FromDevice(dev.get());
    bool already = false;
    for (int i = 0; i < count; ++i)
    {
      auto* pad = cfg->GetController(i);
      if (pad && pad->GetDefaultDevice() == dq_new) { already = true; break; }
    }
    if (already) continue;

    for (int i = 0; i < count; ++i)
    {
      auto* pad = cfg->GetController(i);
      if (!pad) continue;
      const auto cur = pad->GetDefaultDevice();
      if (connected_qnames.find(cur.ToString()) != connected_qnames.end())
        continue; // occupied by another physical controller
      pad->SetDefaultDevice(dq_new);
      pad->LoadDefaults(g_controller_interface);
      pad->UpdateReferences(g_controller_interface);
      Pad::GetConfig()->SaveConfig();
      break;
    }
  }
}

+ (void)assignTouchscreenToGCPort:(NSInteger)portOneBased
{
  if (portOneBased < 1 || portOneBased > 4)
    return;
  auto* cfg = Pad::GetConfig();
  if (!cfg)
    return;
  const auto devices = g_controller_interface.GetAllDevices();
  std::shared_ptr<ciface::Core::Device> touchscreen_dev;
  for (const auto& dev : devices)
  {
    if (dev && dev->GetSource() == std::string("iOS") && dev->GetName() == std::string("Touchscreen"))
    {
      touchscreen_dev = dev; break;
    }
  }
  if (!touchscreen_dev)
    return;
  ciface::Core::DeviceQualifier dq; dq.FromDevice(touchscreen_dev.get());
  const int port = (int)portOneBased - 1;
  auto* pad = cfg->GetController(port);
  if (!pad) return;
  pad->SetDefaultDevice(dq);
  bool loaded_profile = false;
  {
    const std::string sysDir = pad->GetConfig()->GetSysProfileDirectoryPath();
    const std::string userDir = pad->GetConfig()->GetUserProfileDirectoryPath();
    const std::string sysProfile = sysDir + (sysDir.empty() || sysDir.back() == '/' ? "" : "/") + std::string("Touchscreen.ini");
    const std::string userProfile = userDir + (userDir.empty() || userDir.back() == '/' ? "" : "/") + std::string("Touchscreen.ini");

    Common::IniFile ini;
    if (File::Exists(userProfile) && ini.Load(userProfile))
    {
      pad->LoadConfig(ini.GetOrCreateSection("Profile"));
      loaded_profile = true;
    }
    else if (File::Exists(sysProfile) && ini.Load(sysProfile))
    {
      pad->LoadConfig(ini.GetOrCreateSection("Profile"));
      loaded_profile = true;
    }
  }

  if (!loaded_profile)
  {
    // Fallback to defaults, then ensure Touchscreen stays the default device
    pad->LoadDefaults(g_controller_interface);
    pad->SetDefaultDevice(dq);
  }

  pad->UpdateReferences(g_controller_interface);
  Pad::GetConfig()->SaveConfig();
}

@end
