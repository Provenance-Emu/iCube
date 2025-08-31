// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "TVEmulationBridge.h"

#import <UIKit/UIKit.h>

#import "EmulationCoordinator.h"
#import "EmulationBootParameter.h"
#import "EmulationBootType.h"

// C++ Core host messaging
#include "Core/Host.h"
#include "Core/Core.h"
#include "Core/System.h"
#include "Core/State.h"
#include "Core/Config/MainSettings.h"
#include "VideoCommon/Present.h"
#include "VideoCommon/FramebufferManager.h"
#include "VideoCommon/PostProcessing.h"

extern std::unique_ptr<VideoCommon::Presenter> g_presenter;
extern std::unique_ptr<FramebufferManager> g_framebuffer_manager;

@implementation TVEmulationBridge

+ (void)runWithBootParameter:(EmulationBootParameter*)param {
  [[EmulationCoordinator shared] runEmulationWithBootParameter:param];
}

+ (void)stop {
  Host_Message(HostMessageID::WMUserStop);
}

+ (void)pause {
  Core::SetState(Core::System::GetInstance(), Core::State::Paused);
}

+ (void)resume {
  Core::SetState(Core::System::GetInstance(), Core::State::Running);
}

+ (BOOL)isPaused {
  return Core::GetState(Core::System::GetInstance()) == Core::State::Paused;
}

+ (void)registerMainDisplayView:(UIView*)view {
  [[EmulationCoordinator shared] registerMainDisplayView:view];
}

+ (void)launchGameAtPath:(NSString*)path {
  if (path.length == 0) return;
  EmulationBootParameter* p = [EmulationBootParameter new];
  p.bootType = EmulationBootTypeFile;
  p.path = path;
  NSString* lower = path.lowercaseString;
  p.isNKit = [lower hasSuffix:@".nkit.iso"] || [lower hasSuffix:@".nkit.gcz"] || [lower hasSuffix:@".nkit"]; // best-effort
  [[EmulationCoordinator shared] runEmulationWithBootParameter:p];
}

+ (BOOL)isRunning {
  Core::State s = Core::GetState(Core::System::GetInstance());
  return s == Core::State::Running || s == Core::State::Paused || s == Core::State::Starting;
}

+ (void)saveStateToSlot:(NSInteger)slot wait:(BOOL)wait {
  State::Save(Core::System::GetInstance(), (int)slot, wait);
}

+ (void)loadStateFromSlot:(NSInteger)slot {
  int s = (int)slot;
  Core::QueueHostJob([s](Core::System& system) {
    State::Load(system, s);
  });
}

// Display / Orientation helpers
+ (void)resizeSurfaceNow {
  if (g_presenter) {
    g_presenter->ResizeSurface();
  }
}

+ (void)reloadShadersNow {
  if (g_framebuffer_manager) {
    g_framebuffer_manager->RecompileShaders();
  }
}

// Fast-forward (temporary throttler disable)
+ (BOOL)toggleFastForward {
  const bool enableTurbo = !Core::GetIsThrottlerTempDisabled();
  Core::SetIsThrottlerTempDisabled(enableTurbo);

  if (enableTurbo) {
    if (!Config::Get(Config::MAIN_AUDIO_MUTED) &&
        Config::Get(Config::MAIN_AUDIO_MUTE_ON_DISABLED_SPEED_LIMIT)) {
      Config::SetCurrent(Config::MAIN_AUDIO_MUTED, true);
    }
  } else {
    if (Config::Get(Config::MAIN_AUDIO_MUTED) &&
        Config::GetActiveLayerForConfig(Config::MAIN_AUDIO_MUTED) == Config::LayerType::CurrentRun) {
      Config::DeleteKey(Config::LayerType::CurrentRun, Config::MAIN_AUDIO_MUTED);
    }
  }

  const BOOL enabled = Core::GetIsThrottlerTempDisabled() ? YES : NO;
  dispatch_async(dispatch_get_main_queue(), ^{
    [[NSNotificationCenter defaultCenter] postNotificationName:@"DOLFastForwardToggled" object:nil userInfo:@{ @"enabled": @(enabled) }];
  });
  return enabled;
}

+ (BOOL)isFastForwardEnabled {
  return Core::GetIsThrottlerTempDisabled();
}

@end
