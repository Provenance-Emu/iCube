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

  // Only scan local folders during rescan - don't preserve old remote URLs
  // Fresh remote URLs should come from WebDAV sources via updateWithExtraPaths
  std::vector<std::string> localRoots{ FoundationToCppString(softwareFolder) };
  std::vector<std::string> all = UICommon::FindAllGamePaths(localRoots, true);

  printf("DEBUG CACHE MGR: rescan() - only using %lu local paths (not preserving old remote URLs)\n", (unsigned long)all.size());

  bool updated = self->_cache->Update(all);
  if (updated) {
    self->_cache->Save();
  }
}

- (void)rescanAndFetchMetadataWithCompletionHandler:(nullable void (^)())completion_handler {
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSString* softwareFolder = [UserFolderUtil getSoftwareFolder];

    // Only scan local folders - don't preserve old remote URLs during refresh
    // Fresh remote URLs should come from WebDAV sources via updateWithExtraPaths
    std::vector<std::string> localRoots{ FoundationToCppString(softwareFolder) };
    std::vector<std::string> all = UICommon::FindAllGamePaths(localRoots, true);

    printf("DEBUG CACHE MGR: rescanAndFetchMetadata() - only using %lu local paths (not preserving old remote URLs)\n", (unsigned long)all.size());

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

- (void)rescanLocalAndFetchMetadataWithCompletionHandler:(nullable void (^)())completion_handler {
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSString* softwareFolder = [UserFolderUtil getSoftwareFolder];

    // During refresh: preserve existing remote URLs and only add/update local files
    // This provides better UX - remote files stay visible until WebDAV updates arrive
    NSMutableArray<NSString*>* remoteUrls = [[NSMutableArray alloc] init];
    self->_cache->ForEach([remoteUrls](const std::shared_ptr<const UICommon::GameFile>& game) {
      std::string path = game->GetFilePath();
      if (path.empty()) {
        printf("DEBUG CACHE MGR: SKIPPED empty path from cached GameFile\n");
        return;
      }
      NSString* pathStr = [NSString stringWithUTF8String:path.c_str()];
      if ([pathStr hasPrefix:@"http://"] || [pathStr hasPrefix:@"https://"] ||
          [pathStr hasPrefix:@"webdav://"] || [pathStr hasPrefix:@"webdavs://"]) {
        [remoteUrls addObject:pathStr];
      }
    });

    // Scan local folders
    std::vector<std::string> localRoots{ FoundationToCppString(softwareFolder) };
    std::vector<std::string> all = UICommon::FindAllGamePaths(localRoots, true);

    // Preserve existing remote URLs during refresh for better UX
    for (NSString* remoteUrl in remoteUrls) {
      if (remoteUrl.length > 0) {
        all.push_back(FoundationToCppString(remoteUrl));
      } else {
        printf("DEBUG CACHE MGR: SKIPPED empty remote URL from cache\n");
      }
    }

    printf("DEBUG CACHE MGR: rescanLocalAndFetchMetadata() - using %lu local paths + %lu preserved remote URLs\n",
           (unsigned long)(all.size() - remoteUrls.count), (unsigned long)remoteUrls.count);

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
    // Protect against null GameFile shared_ptr in cache
    if (!game) {
      printf("DEBUG CACHE MGR: SKIPPED null GameFile shared_ptr in cache\n");
      return;
    }

    // Additional safety check - ensure GameFile is valid
    if (!game->IsValid()) {
      printf("DEBUG CACHE MGR: SKIPPED invalid GameFile in cache: %s\n", game->GetFilePath().c_str());
      return;
    }

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
  printf("DEBUG CACHE MGR: updateWithExtraPaths called with %lu extra paths\n", (unsigned long)extraPaths.count);
  for (NSUInteger i = 0; i < extraPaths.count; i++) {
    printf("DEBUG CACHE MGR:   input[%lu]: %s\n", (unsigned long)i, [extraPaths[i] UTF8String]);
  }

  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSString* softwareFolder = [UserFolderUtil getSoftwareFolder];

    // Expand only local folders via FindAllGamePaths
    std::vector<std::string> localRoots{ FoundationToCppString(softwareFolder) };
    std::vector<std::string> all = UICommon::FindAllGamePaths(localRoots, true);
    printf("DEBUG CACHE MGR: Found %lu local paths\n", (unsigned long)all.size());

    // Filter and append only accessible remote URLs
    printf("DEBUG CACHE MGR: Processing %lu extra paths\n", (unsigned long)extraPaths.count);
    NSUInteger acceptedCount = 0, rejectedCount = 0;
    for (NSString* s in extraPaths) {
      if (s.length == 0) {
        printf("DEBUG CACHE MGR: SKIPPED empty string\n");
        continue;
      }

      printf("DEBUG CACHE MGR: Processing path: %s\n", [s UTF8String]);

      // Check if it's a remote URL
      if ([s hasPrefix:@"http://"] || [s hasPrefix:@"https://"] ||
          [s hasPrefix:@"webdav://"] || [s hasPrefix:@"webdavs://"]) {
        // For remote URLs, do a quick accessibility check
        // Only add if we can create a basic URL object
        NSURL* url = [NSURL URLWithString:s];
        if (url && url.host) {
          printf("DEBUG CACHE MGR: ACCEPTED remote URL: %s\n", [s UTF8String]);
          all.push_back(FoundationToCppString(s));
          acceptedCount++;
        } else {
          printf("DEBUG CACHE MGR: REJECTED remote URL (invalid): %s\n", [s UTF8String]);
          rejectedCount++;
        }
      } else {
        printf("DEBUG CACHE MGR: ACCEPTED local path: %s\n", [s UTF8String]);
        // Local files - add as-is
        all.push_back(FoundationToCppString(s));
        acceptedCount++;
      }
    }
    printf("DEBUG CACHE MGR: *** FILTER RESULTS: %lu accepted, %lu rejected ***\n", (unsigned long)acceptedCount, (unsigned long)rejectedCount);

    bool updated = false;
    @try {
      printf("DEBUG CACHE MGR: *** CALLING C++ GameFileCache::Update with %lu TOTAL paths ***\n", (unsigned long)all.size());
      for (size_t i = 0; i < all.size(); ++i) {
        printf("DEBUG CACHE MGR:   final[%zu]: %s\n", i, all[i].c_str());
      }

      printf("DEBUG CACHE MGR: About to call self->_cache->Update(all)\n");
      updated = self->_cache->Update(all);
      printf("DEBUG CACHE MGR: C++ Update returned %s\n", updated ? "true" : "false");

      if (fetch) {
        updated |= self->_cache->UpdateAdditionalMetadata();
      }
      if (updated) {
        self->_cache->Save();
        NSLog(@"GameFileCacheManager: Cache saved");
        dispatch_async(dispatch_get_main_queue(), ^{
          [[NSNotificationCenter defaultCenter] postNotificationName:@"RemoteLibraryUpdated" object:nil];
        });
      }
    } @catch (NSException* exception) {
      NSLog(@"GameFileCache update failed: %@", exception);
    }
  });
}

@end
