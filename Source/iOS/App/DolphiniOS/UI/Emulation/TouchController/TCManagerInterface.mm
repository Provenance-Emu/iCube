// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "TCManagerInterface.h"

#import "InputCommon/ControllerInterface/iOS/StateManager.h"
#import "DSUServerBridge.h"

@implementation TCManagerInterface

// This class only exists because I don't want to rewrite the touchscreen controller classes
// in Objective-C. If I did, then I could just call the C++ methods directly.

+ (void)setButtonStateFor:(NSInteger)button controller:(NSInteger)controllerId state:(BOOL)state {
  ciface::iOS::StateManager::GetInstance()->SetButtonPressed((int)controllerId, (ciface::iOS::ButtonType)button, state);
  // Also forward to DSU server if running
  if ([DSUServerBridge isRunning]) {
    [DSUServerBridge setButton:button controller:controllerId state:state];
  }
}

+ (void)setAxisValueFor:(NSInteger)axis controller:(NSInteger)controllerId value:(float)value {
  // Apply DSU scaling parameters (gain, deadzone, smoothing) to analog axes before forwarding
  static float s_last[4][8] = {{0}}; // simple per-controller/per-axis smoothing
  NSUserDefaults* defs = NSUserDefaults.standardUserDefaults;
  float gain = (float)[defs floatForKey:@"dsu_gyro_gain"]; if (gain <= 0.f) gain = 1.f;
  float dead = (float)[defs floatForKey:@"dsu_deadzone"]; if (dead < 0.f) dead = 0.f; if (dead > 0.49f) dead = 0.49f;
  float alpha = (float)[defs floatForKey:@"dsu_smoothing"]; if (alpha < 0.f) alpha = 0.f; if (alpha > 0.95f) alpha = 0.0f; // 0 = off

  // Deadzone (assumes value in [-1, 1]) and gain
  float v = value;
  if (fabsf(v) < dead) v = 0.f; else {
    float sign = (v >= 0.f) ? 1.f : -1.f;
    float mag = (fabsf(v) - dead) / (1.f - dead);
    v = sign * mag;
  }
  v *= gain;
  if (v > 1.f) v = 1.f; if (v < -1.f) v = -1.f;

  // Smoothing (EMA)
  int ci = (int)MAX(0, MIN(3, (int)controllerId));
  int ai = (int)MAX(0, MIN(7, (int)axis));
  if (alpha > 0.f) {
    v = alpha * s_last[ci][ai] + (1.f - alpha) * v;
    s_last[ci][ai] = v;
  } else {
    s_last[ci][ai] = v;
  }

  ciface::iOS::StateManager::GetInstance()->SetAxisValue((int)controllerId, (ciface::iOS::ButtonType)axis, v);
  // Also forward to DSU server if running
  if ([DSUServerBridge isRunning]) {
    [DSUServerBridge setAxis:axis controller:controllerId value:v];
  }
}

@end
