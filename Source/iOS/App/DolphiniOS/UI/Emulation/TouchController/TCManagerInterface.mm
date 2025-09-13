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
  // Map only Wii face buttons to DSU shapes; GC mapping will be handled by profiles
  // Wii Remote: A->Cross(1), B->Circle(2), 1->Square(0), 2->Triangle(3)
  if (button == 100) { [DSUServerBridge setButton:1 controller:controllerId state:state]; }
  if (button == 101) { [DSUServerBridge setButton:2 controller:controllerId state:state]; }
  if (button == 105) { [DSUServerBridge setButton:0 controller:controllerId state:state]; }
  if (button == 106) { [DSUServerBridge setButton:3 controller:controllerId state:state]; }
  // Wii special: - / + / Home
  if (button == 102) { [DSUServerBridge setShare:controllerId state:state]; }
  if (button == 103) { [DSUServerBridge setOptions:controllerId state:state]; }
  if (button == 104) { [DSUServerBridge setPS:controllerId state:state]; }
  // Wii shoulders as convenience for classic/nunchuk in DSU receiver
  if (button == 200) { [DSUServerBridge setShoulderL:controllerId state:state]; }
  if (button == 201) { [DSUServerBridge setShoulderR:controllerId state:state]; }
  // GC convenience: Start -> DSU PS for Start mapping via profile; do not map Z here to avoid double bindings
  if (button == 2) { [DSUServerBridge setPS:controllerId state:state]; }
  // GC face to DSU shapes for DSU profiles
  if (button == 0) { [DSUServerBridge setButton:1 controller:controllerId state:state]; } // A -> Cross
  if (button == 1) { [DSUServerBridge setButton:2 controller:controllerId state:state]; } // B -> Circle
  if (button == 3) { [DSUServerBridge setButton:0 controller:controllerId state:state]; } // X -> Square
  if (button == 4) { [DSUServerBridge setButton:3 controller:controllerId state:state]; } // Y -> Triangle
  // GC Z -> DSU Touch Button
  if (button == 5) { [DSUServerBridge setTouch:controllerId state:state]; }
}

// Aggregate split stick inputs (Up/Down/Left/Right) into full X/Y for DSU
static float s_splitAxes[4][256] = {{0}}; // [controller][axisIndex] last values in [-1,1] (size covers up to 255)
static inline float clamp11(float v) { return v < -1.f ? -1.f : (v > 1.f ? 1.f : v); }

+ (void)setAxisValueFor:(NSInteger)axis controller:(NSInteger)controllerId value:(float)value {
  // Apply DSU scaling parameters (gain, deadzone, smoothing) to analog axes before forwarding
  static float s_last[4][256] = {{0}}; // simple per-controller/per-axis smoothing
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

  // Smoothing (EMA). Disable for split-stick axes to avoid clamping/angle bias.
  int ci = (int)MAX(0, MIN(3, (int)controllerId));
  int ai = (int)MAX(0, MIN(255, (int)axis));
  const bool is_split_stick = ((ai >= 11 && ai <= 14) || (ai >= 16 && ai <= 19) || (ai >= 203 && ai <= 206));
  if (alpha > 0.f && !is_split_stick) {
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
      BOOL pressed = v > 0.7f;
      if (axis == 20) { [DSUServerBridge setShoulderL:controllerId state:pressed]; }
      if (axis == 21) { [DSUServerBridge setShoulderR:controllerId state:pressed]; }
    }

    // Aggregate NIB split sticks to DSU sticks (use magnitude-based signed combination)
    // Main stick: 11 (Up-), 12 (Down+), 13 (Left-), 14 (Right+)
    // C-stick:    16 (Up-), 17 (Down+), 18 (Left-), 19 (Right+)
    // Nunchuk:    203 (Up-), 204 (Down+), 205 (Left-), 206 (Right+)
    if ((axis >= 11 && axis <= 14) || (axis >= 16 && axis <= 19) || (axis >= 203 && axis <= 206)) {
      int aidx = (int)axis;
      s_splitAxes[ci][aidx] = clamp11(v);

      auto combLR = ^(int leftIdx, int rightIdx) {
        // Split-stick axes: negative values mean the direction is active
        float l = s_splitAxes[ci][leftIdx];   // Left: negative when active
        float r = s_splitAxes[ci][rightIdx];  // Right: negative when active
        // Convert: left active (negative) -> negative result, right active (negative) -> positive result
        float result = clamp11(-r - (-l)); // Simplifies to: clamp11(l - r)
        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
          NSLog(@"[DSU] combLR: l=%.3f r=%.3f result=%.3f (leftIdx=%d rightIdx=%d)", l, r, result, leftIdx, rightIdx);
        }
        return result;
      };
      auto combUD = ^(int upIdx, int downIdx) {
        // Split-stick axes: negative values mean the direction is active
        float u = s_splitAxes[ci][upIdx];     // Up: negative when active
        float d = s_splitAxes[ci][downIdx];   // Down: negative when active
        // Convert: up active (negative) -> negative result, down active (negative) -> positive result
        float result = clamp11(-d - (-u)); // Simplifies to: clamp11(u - d)
        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
          NSLog(@"[DSU] combUD: u=%.3f d=%.3f result=%.3f (upIdx=%d downIdx=%d)", u, d, result, upIdx, downIdx);
        }
        return result;
      };

      if (axis >= 11 && axis <= 14) {
        float lx = combLR(13, 14); // Left-, Right+
        float ly = combUD(11, 12); // Up-, Down+
        [DSUServerBridge setAxis:0 controller:controllerId value:lx];
        [DSUServerBridge setAxis:1 controller:controllerId value:ly];
      } else if (axis >= 16 && axis <= 19) {
        float rx = combLR(18, 19); // Left-, Right+
        float ry = combUD(16, 17); // Up-, Down+
        [DSUServerBridge setAxis:2 controller:controllerId value:rx];
        [DSUServerBridge setAxis:3 controller:controllerId value:ry];
      } else {
        // Nunchuk stick - only send if there's actual input to avoid overwriting main stick
        float lx2 = combLR(205, 206); // Left-, Right+
        float ly2 = combUD(203, 204); // Up-, Down+
        if (fabsf(lx2) > 0.01f || fabsf(ly2) > 0.01f) {
          [DSUServerBridge setAxis:0 controller:controllerId value:lx2];
          [DSUServerBridge setAxis:1 controller:controllerId value:ly2];
        }
      }
    }
  }
}

@end
