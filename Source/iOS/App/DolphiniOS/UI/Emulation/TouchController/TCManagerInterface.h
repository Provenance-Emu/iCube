// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TCManagerInterface : NSObject

+ (void)setButtonStateFor:(NSInteger)button controller:(NSInteger)controllerId state:(BOOL)state;
+ (void)setAxisValueFor:(NSInteger)axis controller:(NSInteger)controllerId value:(float)value;

/// Releases every button/axis for one touchscreen controller id (including the DSU
/// mirrors), for use when a touch overlay view is torn down or rebuilt so a finger
/// that was mid-press cannot leave the emulated pad stuck (audit defect #7).
+ (void)clearAllForController:(NSInteger)controllerId;

@end

NS_ASSUME_NONNULL_END
