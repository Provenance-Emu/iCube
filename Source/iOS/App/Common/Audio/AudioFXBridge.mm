// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "AudioFXBridge.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#if !TARGET_OS_TV
#import <CoreAudioKit/CoreAudioKit.h>
#endif

// The engine headers are guarded on the core's platform define.
#ifndef IPHONEOS
#define IPHONEOS 1
#endif
#include "AudioCommon/AVAudioEngineSoundStream.h"
#include "AudioCommon/AudioCommon.h"
#include "AudioCommon/CoreAudioSoundStream.h"
#include "AudioCommon/IOSAudioInput.h"
#include "AudioCommon/IOSAudioSession.h"
#include "Core/System.h"

static inline AVAudioEngineSound* ActiveEngine()
{
  return dynamic_cast<AVAudioEngineSound*>(Core::System::GetInstance().GetSoundStream());
}

static inline CoreAudioSound* ActiveCoreAudio()
{
  return dynamic_cast<CoreAudioSound*>(Core::System::GetInstance().GetSoundStream());
}

@implementation AudioFXBridge

+ (BOOL)isEngineActive
{
  return ActiveEngine() != nullptr;
}

+ (BOOL)isCoreAudioActive
{
  return ActiveCoreAudio() != nullptr;
}

+ (NSString*)outputModeName
{
  if (AVAudioEngineSound* engine = ActiveEngine())
  {
    switch (engine->GetMode())
    {
    case AVAudioEngineSound::Mode::Stereo:
      return @"stereo";
    case AVAudioEngineSound::Mode::Spatial:
      return @"spatial";
    case AVAudioEngineSound::Mode::Discrete51:
      return @"discrete";
    }
  }
  if (CoreAudioSound* core = ActiveCoreAudio())
    return core->IsSurroundOutput() ? @"discrete" : @"stereo";
  return @"";
}

+ (NSString*)routeDescription
{
  return [NSString
      stringWithUTF8String:AudioCommon::IOSAudioSession::QueryRoute().description.c_str()];
}

+ (NSInteger)routeMaxOutputChannels
{
  return AudioCommon::IOSAudioSession::QueryRoute().max_output_channels;
}

+ (BOOL)routeIsHeadphones
{
  return AudioCommon::IOSAudioSession::QueryRoute().headphones;
}

// MARK: - Plug-in chain

+ (NSArray<NSDictionary*>*)currentEffects
{
  AVAudioEngineSound* eng = ActiveEngine();
  if (!eng)
    return @[];
  NSMutableArray* arr = [NSMutableArray array];
  const size_t n = eng->fxCount();
  for (size_t i = 0; i < n; ++i)
  {
    AVAudioUnit* u = eng->fxAt(i);
    if (!u)
      continue;
    [arr addObject:@{
      @"name" : u.name ?: @"Effect",
      @"bypass" : @(u.AUAudioUnit.shouldBypassEffect),
      @"index" : @(i)
    }];
  }
  return arr;
}

+ (NSArray<NSDictionary*>*)availableEffects
{
  NSMutableArray<NSDictionary*>* out = [NSMutableArray array];
  AVAudioUnitComponentManager* mgr = [AVAudioUnitComponentManager sharedAudioUnitComponentManager];
  AudioComponentDescription desc{};
  desc.componentType = kAudioUnitType_Effect;
  for (AVAudioUnitComponent* c in [mgr componentsMatchingDescription:desc])
  {
    const AudioComponentDescription acd = c.audioComponentDescription;
    NSString* ident = [NSString
        stringWithFormat:@"type:%u sub:%u manu:%u", (unsigned)acd.componentType,
                         (unsigned)acd.componentSubType, (unsigned)acd.componentManufacturer];
    [out addObject:@{@"name" : c.name ?: @"Effect", @"identifier" : ident}];
  }
  return out;
}

+ (BOOL)addEffectWithName:(NSString*)name
{
  AVAudioEngineSound* eng = ActiveEngine();
  if (!eng)
    return NO;
  return eng->addEffectWithIdentifier(name.UTF8String) ? YES : NO;
}

+ (void)removeEffectAt:(NSUInteger)index
{
  if (AVAudioEngineSound* eng = ActiveEngine())
    eng->removeEffectAt(index);
}

+ (void)moveEffectFrom:(NSUInteger)from to:(NSUInteger)to
{
  if (AVAudioEngineSound* eng = ActiveEngine())
    eng->moveEffect(from, to);
}

+ (void)setEffectAt:(NSUInteger)index bypassed:(BOOL)bypassed
{
  if (AVAudioEngineSound* eng = ActiveEngine())
    eng->setEffectBypass(index, bypassed);
}

+ (void)saveEffectChain
{
  if (AVAudioEngineSound* eng = ActiveEngine())
    eng->saveEffectChain();
}

+ (void)requestEffectViewControllerAt:(NSUInteger)index
                           completion:(void (^)(UIViewController* _Nullable vc))completion
{
  AVAudioEngineSound* eng = ActiveEngine();
  AVAudioUnit* u = eng ? eng->fxAt(index) : nil;
  if (!u)
  {
    completion(nil);
    return;
  }
#if !TARGET_OS_TV
  [u.AUAudioUnit requestViewControllerWithCompletionHandler:^(UIViewController* _Nullable vc) {
    completion(vc);
  }];
#else
  completion(nil);
#endif
}

// MARK: - Microphone

+ (BOOL)microphoneSupported
{
  return IOSAudioInput::IsSupported();
}

+ (NSInteger)microphonePermission
{
  switch (IOSAudioInput::GetPermission())
  {
  case IOSAudioInput::Permission::Undetermined:
    return 0;
  case IOSAudioInput::Permission::Denied:
    return 1;
  case IOSAudioInput::Permission::Granted:
    return 2;
  }
  return 0;
}

+ (void)requestMicrophonePermission:(void (^)(BOOL granted))completion
{
  IOSAudioInput::RequestPermission([completion](bool granted) {
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(granted);
    });
  });
}

@end
