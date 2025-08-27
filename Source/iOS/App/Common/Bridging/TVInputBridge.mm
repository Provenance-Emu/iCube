// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "TVInputBridge.h"
#import <Foundation/Foundation.h>

// Dolphin Core
#include "Core/HW/Wiimote.h"
#include "Core/HW/WiimoteEmu/WiimoteEmu.h"

@implementation TVInputBridge

+ (void)setWiimoteIMUPointEnabled:(BOOL)enabled forPort:(int)port
{
  ControllerEmu::ControlGroup* group = Wiimote::GetWiimoteGroup(port, WiimoteEmu::WiimoteGroup::IMUPoint);
  if (group)
  {
    group->enabled = enabled;
  }
  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
    NSLog(@"[INPUT] tvOS: set IMUPoint enabled=%@ port=%d", enabled ? @"true" : @"false", port);
  }
}

@end
