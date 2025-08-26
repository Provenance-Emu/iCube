// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "TVControllerMappingBridge.h"

// Dolphin includes
#include "InputCommon/ControllerInterface/ControllerInterface.h"
#include "InputCommon/ControllerInterface/iOS/MFiController.h"
#include "Core/HW/GCPad.h"
#include "InputCommon/InputConfig.h"
#include "InputCommon/ControllerEmu/ControllerEmu.h"

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

@end
