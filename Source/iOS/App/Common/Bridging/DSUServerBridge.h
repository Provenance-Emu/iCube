// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Simple ObjC++ bridge that hosts a DSU (Cemuhook DualShock UDP) server.
/// It serves controller and motion data to DSU clients (e.g., Dolphin DSU client).
///
/// Notes:
/// - This implementation currently supports a single logical pad (pad_id 0).
/// - Bonjour advertisement is published under _dolphin-dsu._udp.
@interface DSUServerBridge : NSObject

+ (instancetype)shared;

/// Start the DSU server on the given UDP port (default 26760).
+ (BOOL)startOnPort:(NSInteger)port NS_SWIFT_NAME(start(onPort:)); // returns NO on bind/failure
+ (void)stop;
+ (BOOL)isRunning;
+ (NSInteger)port;

/// Error of last start attempt (nil or empty on success)
+ (NSString *)lastError;

/// Lightweight counters for troubleshooting
+ (NSUInteger)txCount;
+ (NSUInteger)rxCount;

/// Returns best-effort LAN IPv4 address (for display/QR).
+ (NSString *)ipAddress;

/// Input updates from the touch controller (or other sources)
+ (void)setButton:(NSInteger)button controller:(NSInteger)controller state:(BOOL)state;
+ (void)setAxis:(NSInteger)axis controller:(NSInteger)controller value:(float)value;

@end

NS_ASSUME_NONNULL_END
