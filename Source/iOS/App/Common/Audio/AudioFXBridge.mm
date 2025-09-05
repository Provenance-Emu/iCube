// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "AudioFXBridge.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudioTypes.h>
#import <AudioUnit/AudioUnit.h>
#if !TARGET_OS_TV
#import <CoreAudioKit/CoreAudioKit.h>
#endif

// Ensure iOS guard is enabled for the engine header when building in the app target
#ifndef IPHONEOS
#define IPHONEOS 1
#endif
#include "AudioCommon/AVAudioEngineSoundStream.h"
#include "AudioCommon/AudioCommon.h"
#include "AudioCommon/CoreAudioSoundStream.h"
#include "Core/System.h"

static inline AVAudioEngineSound* ActiveEngine()
{
  Core::System& sys = Core::System::GetInstance();
  SoundStream* ss = sys.GetSoundStream();
  return dynamic_cast<AVAudioEngineSound*>(ss);
}

@implementation AudioFXBridge

+ (BOOL)isEngineActive {
  return ActiveEngine() != nullptr;
}

+ (NSArray<NSDictionary*>*)currentEffects {
  AVAudioEngineSound* eng = ActiveEngine();
  if (!eng) return @[];
  NSMutableArray* arr = [NSMutableArray array];
  const size_t n = eng->fxCount();
  for (size_t i = 0; i < n; ++i) {
    AVAudioUnitEffect* u = (AVAudioUnitEffect*)eng->fxAt(i);
    NSString* name = u.name ?: @"Effect";
    [arr addObject:@{ @"name": name, @"bypass": @(u.bypass), @"index": @(i) }];
  }
  return arr;
}

+ (NSArray<NSDictionary*>*)availableEffects {
  NSMutableArray<NSDictionary*>* out = [NSMutableArray array];
  AVAudioUnitComponentManager* mgr = [AVAudioUnitComponentManager sharedAudioUnitComponentManager];
  // Effect types only
  AudioComponentDescription desc; memset(&desc, 0, sizeof(desc));
  desc.componentType = kAudioUnitType_Effect;
  NSArray<AVAudioUnitComponent*>* comps = [mgr componentsMatchingDescription:desc];
  for (AVAudioUnitComponent* c in comps) {
    NSString* name = c.name ?: @"Effect";
    // Build a stable identifier string from the AudioComponentDescription tuple
    AudioComponentDescription acd = c.audioComponentDescription;
    NSString* ident = [NSString stringWithFormat:@"type:%u sub:%u manu:%u", acd.componentType, acd.componentSubType, acd.componentManufacturer];
    [out addObject:@{ @"name": name, @"identifier": ident }];
  }
  return out;
}

+ (BOOL)addEffectWithName:(NSString*)name {
  AVAudioEngineSound* eng = ActiveEngine();
  NSLog(@"[FX/Bridge] addEffect name/ident=%@ engine=%p", name, eng);
  if (!eng) return NO;
  const bool ok = eng->addEffectWithIdentifier(name.UTF8String);
  NSLog(@"[FX/Bridge] addEffect result=%d", ok);
  return ok ? YES : NO;
}

+ (void)removeEffectAt:(NSUInteger)index {
  AVAudioEngineSound* eng = ActiveEngine();
  if (!eng) return;
  eng->removeEffectAt(index);
}

+ (void)moveEffectFrom:(NSUInteger)from to:(NSUInteger)to {
  AVAudioEngineSound* eng = ActiveEngine();
  if (!eng) return;
  eng->moveEffect(from, to);
}

+ (void)setEffectAt:(NSUInteger)index bypassed:(BOOL)bypassed {
  AVAudioEngineSound* eng = ActiveEngine();
  if (!eng) return;
  eng->setEffectBypass(index, bypassed);
}

+ (void)requestEffectViewControllerAt:(NSUInteger)index completion:(void(^)(UIViewController* _Nullable vc))completion {
  AVAudioEngineSound* eng = ActiveEngine();
  NSLog(@"[FX/Bridge] requestEffectVC index=%lu engine=%p", (unsigned long)index, eng);
  if (!eng) { completion(nil); return; }
  AVAudioUnitEffect* u = (AVAudioUnitEffect*)eng->fxAt(index);
  if (!u) { NSLog(@"[FX/Bridge] requestEffectVC: no unit at index"); completion(nil); return; }
#if !TARGET_OS_TV
  if (@available(iOS 9.0, *)) {
    [u.AUAudioUnit requestViewControllerWithCompletionHandler:^(UIViewController * _Nullable viewController) {
      NSLog(@"[FX/Bridge] requestEffectVC completion: vc=%@", viewController);
      completion(viewController);
    }];
  } else {
    completion(nil);
  }
#else
  completion(nil);
#endif
}

// MARK: - CoreAudio (RemoteIO) built-in DSP controls
+ (BOOL)isCoreAudioActive {
  Core::System& sys = Core::System::GetInstance();
  SoundStream* ss = sys.GetSoundStream();
  return dynamic_cast<CoreAudioSound*>(ss) != nullptr;
}

+ (void)setCADelayEnabled:(BOOL)enabled {
  Core::System& sys = Core::System::GetInstance();
  if (auto* ca = dynamic_cast<CoreAudioSound*>(sys.GetSoundStream())) ca->setDelayEnabled(enabled);
}
+ (void)setCADelayMs:(NSInteger)ms {
  Core::System& sys = Core::System::GetInstance();
  if (auto* ca = dynamic_cast<CoreAudioSound*>(sys.GetSoundStream())) ca->setDelayMs((int)ms);
}
+ (void)setCADelayFeedback:(double)fb {
  Core::System& sys = Core::System::GetInstance();
  if (auto* ca = dynamic_cast<CoreAudioSound*>(sys.GetSoundStream())) ca->setDelayFeedback((float)fb);
}
+ (void)setCABitcrushEnabled:(BOOL)enabled {
  Core::System& sys = Core::System::GetInstance();
  if (auto* ca = dynamic_cast<CoreAudioSound*>(sys.GetSoundStream())) ca->setBitcrushEnabled(enabled);
}
+ (void)setCABitcrushBits:(NSInteger)bits {
  Core::System& sys = Core::System::GetInstance();
  if (auto* ca = dynamic_cast<CoreAudioSound*>(sys.GetSoundStream())) ca->setBitcrushBits((int)bits);
}
+ (void)setCABitcrushDownsample:(NSInteger)factor {
  Core::System& sys = Core::System::GetInstance();
  if (auto* ca = dynamic_cast<CoreAudioSound*>(sys.GetSoundStream())) ca->setBitcrushDownsample((int)factor);
}
+ (void)setCAEQEnabled:(BOOL)enabled {
  Core::System& sys = Core::System::GetInstance();
  if (auto* ca = dynamic_cast<CoreAudioSound*>(sys.GetSoundStream())) ca->setEQEnabled(enabled);
}
+ (void)setCAEQLowGainDb:(double)db {
  Core::System& sys = Core::System::GetInstance();
  if (auto* ca = dynamic_cast<CoreAudioSound*>(sys.GetSoundStream())) ca->setEQLowGainDb((float)db);
}
+ (void)setCAEQMidGainDb:(double)db {
  Core::System& sys = Core::System::GetInstance();
  if (auto* ca = dynamic_cast<CoreAudioSound*>(sys.GetSoundStream())) ca->setEQMidGainDb((float)db);
}
+ (void)setCAEQHighGainDb:(double)db {
  Core::System& sys = Core::System::GetInstance();
  if (auto* ca = dynamic_cast<CoreAudioSound*>(sys.GetSoundStream())) ca->setEQHighGainDb((float)db);
}

+ (NSDictionary*)coreAudioDSPState {
  Core::System& sys = Core::System::GetInstance();
  if (auto* ca = dynamic_cast<CoreAudioSound*>(sys.GetSoundStream())) {
    return @{ @"delayEnabled": @(ca->getDelayEnabled()),
              @"delayMs": @(ca->getDelayMs()),
              @"delayFeedback": @(ca->getDelayFeedback()),
              @"crushEnabled": @(ca->getBitcrushEnabled()),
              @"crushBits": @(ca->getBitcrushBits()),
              @"crushDown": @(ca->getBitcrushDownsample()),
              @"eqEnabled": @(ca->getEQEnabled()),
              @"low": @(ca->getEQLowGainDb()),
              @"mid": @(ca->getEQMidGainDb()),
              @"high": @(ca->getEQHighGainDb()) };
  }
  return @{};
}
@end
