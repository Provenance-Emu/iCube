// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "AudioSessionManager.h"

#import <AVFoundation/AVFoundation.h>

#import "Core/Config/iOSSettings.h"

#import "Swift.h"

@implementation AudioSessionManager {
  id _routeChangeObserver;
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
  // tvOS uses playback only. The error used to be ignored here with no fallback: if the OS rejects
  // one of the options the session silently stays in its default (ambient) category, and an ambient
  // session is not what the user's AirPods / AirPlay output selection applies to. Retry like iOS.
  if (![session setCategory:AVAudioSessionCategoryPlayback withOptions:options error:&error]) {
    NSLog(@"[Audio] setCategory(Playback, options 0x%lx) failed: %@ — retrying without options",
          (unsigned long)options, error);
    error = nil;
    [session setCategory:AVAudioSessionCategoryPlayback error:&error];
  }
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

  if (error) {
    NSLog(@"[Audio] setCategory failed: %@", error);
  }
  [session setPreferredSampleRate:48000 error:nil];
  [session setPreferredIOBufferDuration:0.005 error:nil];
  NSError* activateError = nil;
  if (![session setActive:YES error:&activateError]) {
    NSLog(@"[Audio] setActive failed: %@", activateError);
  }
  NSLog(@"[Audio] session category=%@ mode=%@ options=0x%lx route=%@",
        session.category, session.mode, (unsigned long)session.categoryOptions,
        [AudioSessionManager describeRoute:session.currentRoute]);
  [self observeRouteChangesOnce];

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
