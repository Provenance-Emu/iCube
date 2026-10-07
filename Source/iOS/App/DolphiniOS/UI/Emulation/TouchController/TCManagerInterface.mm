// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "TCManagerInterface.h"

#import "InputCommon/ControllerInterface/iOS/StateManager.h"
#import "DSUServerBridge.h"

#include <atomic>
#include <os/lock.h>

// setAxisValueFor: runs for every analog sample (touch stick moves, the phone's IMU at 200 Hz, a
// physical controller's motion and touchpad), so it must not read NSUserDefaults each time. These
// mirror the DSU knobs and `input_debug`, refreshed whenever any user default changes. The
// notification is posted synchronously on the writing thread, so a write is visible to the very
// next axis write (TCManagerInterfaceAxisTests sets the knobs and writes immediately).
static NSString* const kDSUGainKey = @"dsu_gyro_gain";
static NSString* const kDSUDeadzoneKey = @"dsu_deadzone";
static NSString* const kDSUSmoothingKey = @"dsu_smoothing";
static NSString* const kInputDebugKey = @"input_debug";
static std::atomic<float> s_dsuGain{1.f};
static std::atomic<float> s_dsuDeadzone{0.f};
static std::atomic<float> s_dsuSmoothing{0.f};
static std::atomic<bool> s_inputDebug{false};

static void TCRefreshInputDefaults(void) {
  NSUserDefaults* defs = NSUserDefaults.standardUserDefaults;
  float gain = (float)[defs floatForKey:kDSUGainKey]; if (gain <= 0.f) gain = 1.f;
  float dead = (float)[defs floatForKey:kDSUDeadzoneKey]; if (dead < 0.f) dead = 0.f; if (dead > 0.49f) dead = 0.49f;
  float alpha = (float)[defs floatForKey:kDSUSmoothingKey]; if (alpha < 0.f) alpha = 0.f; if (alpha > 0.95f) alpha = 0.0f; // 0 = off
  s_dsuGain.store(gain, std::memory_order_relaxed);
  s_dsuDeadzone.store(dead, std::memory_order_relaxed);
  s_dsuSmoothing.store(alpha, std::memory_order_relaxed);
  s_inputDebug.store([defs boolForKey:kInputDebugKey], std::memory_order_relaxed);
}

@implementation TCManagerInterface

+ (void)initialize {
  if (self != [TCManagerInterface class]) return;
  TCRefreshInputDefaults();
  // queue:nil runs the refresh on the posting thread, before the defaults write returns.
  [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification
                                                  object:nil
                                                   queue:nil
                                              usingBlock:^(NSNotification* _Nonnull note) {
                                                TCRefreshInputDefaults();
                                              }];
}

+ (BOOL)inputDebugEnabled {
  return s_inputDebug.load(std::memory_order_relaxed);
}

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

// Dolphin's own DSU client (DualShockUDPClient.cpp) is the reference for the DSU axis convention:
//   accel (g -> m/s^2): Left = +x, Right = -x; Down = +y, Up = -y; Forward = +z, Backward = -z
//   gyro (deg/s -> rad/s): PitchUp = +pitch, PitchDown = -pitch; RollRight = +roll, RollLeft = -roll;
//                          YawRight = +yaw, YawLeft = -yaw
// The core reads IMUAccelerometer as x = Left - Right, y = Backward - Forward, z = Up - Down and
// IMUGyroscope as pitch = PitchDown - PitchUp, roll = RollLeft - RollRight, yaw = YawLeft - YawRight.
// Inverting the client therefore gives, for the core's signed vector (cx, cy, cz) and rates:
//   dsu x = cx / g, dsu y = -cz / g, dsu z = -cy / g, and every gyro component = -(core rate) in deg/s,
// so a Dolphin DSU client reproduces exactly the remote motion the game sees.
static const float kStandardGravity = 9.80665f;

+ (TCDSUMotionComponent)dsuMotionComponentForAxis:(NSInteger)axis value:(float)value {
  const float degPerRad = 180.0f / (float)M_PI;
  switch (axis) {
    case 625: return (TCDSUMotionComponent){TCDSUMotionKindAccelerometer, 0, value / kStandardGravity};  // WIIMOTE_ACCEL_LEFT
    case 628: return (TCDSUMotionComponent){TCDSUMotionKindAccelerometer, 2, -value / kStandardGravity}; // WIIMOTE_ACCEL_BACKWARD
    case 629: return (TCDSUMotionComponent){TCDSUMotionKindAccelerometer, 1, -value / kStandardGravity}; // WIIMOTE_ACCEL_UP
    case 632: return (TCDSUMotionComponent){TCDSUMotionKindGyro, 0, -value * degPerRad}; // WIIMOTE_GYRO_PITCH_DOWN
    case 635: return (TCDSUMotionComponent){TCDSUMotionKindGyro, 1, -value * degPerRad}; // WIIMOTE_GYRO_YAW_LEFT
    case 633: return (TCDSUMotionComponent){TCDSUMotionKindGyro, 2, -value * degPerRad}; // WIIMOTE_GYRO_ROLL_LEFT
    default: return (TCDSUMotionComponent){TCDSUMotionKindNone, 0, 0.0f};
  }
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

// Per-axis state shared by every writer. setAxisValueFor: runs on the main thread (touch overlay,
// physical controller handlers) AND on the device-motion queue (IMU axes, the gyro IR pointer), so
// all of it is guarded by s_axisStateLock. The lock only covers the arithmetic: the StateManager
// write (its own mutex) and every DSUServerBridge call (which can send a packet) happen after it is
// released, from copies taken under it.
static os_unfair_lock s_axisStateLock = OS_UNFAIR_LOCK_INIT;
static float s_last[4][256] = {{0}};      // [controller][axis] smoothing history (axes below 256)
static float s_splitAxes[4][256] = {{0}}; // [controller][axisIndex] last split-stick values in [-1,1]
static float s_irX = 0.0f, s_irY = 0.0f;  // last DSU IR pointer, in [-1,1]
static float s_dsuAccel[3] = {0.0f, 0.0f, 0.0f};
static float s_dsuGyro[3] = {0.0f, 0.0f, 0.0f}; // pitch, yaw, roll
static inline float clamp11(float v) { return v < -1.f ? -1.f : (v > 1.f ? 1.f : v); }

// Match TCJoystick: the negative half reports negative, the positive half positive.
static inline float TCCombineSplitAxes(float negativeValue, float positiveValue) {
  const float negativeMag = negativeValue < 0.f ? -negativeValue : 0.f; // 0..1
  const float positiveMag = positiveValue > 0.f ? positiveValue : 0.f;  // 0..1
  return clamp11(positiveMag - negativeMag);
}

+ (void)setAxisValueFor:(NSInteger)axis controller:(NSInteger)controllerId value:(float)value {
  // Apply DSU scaling parameters to analog axes before forwarding (cached; see TCRefreshInputDefaults)
  const float gain = s_dsuGain.load(std::memory_order_relaxed);
  const float dead = s_dsuDeadzone.load(std::memory_order_relaxed);
  const float alpha = s_dsuSmoothing.load(std::memory_order_relaxed);

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
    if (has_smoothing_cell) {
      os_unfair_lock_lock(&s_axisStateLock);
      if (allow_smoothing) {
        v = alpha * s_last[ci][ai] + (1.f - alpha) * v;
      }
      s_last[ci][ai] = v;
      os_unfair_lock_unlock(&s_axisStateLock);
    }
  }

  // StateManager takes its own mutex per write, shared with the core's input poll. Left as is on
  // purpose: whether that contention matters is still to be measured (System Trace) before changing it.
  ciface::iOS::StateManager::GetInstance()->SetAxisValue((int)controllerId, (ciface::iOS::ButtonType)axis, v);
  // Also forward to DSU server if running
  if (![DSUServerBridge isRunning]) return;

  // **WIIMOTE IR POINTER** - Forward IR data to DSU touch coordinates
  // Uses TCButtonType.wiiInfraredUp/Down/Left/Right indices (112-115)
  if (is_ir_axis) {
    os_unfair_lock_lock(&s_axisStateLock);
    if (axis == 112 || axis == 113) { s_irY = v; }
    if (axis == 114 || axis == 115) { s_irX = v; }
    const float ir_x = s_irX, ir_y = s_irY;
    os_unfair_lock_unlock(&s_axisStateLock);
    int touch_x = (int)((ir_x + 1.0f) * 0.5f * 1920.0f);
    int touch_y = (int)((ir_y + 1.0f) * 0.5f * 1080.0f);
    BOOL active = (fabsf(ir_x) > 0.01f || fabsf(ir_y) > 0.01f);
    [DSUServerBridge setTouchPoint:0 controller:controllerId active:active x:touch_x y:touch_y];
  }

  // Wii Remote IMU (accel 625-630, gyro 631-636) -> DSU motion. One signed value per axis, in
  // g and deg/s; see dsuMotionComponentForAxis:value:.
  const TCDSUMotionComponent motion = [self dsuMotionComponentForAxis:axis value:v];
  if (motion.kind != TCDSUMotionKindNone) {
    float sent[3];
    os_unfair_lock_lock(&s_axisStateLock);
    float* target = motion.kind == TCDSUMotionKindAccelerometer ? s_dsuAccel : s_dsuGyro;
    target[motion.index] = motion.value;
    memcpy(sent, target, sizeof(sent));
    os_unfair_lock_unlock(&s_axisStateLock);
    if (motion.kind == TCDSUMotionKindAccelerometer) {
      [DSUServerBridge setAccelerometer:controllerId x:sent[0] y:sent[1] z:sent[2]];
    } else {
      [DSUServerBridge setGyro:controllerId pitch:sent[0] yaw:sent[1] roll:sent[2]];
    }
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
  if (!is_split_stick) return;
  int upIdx, downIdx, leftIdx, rightIdx;
  if (axis >= 11 && axis <= 14) { upIdx = 11; downIdx = 12; leftIdx = 13; rightIdx = 14; }
  else if (axis >= 16 && axis <= 19) { upIdx = 16; downIdx = 17; leftIdx = 18; rightIdx = 19; }
  else { upIdx = 203; downIdx = 204; leftIdx = 205; rightIdx = 206; }

  os_unfair_lock_lock(&s_axisStateLock);
  s_splitAxes[ci][(int)axis] = clamp11(v);
  const float upValue = s_splitAxes[ci][upIdx], downValue = s_splitAxes[ci][downIdx];
  const float leftValue = s_splitAxes[ci][leftIdx], rightValue = s_splitAxes[ci][rightIdx];
  os_unfair_lock_unlock(&s_axisStateLock);

  float x = TCCombineSplitAxes(leftValue, rightValue); // right positive, left negative
  float y = TCCombineSplitAxes(upValue, downValue);    // down positive, up negative
  if (s_inputDebug.load(std::memory_order_relaxed)) {
    NSLog(@"[DSU] combLR: leftVal=%.3f rightVal=%.3f result=%.3f", leftValue, rightValue, x);
    NSLog(@"[DSU] combUD: upVal=%.3f downVal=%.3f result=%.3f", upValue, downValue, y);
  }

  if (axis >= 11 && axis <= 14) {
    // Snap small residuals to zero to avoid stickiness
    if (fabsf(x) < 0.02f) x = 0.f; if (fabsf(y) < 0.02f) y = 0.f;
    [DSUServerBridge setAxis:0 controller:controllerId value:x];
    [DSUServerBridge setAxis:1 controller:controllerId value:y];
    // Recenter guard: resend center shortly after release to overcome missed events
    if (x == 0.f && y == 0.f) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [DSUServerBridge setAxis:0 controller:controllerId value:0.f];
        [DSUServerBridge setAxis:1 controller:controllerId value:0.f];
      });
    }
  } else if (axis >= 16 && axis <= 19) {
    if (fabsf(x) < 0.02f) x = 0.f; if (fabsf(y) < 0.02f) y = 0.f;
    [DSUServerBridge setAxis:2 controller:controllerId value:x];
    [DSUServerBridge setAxis:3 controller:controllerId value:y];
    if (x == 0.f && y == 0.f) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [DSUServerBridge setAxis:2 controller:controllerId value:0.f];
        [DSUServerBridge setAxis:3 controller:controllerId value:0.f];
      });
    }
  } else {
    // Nunchuk stick - only send if there's actual input to avoid overwriting main stick
    if (fabsf(x) > 0.01f || fabsf(y) > 0.01f) {
      [DSUServerBridge setAxis:0 controller:controllerId value:x];
      [DSUServerBridge setAxis:1 controller:controllerId value:y];
    } else {
      // If both near zero, ensure main stick recenters as well
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [DSUServerBridge setAxis:0 controller:controllerId value:0.f];
        [DSUServerBridge setAxis:1 controller:controllerId value:0.f];
      });
    }
  }
}

@end
