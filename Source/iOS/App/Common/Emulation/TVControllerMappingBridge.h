// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#if TARGET_OS_MACCATALYST
#import <GameController/GCController.h>
#else
#import <GameController/GameController.h>
#endif

NS_ASSUME_NONNULL_BEGIN

@interface TVControllerMappingBridge : NSObject

/// Assigns the given GCController as the default device for the specified GameCube port (1-based).
/// Also sets controller.playerIndex to (port-1) if possible.
+ (void)assignController:(GCController*)controller toGCPort:(NSInteger)portOneBased;

/// Returns the default device qualifier string for the specified GameCube port (1-based).
+ (NSString*)defaultDeviceForGCPort:(NSInteger)portOneBased;

/// Clears the default device for the specified GameCube port (1-based).
+ (void)clearDefaultDeviceForGCPort:(NSInteger)portOneBased;

/// Returns the Dolphin qualified name for the given controller, or empty string if not found.
+ (NSString*)qualifiedNameForController:(GCController*)controller;

@end

NS_ASSUME_NONNULL_END
