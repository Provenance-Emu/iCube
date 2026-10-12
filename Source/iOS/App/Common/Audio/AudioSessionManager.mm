// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "AudioSessionManager.h"

#import <AVFoundation/AVFoundation.h>

#ifndef IPHONEOS
#define IPHONEOS 1
#endif
#include "AudioCommon/IOSAudioSession.h"
#import "Core/Config/iOSSettings.h"

#import "Swift.h"

/// 10.7 ms at 48 kHz: half the callbacks of the old 5 ms request for a difference the game's own
/// 80 ms mixer buffer makes inaudible.
static const NSTimeInterval kPreferredIOBufferDuration = 512.0 / 48000.0;
static const double kPreferredSampleRate = 48000.0;

@implementation AudioSessionManager {
  id _routeChangeObserver;
  BOOL _hookRegistered;
  BOOL _microphoneActive;
}

/// "HDMI:Living Room TV, BluetoothA2DP:AirPods Pro" — the output ports the session is actually
/// using. Logged at activation and on every route change so an "I hear it on the TV, not the
/// AirPods" report can be read straight from the console.
+ (NSString*)describeRoute:(AVAudioSessionRouteDescription*)route {
  NSMutableArray<NSString*>* parts = [NSMutableArray array];
  for (AVAudioSessionPortDescription* out in route.outputs) {
    [parts addObject:[NSString stringWithFormat:@"%@:%@", out.portType, out.portName]];
  }
  return parts.count > 0 ? [parts componentsJoinedByString:@", "] : @"(none)";
}

- (void)observeRouteChangesOnce {
  if (_routeChangeObserver != nil) {
    return;
  }
  _routeChangeObserver = [[NSNotificationCenter defaultCenter]
      addObserverForName:AVAudioSessionRouteChangeNotification
                  object:[AVAudioSession sharedInstance]
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(NSNotification* note) {
                NSNumber* reason = note.userInfo[AVAudioSessionRouteChangeReasonKey];
                NSLog(@"[Audio] route changed (reason %@) -> %@", reason,
                      [AudioSessionManager describeRoute:[AVAudioSession sharedInstance].currentRoute]);
              }];
}

- (void)registerMicrophoneHookOnce
{
  if (_hookRegistered)
  {
    return;
  }
  _hookRegistered = YES;
  __weak AudioSessionManager* weakSelf = self;
  AudioCommon::IOSAudioSession::SetMicrophoneSessionHook([weakSelf](bool active) {
    AudioSessionManager* strongSelf = weakSelf;
    if (!strongSelf)
    {
      return;
    }
    strongSelf->_microphoneActive = active ? YES : NO;
    NSLog(@"[Audio] microphone %@", active ? @"opened" : @"closed");
    [strongSelf setSessionCategory];
  });
}

+ (AudioSessionManager*)shared {
  static AudioSessionManager* sharedInstance = nil;
  static dispatch_once_t onceToken;

  dispatch_once(&onceToken, ^{
    sharedInstance = [[self alloc] init];
  });

  return sharedInstance;
}

- (BOOL)microphoneActive
{
  return _microphoneActive;
}

- (void)setSessionCategory {
  [self registerMicrophoneHookOnce];
  AVAudioSession* session = [AVAudioSession sharedInstance];
  NSError* error = nil;

#if !TARGET_OS_TV
  if (_microphoneActive)
  {
    // Recording: Bluetooth stays on A2DP for output (built-in microphone for input) rather than
    // dropping to the low-quality HFP profile, and the speaker stays the default output. tvOS has
    // no app-accessible microphone, so the core never asks for this there.
    AVAudioSessionCategoryOptions options = AVAudioSessionCategoryOptionAllowBluetoothA2DP |
                                            AVAudioSessionCategoryOptionDefaultToSpeaker |
                                            AVAudioSessionCategoryOptionAllowAirPlay;
    if (![session setCategory:AVAudioSessionCategoryPlayAndRecord
                         mode:AVAudioSessionModeDefault
                      options:options
                        error:&error])
    {
      NSLog(@"[Audio] setCategory(PlayAndRecord) failed: %@", error);
    }
  }
  else
#endif
  {
    AudioMuteSwitchMode mode = (AudioMuteSwitchMode)Config::Get(Config::MAIN_MUTE_SWITCH_MODE);
    NSString* category = AVAudioSessionCategoryPlayback;
#if !TARGET_OS_TV
    if (mode == AudioMuteSwitchModeObey)
    {
      category = AVAudioSessionCategorySoloAmbient;
    }
#else
    (void)mode;
#endif
    // Playback categories route to Bluetooth and AirPlay on their own; the AllowBluetoothA2DP /
    // AllowAirPlay options are PlayAndRecord-only and tvOS rejects them.
    if (![session setCategory:category mode:AVAudioSessionModeMoviePlayback options:0 error:&error])
    {
      NSLog(@"[Audio] setCategory(%@) failed: %@", category, error);
    }
  }

  [session setPreferredSampleRate:kPreferredSampleRate error:nil];
  [session setPreferredIOBufferDuration:kPreferredIOBufferDuration error:nil];
  NSError* activateError = nil;
  if (![session setActive:YES error:&activateError]) {
    NSLog(@"[Audio] setActive failed: %@", activateError);
  }
  NSLog(@"[Audio] session category=%@ mode=%@ options=0x%lx mic=%d route=%@", session.category,
        session.mode, (unsigned long)session.categoryOptions, (int)_microphoneActive,
        [AudioSessionManager describeRoute:session.currentRoute]);
  [self observeRouteChangesOnce];
}

@end
