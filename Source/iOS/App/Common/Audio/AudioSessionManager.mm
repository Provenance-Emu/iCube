// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "AudioSessionManager.h"

#import <AVFoundation/AVFoundation.h>

#import "Core/Config/iOSSettings.h"

#import "Swift.h"

@implementation AudioSessionManager

+ (AudioSessionManager*)shared {
  static AudioSessionManager* sharedInstance = nil;
  static dispatch_once_t onceToken;

  dispatch_once(&onceToken, ^{
    sharedInstance = [[self alloc] init];
  });

  return sharedInstance;
}

- (void)setSessionCategory {
  AVAudioSession* session = [AVAudioSession sharedInstance];

  AudioMuteSwitchMode mode = (AudioMuteSwitchMode)Config::Get(Config::MAIN_MUTE_SWITCH_MODE);

  NSError* error = nil;
  AVAudioSessionCategoryOptions options = AVAudioSessionCategoryOptionAllowBluetoothA2DP | AVAudioSessionCategoryOptionAllowAirPlay;

#if TARGET_OS_TV
  // tvOS uses playback only
  [session setCategory:AVAudioSessionCategoryPlayback withOptions:options error:&error];
  [session setMode:AVAudioSessionModeMoviePlayback error:nil];
#else
  if (mode == AudioMuteSwitchModeObey) {
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 100000
    [session setCategory:AVAudioSessionCategorySoloAmbient withOptions:options error:&error];
#else
    [session setCategory:AVAudioSessionCategorySoloAmbient error:&error];
#endif
  } else {
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 100000
    [session setCategory:AVAudioSessionCategoryPlayback withOptions:options error:&error];
#else
    [session setCategory:AVAudioSessionCategoryPlayback error:&error];
#endif
  }
  [session setMode:AVAudioSessionModeMoviePlayback error:nil];
#endif

  [session setPreferredSampleRate:48000 error:nil];
  [session setPreferredIOBufferDuration:0.005 error:nil];
  [session setActive:YES error:nil];

#if TARGET_OS_TV
  // Advisory: post a notification to suggest backend based on route
  AVAudioSessionRouteDescription* route = session.currentRoute;
  BOOL hasHDMI = NO; BOOL headphones = NO;
  for (AVAudioSessionPortDescription* out in route.outputs) {
    if ([out.portType isEqualToString:AVAudioSessionPortHDMI]) hasHDMI = YES;
    if ([out.portType isEqualToString:AVAudioSessionPortHeadphones]) headphones = YES;
  }
  NSString* backend = hasHDMI ? @"CoreAudio" : @"AVAudioEngine";
  NSDictionary* info = @{ @"backend": backend };
  [[NSNotificationCenter defaultCenter] postNotificationName:@"DOLSuggestAudioBackend" object:nil userInfo:info];
#endif
}

@end
