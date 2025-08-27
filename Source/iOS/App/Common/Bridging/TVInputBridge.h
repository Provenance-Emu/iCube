// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TVInputBridge : NSObject
/// Enable/disable the Wiimote IMUPoint control group for a given Wiimote index (0-based)
+ (void)setWiimoteIMUPointEnabled:(BOOL)enabled forPort:(int)port;
@end

NS_ASSUME_NONNULL_END
