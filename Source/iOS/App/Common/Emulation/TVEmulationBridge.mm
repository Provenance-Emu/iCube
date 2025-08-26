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

@end
