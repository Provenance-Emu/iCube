// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "TVLibraryBridge.h"
#import <TargetConditionals.h>

#import "GameFileCacheManager.h"
#import "GameFilePtrWrapper.h"
#import "TVGameItem.h"
#import "Core/Core.h"
#import "Core/System.h"
#import "UICommon/UICommon.h"
#import "EmulationCoordinator.h"
#include "Core/BootManager.h"
#include "Core/Boot/Boot.h"
#include "DiscIO/Enums.h"
#import "EmulationBootParameter.h"
#import "EmulationBootType.h"
#import "WiiSystemUpdateViewController.h"
#import "TVWiiSystemUpdateViewController.h"

@implementation TVLibraryBridge

+ (NSArray<TVGameItem*>*)currentGames {
  return [[GameFileCacheManager sharedManager] currentGames];
}

+ (void)rescanAndFetchMetadataWithCompletion:(void(^)(void))completion {
  [[GameFileCacheManager sharedManager] rescanAndFetchMetadataWithCompletionHandler:^{
    if (completion) completion();
  }];
}

+ (void)rescanLocalAndFetchMetadata:(void(^)(void))completion {
  [[GameFileCacheManager sharedManager] rescanLocalAndFetchMetadataWithCompletionHandler:^{
    if (completion) completion();
  }];
}

+ (void)loadGameCubeMainMenu {
  EmulationBootParameter* p = [EmulationBootParameter new];
  p.bootType = EmulationBootTypeGCIPL;
  p.iplRegion = DiscIO::Region::NTSC_U;
  [[EmulationCoordinator shared] runEmulationWithBootParameter:p];
}

+ (void)presentUpdateControllerWithRegion:(NSString*)regionCode {
  UIViewController* root = UIApplication.sharedApplication.keyWindow.rootViewController;
  if (!root) return;

  // Prefer the unified TVWiiSystemUpdateViewController on all platforms
  if ([TVWiiSystemUpdateViewController class]) {
    TVWiiSystemUpdateViewController* vc = [TVWiiSystemUpdateViewController new];
    if (regionCode.length > 0) { vc.updateSource = regionCode; }
    vc.isOnlineUpdate = YES;
    [root presentViewController:vc animated:YES completion:nil];
    return;
  }

  // Fallback (older iOS builds): storyboard-based updater
  @try {
    UIStoryboard* sb = [UIStoryboard storyboardWithName:@"WiiSystemUpdate" bundle:nil];
    if (sb) {
      UIViewController* vc = (UIViewController*)[sb instantiateInitialViewController];
      if (vc) {
        if (regionCode.length > 0 && [vc respondsToSelector:@selector(setUpdateSource:)]) {
          [vc setValue:regionCode forKey:@"updateSource"];
        }
        if ([vc respondsToSelector:@selector(setIsOnlineUpdate:)]) {
          [vc setValue:@(YES) forKey:@"isOnlineUpdate"];
        }
        [root presentViewController:vc animated:YES completion:nil];
        return;
      }
    }
  } @catch (...) {
  }
}

+ (void)performOnlineSystemUpdate {
  [self presentUpdateControllerWithRegion:nil];
}

+ (void)performOnlineSystemUpdateWithRegion:(NSString*)regionCode {
  [self presentUpdateControllerWithRegion:regionCode];
}

+ (void)updateLibraryWithRemotePaths:(NSArray<NSString*>*)paths fetchMetadata:(BOOL)fetch {
  printf("DEBUG BRIDGE: TVLibraryBridge received %lu remote paths\n", (unsigned long)paths.count);
  for (NSUInteger i = 0; i < paths.count; i++) {
    printf("DEBUG BRIDGE:   [%lu]: %s\n", (unsigned long)i, [paths[i] UTF8String]);
  }
  printf("DEBUG BRIDGE: Calling GameFileCacheManager updateWithExtraPaths\n");
  [[GameFileCacheManager sharedManager] updateWithExtraPaths:paths fetchMetadata:fetch];
  printf("DEBUG BRIDGE: GameFileCacheManager updateWithExtraPaths completed\n");
}

@end
