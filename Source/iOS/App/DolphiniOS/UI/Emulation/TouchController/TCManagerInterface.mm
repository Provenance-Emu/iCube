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

+ (float)axisValueFor:(NSInteger)axis controller:(NSInteger)controllerId {
  // StateManager::GetAxisValue uses std::map::at, which throws for an axis never written.
  try {
    return ciface::iOS::StateManager::GetInstance()->GetAxisValue((int)controllerId, (ciface::iOS::ButtonType)axis);
  } catch (const std::out_of_range&) {
    return 0.f;
  }
}

+ (void)clearAllForController:(NSInteger)controllerId {
  ciface::iOS::StateManager::GetInstance()->ClearController((int)controllerId);
  // Release every DSU mirror this class writes in setButtonStateFor:/setAxisValueFor:
  // too, so a torn-down overlay cannot leave a DSU client's view of the pad stuck
  // even though the core-facing StateManager has already released it.
  [DSUServerBridge setDPadUpForController:controllerId state:NO];
  [DSUServerBridge setDPadDownForController:controllerId state:NO];
  [DSUServerBridge setDPadLeftForController:controllerId state:NO];
  [DSUServerBridge setDPadRightForController:controllerId state:NO];
  for (NSInteger shape = 0; shape < 4; shape++) {
    [DSUServerBridge setButton:shape controller:controllerId state:NO];
  }
  [DSUServerBridge setShare:controllerId state:NO];
  [DSUServerBridge setOptions:controllerId state:NO];
  [DSUServerBridge setPS:controllerId state:NO];
  [DSUServerBridge setShoulderL:controllerId state:NO];
  [DSUServerBridge setShoulderR:controllerId state:NO];
  [DSUServerBridge setTouch:controllerId state:NO];
  [DSUServerBridge setAxis:0 controller:controllerId value:0.f];
  [DSUServerBridge setAxis:1 controller:controllerId value:0.f];
  [DSUServerBridge setAxis:2 controller:controllerId value:0.f];
  [DSUServerBridge setAxis:3 controller:controllerId value:0.f];
  // GC analog triggers map [0..1] -> [-1..1] (t = v*2-1); rest (v=0) is t=-1.
  [DSUServerBridge setAxis:4 controller:controllerId value:-1.f];
  [DSUServerBridge setAxis:5 controller:controllerId value:-1.f];
  [DSUServerBridge setTouchPoint:0 controller:controllerId active:NO x:0 y:0];
}

// Aggregate split stick inputs (Up/Down/Left/Right) into full X/Y for DSU
static float s_splitAxes[4][256] = {{0}}; // [controller][axisIndex] last values in [-1,1] (size covers up to 255)
static inline float clamp11(float v) { return v < -1.f ? -1.f : (v > 1.f ? 1.f : v); }

+ (void)setAxisValueFor:(NSInteger)axis controller:(NSInteger)controllerId value:(float)value {
//  NSLog(@"Set axis value for %i, controller %i, value: %f", axis, controllerId, value);
  // Apply DSU scaling parameters to analog axes before forwarding
  static float s_last[4][256] = {{0}}; // simple per-controller/per-axis smoothing
  NSUserDefaults* defs = NSUserDefaults.standardUserDefaults;
  float gain = (float)[defs floatForKey:@"dsu_gyro_gain"]; if (gain <= 0.f) gain = 1.f;
  float dead = (float)[defs floatForKey:@"dsu_deadzone"]; if (dead < 0.f) dead = 0.f; if (dead > 0.49f) dead = 0.49f;
  float alpha = (float)[defs floatForKey:@"dsu_smoothing"]; if (alpha < 0.f) alpha = 0.f; if (alpha > 0.95f) alpha = 0.0f; // 0 = off

  // Axis classification. Classify against the UNCLAMPED `axis`: the IMU ranges (625-636,
  // 900-905) sit above the 256-entry smoothing tables, so testing the clamped index `ai`
  // could never match them and every gyro/accel write fell through as an ordinary analog
  // axis (deadzone, gain, EMA, and a +/-1 clamp that cut gravity from ~9.8 to 1 m/s^2).
  // `ai` is ONLY an array index, valid solely for axes below 256.
  int ci = (int)MAX(0, MIN(3, (int)controllerId));
  const bool is_split_stick = ((axis >= 11 && axis <= 14) || (axis >= 16 && axis <= 19) || (axis >= 203 && axis <= 206));
  const bool is_ir_axis = (axis >= 112 && axis <= 115); // Wii IR Up/Down/Left/Right
  const bool is_imu_axis = ((axis >= 625 && axis <= 636) || (axis >= 900 && axis <= 905)); // Wiimote+Nunchuk IMU
  const bool has_smoothing_cell = (axis >= 0 && axis < 256);
  int ai = has_smoothing_cell ? (int)axis : 0;

  // IMU axes carry m/s^2 and rad/s and go to the core raw, exactly as upstream DolphiniOS
  // forwarded them: no deadzone, no gain, no smoothing, no unit-range clamp.
  float v = value;
  if (!is_imu_axis) {
    // Deadzone/gain only for standard analog axes; IR is already normalized by its writer.
    if (!is_ir_axis) {
      if (fabsf(v) < dead) v = 0.f; else {
        float sign = (v >= 0.f) ? 1.f : -1.f;
        float mag = (fabsf(v) - dead) / (1.f - dead);
        v = sign * mag;
      }
      v *= gain;
    }
    if (v > 1.f) v = 1.f; if (v < -1.f) v = -1.f;

    // Smoothing (EMA). Disable for split-stick and IR axes.
    const bool allow_smoothing = (alpha > 0.f) && has_smoothing_cell && !(is_split_stick || is_ir_axis);
    if (allow_smoothing) {
      v = alpha * s_last[ci][ai] + (1.f - alpha) * v;
    }
    if (has_smoothing_cell) s_last[ci][ai] = v;
  }

  ciface::iOS::StateManager::GetInstance()->SetAxisValue((int)controllerId, (ciface::iOS::ButtonType)axis, v);
  // Also forward to DSU server if running
  if ([DSUServerBridge isRunning]) {
    // **WIIMOTE IR POINTER** - Forward IR data to DSU touch coordinates
    // Uses TCButtonType.wiiInfraredUp/Down/Left/Right indices (112-115)
    if (axis >= 112 && axis <= 115) {
      static float ir_x = 0.0f, ir_y = 0.0f;
      if (axis == 112 || axis == 113) { ir_y = v; }
      if (axis == 114 || axis == 115) { ir_x = v; }
      int touch_x = (int)((ir_x + 1.0f) * 0.5f * 1920.0f);
      int touch_y = (int)((ir_y + 1.0f) * 0.5f * 1080.0f);
      BOOL active = (fabsf(ir_x) > 0.01f || fabsf(ir_y) > 0.01f);
      [DSUServerBridge setTouchPoint:0 controller:controllerId active:active x:touch_x y:touch_y];
    }

    // Forward Wiimote gyro data to DSU (axes 631-636 are IMU gyro)
    if (axis >= 631 && axis <= 636) {
      static float gyro_pitch = 0.0f, gyro_yaw = 0.0f, gyro_roll = 0.0f;
      // Convert radians/sec to degrees/sec for DSU protocol
      float deg_per_sec = v * (180.0f / M_PI);

      if (axis == 631 || axis == 632) { // Pitch Up/Down
        gyro_pitch = (axis == 632) ? deg_per_sec : -deg_per_sec;
      } else if (axis == 635 || axis == 636) { // Yaw Left/Right
        gyro_yaw = (axis == 636) ? deg_per_sec : -deg_per_sec;
      } else if (axis == 633 || axis == 634) { // Roll Left/Right
        gyro_roll = (axis == 634) ? deg_per_sec : -deg_per_sec;
      }

      [DSUServerBridge setGyro:controllerId pitch:gyro_pitch yaw:gyro_yaw roll:gyro_roll];
    }

    // Forward Wiimote accelerometer data to DSU (axes 625-630 are IMU accel)
    if (axis >= 625 && axis <= 630) {
      static float accel_x = 0.0f, accel_y = 0.0f, accel_z = 0.0f;

      if (axis == 625 || axis == 626) { // Accel Left/Right
        accel_x = (axis == 626) ? v : -v;
      } else if (axis == 627 || axis == 628) { // Accel Forward/Backward
        accel_y = (axis == 628) ? v : -v;
      } else if (axis == 629 || axis == 630) { // Accel Up/Down
        accel_z = (axis == 630) ? v : -v;
      }

      [DSUServerBridge setAccelerometer:controllerId x:accel_x y:accel_y z:accel_z];
    }
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
        // Match TCJoystick: left axis reports negative, right axis reports positive
        float leftValue = s_splitAxes[ci][leftIdx];   // negative when left
        float rightValue = s_splitAxes[ci][rightIdx]; // positive when right, negative when left
        float leftMag = leftValue < 0.f ? -leftValue : 0.f;    // 0..1
        float rightMag = rightValue > 0.f ? rightValue : 0.f;  // 0..1
        float result = clamp11(rightMag - leftMag); // right positive, left negative
        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
          NSLog(@"[DSU] combLR: leftVal=%.3f rightVal=%.3f leftMag=%.3f rightMag=%.3f result=%.3f", leftValue, rightValue, leftMag, rightMag, result);
        }
        return result;
      };
      auto combUD = ^(int upIdx, int downIdx) {
        // Match TCJoystick: up axis reports negative, down axis reports positive
        float upValue = s_splitAxes[ci][upIdx];     // negative when up
        float downValue = s_splitAxes[ci][downIdx]; // positive when down, negative when up
        float upMag = upValue < 0.f ? -upValue : 0.f;       // 0..1
        float downMag = downValue > 0.f ? downValue : 0.f;  // 0..1
        float result = clamp11(downMag - upMag); // down positive, up negative
        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
          NSLog(@"[DSU] combUD: upVal=%.3f downVal=%.3f upMag=%.3f downMag=%.3f result=%.3f", upValue, downValue, upMag, downMag, result);
        }
        return result;
      };

      if (axis >= 11 && axis <= 14) {
        float lx = combLR(13, 14); // Left-, Right+
        float ly = combUD(11, 12); // Up-, Down+
        // Snap small residuals to zero to avoid stickiness
        if (fabsf(lx) < 0.02f) lx = 0.f; if (fabsf(ly) < 0.02f) ly = 0.f;
        [DSUServerBridge setAxis:0 controller:controllerId value:lx];
        [DSUServerBridge setAxis:1 controller:controllerId value:ly];
        // Recenter guard: resend center shortly after release to overcome missed events
        if (lx == 0.f && ly == 0.f) {
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            [DSUServerBridge setAxis:0 controller:controllerId value:0.f];
            [DSUServerBridge setAxis:1 controller:controllerId value:0.f];
          });
        }
      } else if (axis >= 16 && axis <= 19) {
        float rx = combLR(18, 19); // Left-, Right+
        float ry = combUD(16, 17); // Up-, Down+
        if (fabsf(rx) < 0.02f) rx = 0.f; if (fabsf(ry) < 0.02f) ry = 0.f;
        [DSUServerBridge setAxis:2 controller:controllerId value:rx];
        [DSUServerBridge setAxis:3 controller:controllerId value:ry];
        if (rx == 0.f && ry == 0.f) {
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            [DSUServerBridge setAxis:2 controller:controllerId value:0.f];
            [DSUServerBridge setAxis:3 controller:controllerId value:0.f];
          });
        }
      } else {
        // Nunchuk stick - only send if there's actual input to avoid overwriting main stick
        float lx2 = combLR(205, 206); // Left-, Right+
        float ly2 = combUD(203, 204); // Up-, Down+
        if (fabsf(lx2) > 0.01f || fabsf(ly2) > 0.01f) {
          [DSUServerBridge setAxis:0 controller:controllerId value:lx2];
          [DSUServerBridge setAxis:1 controller:controllerId value:ly2];
        } else {
          // If both near zero, ensure main stick recenters as well
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            [DSUServerBridge setAxis:0 controller:controllerId value:0.f];
            [DSUServerBridge setAxis:1 controller:controllerId value:0.f];
          });
        }
      }
    }
  }
}

@end
