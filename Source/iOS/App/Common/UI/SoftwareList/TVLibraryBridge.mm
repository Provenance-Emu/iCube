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

+ (void)updateLibraryWithRemotePaths:(NSArray<NSString*>*)paths fetchMetadata:(BOOL)fetch {
  printf("DEBUG BRIDGE: TVLibraryBridge received %lu remote paths\n", (unsigned long)paths.count);
  for (NSUInteger i = 0; i < paths.count; i++) {
    printf("DEBUG BRIDGE:   [%lu]: %s\n", (unsigned long)i, [paths[i] UTF8String]);
  }
  static inline NSString* MapWebDAVToHTTP(NSString* path) {
    if (!path) return path;
    // Convert webdav(s) scheme to http(s) so Core's Http* readers are used (supports WBFS/GCZ/etc.)
    if ([path hasPrefix:@"webdavs://"]) {
      return [path stringByReplacingOccurrencesOfString:@"webdavs://" withString:@"https://"];
    }
    if ([path hasPrefix:@"webdav://"]) {
      return [path stringByReplacingOccurrencesOfString:@"webdav://" withString:@"http://"];
    }
    return path;
  }
  static inline NSString* InjectBasicAuthIfPresent(NSString* url) {
    // If the URL already contains userinfo, keep as is
    if ([url containsString:@"@"] && [url containsString:@"://"]) return url;
    // Try to look up a configured WebDAV source to get credentials based on host:port
    // Minimal: rely on URL already containing credentials if needed.
    return url;
  }
  NSMutableArray<NSString*>* mapped = [NSMutableArray arrayWithCapacity:paths.count];
  for (NSString* p in paths) {
    NSString* http = MapWebDAVToHTTP(p);
    [mapped addObject:InjectBasicAuthIfPresent(http)];
  }
  paths = mapped;
  printf("DEBUG BRIDGE: Calling GameFileCacheManager updateWithExtraPaths\n");
  [[GameFileCacheManager sharedManager] updateWithExtraPaths:paths fetchMetadata:fetch];
  printf("DEBUG BRIDGE: GameFileCacheManager updateWithExtraPaths completed\n");
}

@end
