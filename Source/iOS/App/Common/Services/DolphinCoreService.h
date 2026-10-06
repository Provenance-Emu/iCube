// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DolphinCoreService : UIResponder <UIApplicationDelegate>

/// The launch defaults: writes each to the Base layer only where Base has no value yet, so a key
/// the user set (or SettingsRepair left) is never overwritten. Runs at launch after SettingsRepair.
+ (void)seedLaunchDefaultsWithFastmemAvailable:(BOOL)fastmemAvailable
    NS_SWIFT_NAME(seedLaunchDefaults(fastmemAvailable:));

@end

NS_ASSUME_NONNULL_END
