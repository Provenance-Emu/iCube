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
  // Mirror D-Pad presses to DSU analog dpad fields so DSU clients receive them
  // GameCube D-Pad (Up=6,Down=7,Left=8,Right=9)
  if (button == 6)  { [DSUServerBridge setDPadUpForController:controllerId state:state]; }
  if (button == 7)  { [DSUServerBridge setDPadDownForController:controllerId state:state]; }
  if (button == 8)  { [DSUServerBridge setDPadLeftForController:controllerId state:state]; }
  if (button == 9)  { [DSUServerBridge setDPadRightForController:controllerId state:state]; }
  // Wii Remote D-Pad (Up=107,Down=108,Left=109,Right=110)
  if (button == 107) { [DSUServerBridge setDPadUpForController:controllerId state:state]; }
  if (button == 108) { [DSUServerBridge setDPadDownForController:controllerId state:state]; }
  if (button == 109) { [DSUServerBridge setDPadLeftForController:controllerId state:state]; }
  if (button == 110) { [DSUServerBridge setDPadRightForController:controllerId state:state]; }
  // Map GC/Wii face buttons to DSU face analogs: indices (Square=0, Cross=1, Circle=2, Triangle=3)
  // GameCube: A->Cross(1), B->Circle(2), X->Square(0), Y->Triangle(3)
  if (button == 0)  { [DSUServerBridge setButton:1 controller:controllerId state:state]; }
  if (button == 1)  { [DSUServerBridge setButton:2 controller:controllerId state:state]; }
  if (button == 3)  { [DSUServerBridge setButton:0 controller:controllerId state:state]; }
  if (button == 4)  { [DSUServerBridge setButton:3 controller:controllerId state:state]; }
  // Wii Remote: A->Cross(1), B->Circle(2), 1->Square(0), 2->Triangle(3)
  if (button == 100) { [DSUServerBridge setButton:1 controller:controllerId state:state]; }
  if (button == 101) { [DSUServerBridge setButton:2 controller:controllerId state:state]; }
  if (button == 105) { [DSUServerBridge setButton:0 controller:controllerId state:state]; }
  if (button == 106) { [DSUServerBridge setButton:3 controller:controllerId state:state]; }
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
    // GC analog triggers: L(20)->DSU axis 4, R(21)->DSU axis 5, map [0..1] to [-1..1]
    if (axis == 20 || axis == 21) {
      float t = (v * 2.f) - 1.f;
      [DSUServerBridge setAxis:(axis == 20 ? 4 : 5) controller:controllerId value:t];
    }
    // Note: GC/Wii sticks from NIB use split directional axes; we leave DSU sticks to other sources for now
  }
}

@end
