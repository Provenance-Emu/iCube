// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Live state of the running audio backend and the AVAudioEngine plug-in chain. Settings
/// themselves go through DOLConfigBridge; this only reads what the stream is doing right now.
@interface AudioFXBridge : NSObject

/// YES while the AVAudioEngine backend is the running sound stream.
+ (BOOL)isEngineActive;
/// YES while the CoreAudio backend is the running sound stream.
+ (BOOL)isCoreAudioActive;
/// "stereo", "spatial" or "discrete" for the graph the running backend built; "" when no stream.
+ (NSString*)outputModeName;
/// "HDMI:Living Room TV, BluetoothA2DP:AirPods Pro" from the session's current route.
+ (NSString*)routeDescription;
+ (NSInteger)routeMaxOutputChannels;
+ (BOOL)routeIsHeadphones;

// AVAudioEngine plug-in chain.
+ (NSArray<NSDictionary*>*)currentEffects;    /// { name, bypass, index }
+ (NSArray<NSDictionary*>*)availableEffects;  /// { name, identifier }
+ (BOOL)addEffectWithName:(NSString*)name;    /// identifier string or name substring
+ (void)removeEffectAt:(NSUInteger)index;
+ (void)moveEffectFrom:(NSUInteger)from to:(NSUInteger)to;
+ (void)setEffectAt:(NSUInteger)index bypassed:(BOOL)bypassed;
/// Persists the chain including each unit's parameters; call when a plug-in's view is dismissed.
+ (void)saveEffectChain;
+ (void)requestEffectViewControllerAt:(NSUInteger)index
                           completion:(void (^)(UIViewController* _Nullable vc))completion;

// Microphone (iOS only; tvOS reports unsupported).
+ (BOOL)microphoneSupported;
/// 0 undetermined, 1 denied, 2 granted.
+ (NSInteger)microphonePermission;
+ (void)requestMicrophonePermission:(void (^)(BOOL granted))completion;

@end

NS_ASSUME_NONNULL_END
