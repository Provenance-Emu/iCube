// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

@class EmulationBootParameter;
@class UIView;

NS_ASSUME_NONNULL_BEGIN

@interface TVEmulationBridge : NSObject

+ (void)runWithBootParameter:(EmulationBootParameter*)param;
+ (void)stop;
+ (BOOL)isRunning;
+ (void)pause;
+ (void)resume;
+ (BOOL)isPaused;

// Convenience wrappers for Swift
// Launch a game file at path; sensible defaults applied.
// Path should point to a GameCube/Wii image supported by Dolphin.
// Returns immediately; emulation runs on background thread.
+ (void)launchGameAtPath:(NSString*)path;
// Register the main display UIView that will host the Metal surface.
+ (void)registerMainDisplayView:(UIView*)view;

// Savestates
+ (void)saveStateToSlot:(NSInteger)slot wait:(BOOL)wait;
+ (void)loadStateFromSlot:(NSInteger)slot;

// Speed / Fast-forward
// Toggle temporary throttler disable (turbo). Returns the new state.
// Display / Orientation
+ (void)resizeSurfaceNow;
+ (void)reloadShadersNow;
// Speed / Fast-forward
// Toggle temporary throttler disable (turbo). Returns the new state.
+ (BOOL)toggleFastForward;
+ (BOOL)isFastForwardEnabled;

// System Detection
+ (BOOL)isCurrentSystemWii;
+ (float)currentDrawAspectRatio;
+ (void)setWiiIMUPointEnabled:(BOOL)enabled;

// Video Geometry
// Returns the current video content rect in the coordinate space of the registered main display view.
+ (CGRect)currentVideoContentRect;

@end

NS_ASSUME_NONNULL_END
