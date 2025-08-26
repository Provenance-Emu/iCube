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
#if TARGET_OS_TV
#import "TVWiiSystemUpdateViewController.h"
#endif

@implementation TVLibraryBridge

+ (NSArray<TVGameItem*>*)currentGames {
  NSArray<GameFilePtrWrapper*>* wrappers = [[GameFileCacheManager sharedManager] getGames];
  NSMutableArray<TVGameItem*>* items = [NSMutableArray arrayWithCapacity:wrappers.count];
  for (GameFilePtrWrapper* w in wrappers) {
    [items addObject:[[TVGameItem alloc] initWithWrapper:w]];
  }
  return items;
}

+ (void)rescanAndFetchMetadataWithCompletion:(void(^)(void))completion {
  [[GameFileCacheManager sharedManager] rescanAndFetchMetadataWithCompletionHandler:^{
    if (completion) completion();
  }];
}

+ (void)loadGameCubeMainMenu {
  EmulationBootParameter* p = [EmulationBootParameter new];
  p.bootType = EmulationBootTypeGCIPL;
  p.iplRegion = DiscIO::Region::NTSC_U;
  [[EmulationCoordinator shared] runEmulationWithBootParameter:p];
}

+ (void)performOnlineSystemUpdate {
  EmulationBootParameter* p = [EmulationBootParameter new];
  p.bootType = EmulationBootTypeSystemMenu;
  [[EmulationCoordinator shared] runEmulationWithBootParameter:p];
}

+ (void)performOnlineSystemUpdateWithRegion:(NSString*)regionCode {
#if TARGET_OS_TV
	UIViewController* root = UIApplication.sharedApplication.keyWindow.rootViewController;
	if (root) {
		TVWiiSystemUpdateViewController* vc = [TVWiiSystemUpdateViewController new];
		vc.updateSource = regionCode;
		vc.isOnlineUpdate = true;
		[root presentViewController:vc animated:YES completion:nil];
		return;
	}
#else
	@try {
		UIStoryboard* sb = [UIStoryboard storyboardWithName:@"WiiSystemUpdate" bundle:nil];
		UIViewController* root = UIApplication.sharedApplication.keyWindow.rootViewController;
		if (sb && root) {
			WiiSystemUpdateViewController* vc = (WiiSystemUpdateViewController*)[sb instantiateInitialViewController];
			if (vc) {
				vc.updateSource = regionCode;
				vc.isOnlineUpdate = true;
				[root presentViewController:vc animated:YES completion:nil];
				return;
			}
		}
	} @catch (...) {
	}
#endif
	[self performOnlineSystemUpdate];
}

@end
