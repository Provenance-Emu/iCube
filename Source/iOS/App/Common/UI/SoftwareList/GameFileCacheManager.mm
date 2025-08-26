// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "GameFileCacheManager.h"

#import "FoundationStringUtil.h"
#import "GameFilePtrWrapper.h"
#import "TVGameItem.h"
#import "Swift.h"
#import "UICommon/GameFile.h"

#import "UICommon/GameFileCache.h"

@implementation GameFileCacheManager

+ (GameFileCacheManager*)sharedManager {
  static dispatch_once_t _onceToken = 0;
  static GameFileCacheManager* _sharedManager = nil;

  dispatch_once(&_onceToken, ^{
    _sharedManager = [[self alloc] init];
  });

  return _sharedManager;
}

- (id)init {
  if (self = [super init]) {
    self->_cache = new UICommon::GameFileCache();
    self->_cache->Load();
  }

  return self;
}

- (void)updateCacheWithShouldUpdateMetadata:(bool)updateMetadata {
  NSString* softwareFolder = [UserFolderUtil getSoftwareFolder];

  std::vector<std::string> scanPaths{ FoundationToCppString(softwareFolder) };

  bool cacheUpdated = self->_cache->Update(UICommon::FindAllGamePaths(scanPaths, true));

  if (updateMetadata) {
    cacheUpdated |= self->_cache->UpdateAdditionalMetadata();
  }

  if (cacheUpdated) {
    self->_cache->Save();
  }
}

- (void)rescan {
  NSString* softwareFolder = [UserFolderUtil getSoftwareFolder];

  // Get current remote URLs from cache to preserve them
  NSMutableArray<NSString*>* remoteUrls = [[NSMutableArray alloc] init];
  self->_cache->ForEach([remoteUrls](const std::shared_ptr<const UICommon::GameFile>& game) {
    std::string path = game->GetFilePath();
    NSString* pathStr = [NSString stringWithUTF8String:path.c_str()];
    if ([pathStr hasPrefix:@"http://"] || [pathStr hasPrefix:@"https://"] ||
        [pathStr hasPrefix:@"webdav://"] || [pathStr hasPrefix:@"webdavs://"]) {
      [remoteUrls addObject:pathStr];
    }
  });

  // Expand local folders via FindAllGamePaths
  std::vector<std::string> localRoots{ FoundationToCppString(softwareFolder) };
  std::vector<std::string> all = UICommon::FindAllGamePaths(localRoots, true);

  // Add preserved remote URLs
  for (NSString* remoteUrl in remoteUrls) {
    all.push_back(FoundationToCppString(remoteUrl));
  }

  bool updated = self->_cache->Update(all);
  if (updated) {
    self->_cache->Save();
  }
}

- (void)rescanAndFetchMetadataWithCompletionHandler:(nullable void (^)())completion_handler {
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSString* softwareFolder = [UserFolderUtil getSoftwareFolder];

    // Get current remote URLs from cache to preserve them
    NSMutableArray<NSString*>* remoteUrls = [[NSMutableArray alloc] init];
    self->_cache->ForEach([remoteUrls](const std::shared_ptr<const UICommon::GameFile>& game) {
      std::string path = game->GetFilePath();
      NSString* pathStr = [NSString stringWithUTF8String:path.c_str()];
      if ([pathStr hasPrefix:@"http://"] || [pathStr hasPrefix:@"https://"] ||
          [pathStr hasPrefix:@"webdav://"] || [pathStr hasPrefix:@"webdavs://"]) {
        [remoteUrls addObject:pathStr];
      }
    });

    // Expand local folders via FindAllGamePaths
    std::vector<std::string> localRoots{ FoundationToCppString(softwareFolder) };
    std::vector<std::string> all = UICommon::FindAllGamePaths(localRoots, true);

    // Add preserved remote URLs
    for (NSString* remoteUrl in remoteUrls) {
      all.push_back(FoundationToCppString(remoteUrl));
    }

    bool updated = self->_cache->Update(all);
    updated |= self->_cache->UpdateAdditionalMetadata();

    if (updated) {
      self->_cache->Save();
    }

    if (completion_handler) {
      completion_handler();
    }
  });
}

- (NSArray<GameFilePtrWrapper*>*)getGames {
  NSMutableArray<GameFilePtrWrapper*>* array = [[NSMutableArray alloc] init];
  self->_cache->ForEach([array](const std::shared_ptr<const UICommon::GameFile>& game) {
    GameFilePtrWrapper* wrapper = [[GameFilePtrWrapper alloc] init];
    wrapper.gameFile = game;

    [array addObject:wrapper];
  });

  return array;
}

- (NSArray<TVGameItem*>*)currentGames {
  NSMutableArray<TVGameItem*>* items = [[NSMutableArray alloc] init];
  size_t count = 0;

  self->_cache->ForEach([items, &count](const std::shared_ptr<const UICommon::GameFile>& game) {
    GameFilePtrWrapper* wrapper = [[GameFilePtrWrapper alloc] init];
    wrapper.gameFile = game;
    TVGameItem* item = [[TVGameItem alloc] initWithWrapper:wrapper];
    [items addObject:item];

    if (count < 20) {
      NSLog(@"  [%zu]: %s (isRemote: %s)", count, game->GetFilePath().c_str(), game->GetFilePath().rfind("http", 0) == 0 ? "true" : "false");
    }
    count++;
  });

  NSLog(@"GameFileCacheManager: currentGames returning %lu game files from cache", (unsigned long)count);
  return items;
}

- (void)updateWithExtraPaths:(NSArray<NSString*>*)extraPaths fetchMetadata:(BOOL)fetch {
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSString* softwareFolder = [UserFolderUtil getSoftwareFolder];

    // Expand only local folders via FindAllGamePaths
    std::vector<std::string> localRoots{ FoundationToCppString(softwareFolder) };
    std::vector<std::string> all = UICommon::FindAllGamePaths(localRoots, true);

    // Filter and append only accessible remote URLs
    for (NSString* s in extraPaths) {
      if (s.length == 0) continue;

      // Check if it's a remote URL
      if ([s hasPrefix:@"http://"] || [s hasPrefix:@"https://"] ||
          [s hasPrefix:@"webdav://"] || [s hasPrefix:@"webdavs://"]) {
        // For remote URLs, do a quick accessibility check
        // Only add if we can create a basic URL object
        NSURL* url = [NSURL URLWithString:s];
        if (url && url.host) {
          all.push_back(FoundationToCppString(s));
        }
      } else {
        // Local files - add as-is
        all.push_back(FoundationToCppString(s));
      }
    }

    bool updated = false;
    @try {
      NSLog(@"GameFileCacheManager: calling Update with %lu paths", (unsigned long)all.size());
      for (size_t i = 0; i < all.size() && i < 20; ++i) {
        NSLog(@"  [%zu]: %s", i, all[i].c_str());
      }

      updated = self->_cache->Update(all);
      NSLog(@"GameFileCacheManager: Update returned %s", updated ? "true" : "false");

      if (fetch) {
        updated |= self->_cache->UpdateAdditionalMetadata();
      }
      if (updated) {
        self->_cache->Save();
        NSLog(@"GameFileCacheManager: Cache saved");
      }
    } @catch (NSException* exception) {
      NSLog(@"GameFileCache update failed: %@", exception);
    }
  });
}

@end
