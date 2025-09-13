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

/// Receiver connection status (best-effort)
+ (BOOL)hasClient;
+ (NSString *)lastClientAddress; // empty if none seen yet
/// List of recently seen clients (address:port), newest first
+ (NSArray<NSString *> *)clients;
/// Restrict sending to a specific client (address:port). Pass nil/empty to allow all.
+ (void)setRestrictToClient:(NSString * _Nullable)addr;
+ (NSString * _Nullable)restrictedClient;

/// Send a frame immediately to the last client (if any)
+ (void)sendNow;

/// Approval/allowlist control
+ (void)setApprovalRequired:(BOOL)required;
+ (BOOL)approvalRequired;
+ (NSSet<NSString *> *)allowedClients;
+ (void)setClient:(NSString *)addr allowed:(BOOL)allowed;
+ (BOOL)isClientAllowed:(NSString *)addr;

/// Input updates from the touch controller (or other sources)
+ (void)setButton:(NSInteger)button controller:(NSInteger)controller state:(BOOL)state;
+ (void)setAxis:(NSInteger)axis controller:(NSInteger)controller value:(float)value;

/// D-Pad helpers (255 when pressed, 0 when released)
+ (void)setDPadUpForController:(NSInteger)controller state:(BOOL)state;
+ (void)setDPadDownForController:(NSInteger)controller state:(BOOL)state;
+ (void)setDPadLeftForController:(NSInteger)controller state:(BOOL)state;
+ (void)setDPadRightForController:(NSInteger)controller state:(BOOL)state;

/// Layout metadata for Bonjour TXT record
+ (void)setLayout:(NSString *)layout extension:(NSString * _Nullable)ext sideways:(BOOL)sideways;

/// Shoulders (L1/R1) as analog (255/0)
+ (void)setShoulderL:(NSInteger)controller state:(BOOL)state;
+ (void)setShoulderR:(NSInteger)controller state:(BOOL)state;

/// Special buttons
+ (void)setShare:(NSInteger)controller state:(BOOL)state;
+ (void)setOptions:(NSInteger)controller state:(BOOL)state;
+ (void)setPS:(NSInteger)controller state:(BOOL)state;
+ (void)setTouch:(NSInteger)controller state:(BOOL)state;

/// Touch points (DSU supports 2 touch points with X/Y coordinates)
/// Coordinates are in range [0, 1920] x [0, 1080] (DS4 touchpad resolution)
+ (void)setTouchPoint:(NSInteger)touchId controller:(NSInteger)controller active:(BOOL)active x:(NSInteger)x y:(NSInteger)y;
@end

NS_ASSUME_NONNULL_END
