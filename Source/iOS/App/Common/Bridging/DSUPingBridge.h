// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Lightweight DSU (Cemuhook UDP) ping utility.
/// Uses Dolphin's DualShockUDP proto to send a VersionRequest and waits for VersionResponse.
@interface DSUPingBridge : NSObject

+ (void)pingServerAddress:(NSString *)address
                     port:(NSInteger)port
                  timeout:(NSTimeInterval)timeout
               completion:(void(^)(BOOL ok, NSString * _Nullable info))completion;

@end

NS_ASSUME_NONNULL_END
