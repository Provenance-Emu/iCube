// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, IOControlID) {
	IOControlGCPadA = 0,
	IOControlGCPadB = 1,
	IOControlGCPadX = 2,
	IOControlGCPadY = 3,
	IOControlGCPadZ = 4,
	IOControlGCPadStart = 5,
	IOControlGCPadDpadUp = 6,
	IOControlGCPadDpadDown = 7,
	IOControlGCPadDpadLeft = 8,
	IOControlGCPadDpadRight = 9,
	IOControlGCPadLDigital = 10,
	IOControlGCPadRDigital = 11,
	IOControlGCPadLAnalog = 12,
	IOControlGCPadRAnalog = 13,
	IOControlGCPadMainStickX = 14,
	IOControlGCPadMainStickY = 15,
	IOControlGCPadCStickX = 16,
	IOControlGCPadCStickY = 17,
};

@interface InputOverriderBridge : NSObject

+ (void)registerGameCubeOverrideForController:(NSInteger)index;
+ (void)unregisterGameCubeOverrideForController:(NSInteger)index;
+ (void)setControl:(IOControlID)control controller:(NSInteger)index value:(double)value;
+ (void)clearControl:(IOControlID)control controller:(NSInteger)index;

@end

NS_ASSUME_NONNULL_END
