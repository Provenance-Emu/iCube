// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioFXBridge : NSObject
+ (BOOL)isEngineActive;/// Returns YES if AVAudioEngine backend is active
+ (NSArray<NSDictionary*>*)currentEffects;/// Each dict: { name: String, bypass: NSNumber(BOOL), index: NSNumber }
+ (NSArray<NSDictionary*>*)availableEffects;/// Each dict: { name: String, identifier: String }
+ (BOOL)addEffectWithName:(NSString*)name;/// Adds first matching AUv3 effect by name (contains match)
+ (void)removeEffectAt:(NSUInteger)index;
+ (void)moveEffectFrom:(NSUInteger)from to:(NSUInteger)to;
+ (void)setEffectAt:(NSUInteger)index bypassed:(BOOL)bypassed;
+ (void)requestEffectViewControllerAt:(NSUInteger)index completion:(void(^)(UIViewController* _Nullable vc))completion;/// Returns nil if unavailable

/// CoreAudio backend (RemoteIO) built-in DSP controls
+ (BOOL)isCoreAudioActive;
+ (void)setCADelayEnabled:(BOOL)enabled;
+ (void)setCADelayMs:(NSInteger)ms;
+ (void)setCADelayFeedback:(double)fb;
+ (void)setCABitcrushEnabled:(BOOL)enabled;
+ (void)setCABitcrushBits:(NSInteger)bits;
+ (void)setCABitcrushDownsample:(NSInteger)factor;
+ (void)setCAEQEnabled:(BOOL)enabled;
+ (void)setCAEQLowGainDb:(double)db;
+ (void)setCAEQMidGainDb:(double)db;
+ (void)setCAEQHighGainDb:(double)db;
+ (NSDictionary*)coreAudioDSPState;/// Returns current CoreAudio DSP parameters for UI sync
@end

NS_ASSUME_NONNULL_END
