// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "TCManagerInterface.h"

#import "InputCommon/ControllerInterface/iOS/StateManager.h"
#import <Foundation/Foundation.h>

@implementation TCManagerInterface

// This class only exists because I don't want to rewrite the touchscreen controller classes
// in Objective-C. If I did, then I could just call the C++ methods directly.

+ (void)setButtonStateFor:(NSInteger)button controller:(NSInteger)controllerId state:(BOOL)state {
  ciface::iOS::StateManager::GetInstance()->SetButtonPressed((int)controllerId, (ciface::iOS::ButtonType)button, state);
}

+ (void)setAxisValueFor:(NSInteger)axis controller:(NSInteger)controllerId value:(float)value {
  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
    NSLog(@"[INPUT][Bridge] setAxis axis=%ld controller=%ld value=%.3f", (long)axis, (long)controllerId, value);
  }
  ciface::iOS::StateManager::GetInstance()->SetAxisValue((int)controllerId, (ciface::iOS::ButtonType)axis, value);
}

@end
