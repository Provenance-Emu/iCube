// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Which kind of DSU motion field a Wii Remote IMU axis write feeds.
typedef NS_ENUM(NSInteger, TCDSUMotionKind) {
  TCDSUMotionKindNone = 0,
  /// `index` 0/1/2 = DSU accelerometer x/y/z, `value` in g.
  TCDSUMotionKindAccelerometer,
  /// `index` 0/1/2 = DSU gyro pitch/yaw/roll, `value` in degrees per second.
  TCDSUMotionKindGyro,
};

typedef struct {
  TCDSUMotionKind kind;
  NSInteger index;
  float value;
} TCDSUMotionComponent;

@interface TCManagerInterface : NSObject

+ (void)setButtonStateFor:(NSInteger)button controller:(NSInteger)controllerId state:(BOOL)state;
+ (void)setAxisValueFor:(NSInteger)axis controller:(NSInteger)controllerId value:(float)value;
/// The value the core will read for `axis` after setAxisValueFor:'s processing (test seam;
/// 0 for an axis that has never been written).
+ (float)axisValueFor:(NSInteger)axis controller:(NSInteger)controllerId;

/// Maps one Wii Remote IMU axis write (accel ids 625-630 in m/s^2, gyro ids 631-636 in rad/s) to
/// the DSU (cemuhook) motion component it feeds, in the units and axis convention DSU clients
/// expect (accel in g, gyro in deg/s). The IMU writers put the SAME signed value on both halves of
/// each pair and the core reads `positive half - negative half`, so only one half per axis
/// (accel Left/Backward/Up, gyro PitchDown/RollLeft/YawLeft) is the signed value; every other
/// half returns `TCDSUMotionKindNone`. That keeps the forwarded sign independent of write order.
+ (TCDSUMotionComponent)dsuMotionComponentForAxis:(NSInteger)axis value:(float)value;

/// Releases every button/axis for one touchscreen controller id (including the DSU
/// mirrors), for use when a touch overlay view is torn down or rebuilt so a finger
/// that was mid-press cannot leave the emulated pad stuck (audit defect #7).
+ (void)clearAllForController:(NSInteger)controllerId;

/// The `input_debug` user default, cached (refreshed whenever a user default changes) so per-sample
/// input paths can gate their logging without reading NSUserDefaults each time.
@property(class, readonly) BOOL inputDebugEnabled;

@end

NS_ASSUME_NONNULL_END
