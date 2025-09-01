// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>

NS_ASSUME_NONNULL_BEGIN

@interface TVControllerMappingBridge : NSObject

+ (NSString*)qualifiedNameForController:(GCController*)controller NS_SWIFT_NAME(qualifiedName(for:));
+ (void)assignController:(GCController*)controller toGCPort:(NSInteger)portOneBased NS_SWIFT_NAME(assign(_:toGCPort:));
+ (NSString*)defaultDeviceForGCPort:(NSInteger)portOneBased NS_SWIFT_NAME(defaultDevice(forGCPort:));
+ (void)clearDefaultDeviceForGCPort:(NSInteger)portOneBased NS_SWIFT_NAME(clearDefaultDevice(forGCPort:));

/// Assign the iOS Touchscreen virtual device as the default device for a GC port.
+ (void)assignTouchscreenToGCPort:(NSInteger)portOneBased NS_SWIFT_NAME(assignTouchscreen(toGCPort:));

/// Reconciles default devices against currently connected controllers, removing phantom devices
/// and reassigning Player 1 to a connected controller when possible.
+ (void)reconcileAssignments;

@end

NS_ASSUME_NONNULL_END
