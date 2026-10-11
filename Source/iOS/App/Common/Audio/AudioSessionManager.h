// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Owns the AVAudioSession category. Playback (or SoloAmbient when the mute switch is obeyed)
/// normally; PlayAndRecord while the core has an emulated microphone open. Call
/// `setSessionCategory` at launch and again whenever the mute-switch setting changes.
@interface AudioSessionManager : NSObject

+ (AudioSessionManager*)shared;

/// Applies the category for the current settings and microphone state, activates the session and
/// registers the core's microphone hook on first use.
- (void)setSessionCategory;

/// YES while an emulated microphone is capturing. Driven by the core through IOSAudioSession.
@property(nonatomic, readonly) BOOL microphoneActive;

@end

NS_ASSUME_NONNULL_END
