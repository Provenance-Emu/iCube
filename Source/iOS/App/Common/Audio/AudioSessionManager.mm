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

  // Prefer movie playback mode for multichannel/HDMI routes
  [session setMode:AVAudioSessionModeMoviePlayback error:nil];

  // Request 5.1 output when available (best-effort)
  if (session.maximumOutputNumberOfChannels >= 6) {
    [session setPreferredOutputNumberOfChannels:6 error:nil];
  }

  // Activate to apply preferences
  [session setActive:YES error:nil];
}

@end
