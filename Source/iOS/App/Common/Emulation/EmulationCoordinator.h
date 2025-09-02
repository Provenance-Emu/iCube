// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

@class EmulationBootParameter;
@class UIView;

NSString* _Nonnull const DOLEmulationDidStartNotification = @"DOLEmulationDidStartNotification";
NSString* _Nonnull const DOLEmulationDidEndNotification = @"DOLEmulationDidEndNotification";

NS_ASSUME_NONNULL_BEGIN

@interface EmulationCoordinator : NSObject

+ (EmulationCoordinator*)shared;

@property (nonatomic, setter=setIsExternalDisplayConnected:) bool isExternalDisplayConnected;
@property (nonatomic) bool userRequestedPause;

- (void)registerMainDisplayView:(UIView*)mainView;
- (void)registerExternalDisplayView:(UIView*)externalView;
- (void)runEmulationWithBootParameter:(EmulationBootParameter*)bootParameter;
- (void)clearMetalLayer;

/// Ensures GameCube Pad 1 is bound to the iOS Touchscreen when no default device is connected.
/// Also provides auto-assignment for newly connected external controllers.
+ (void)ensurePad1DefaultsToTouchscreen;
/// Assign the most recently connected external controller to the first available player slot
/// that is not already bound to a connected physical controller (ignores touchscreen bindings).
+ (void)autoAssignNewestExternalControllerToFirstAvailableSlot;

// Ensure a given Wiimote port (1-based) is set to Emulated and uses the iOS Touchscreen profile
+ (void)ensureWiimoteDefaultsToTouchscreenForPort:(NSInteger)portOneBased;

@end

NS_ASSUME_NONNULL_END
