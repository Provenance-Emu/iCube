// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "GameFileCacheManager.h"

#import "FoundationStringUtil.h"
#import "GameFilePtrWrapper.h"
#import "TVGameItem.h"
#import "Swift.h"
#import "UICommon/GameFile.h"

#import "UICommon/GameFileCache.h"
#include "Core/ConfigManager.h"
#include "DiscIO/Enums.h"
#include <memory>
#include <os/lock.h>
#include <string_view>
#include <unordered_map>
#include <vector>

using GameFileSnapshot = std::vector<std::shared_ptr<const UICommon::GameFile>>;

// 2603: UICommon::FindAllGamePaths takes std::span<const std::string_view>; the bridge keeps
// std::vector<std::string> lists, so hand it a view vector that lives for the call expression.
static std::vector<std::string_view> AsViews(const std::vector<std::string>& paths)
{
  return std::vector<std::string_view>(paths.begin(), paths.end());
}

static dispatch_queue_t GameFileCacheQueue() {
  static dispatch_once_t onceToken;
  static dispatch_queue_t queue;
  dispatch_once(&onceToken, ^{
    queue = dispatch_queue_create("org.dolphin-ios.gamefilecache.serial", DISPATCH_QUEUE_SERIAL);
  });
  return queue;
}

/// Delete AppleDouble "._<name>" sidecars anywhere under the Software folder. Finder writes
/// one next to every file it copies over WebDAV (the target has no xattr support); they carry
/// the game's extension, so builds before this listed and booted them as a second copy of the
/// title ("IntCPU: Unknown instruction 00000000"). The scan now skips them, and this removes
/// the ones users already imported. `.DS_Store` goes too. Nothing iCube uses lives in either.
static void PurgeAppleDoubleSidecars(NSString* softwareFolder) {
  NSFileManager* fm = [NSFileManager defaultManager];
  NSDirectoryEnumerator<NSURL*>* e =
      [fm enumeratorAtURL:[NSURL fileURLWithPath:softwareFolder]
          includingPropertiesForKeys:@[ NSURLIsRegularFileKey ]
                             options:0
                        errorHandler:nil];
  NSUInteger removed = 0;
  for (NSURL* url in e) {
    NSString* name = url.lastPathComponent;
    if (![name hasPrefix:@"._"] && ![name isEqualToString:@".DS_Store"])
      continue;
    NSNumber* isRegular = nil;
    [url getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:nil];
    if (!isRegular.boolValue)
      continue;
    if ([fm removeItemAtURL:url error:nil])
      removed++;
  }
  if (removed > 0)
    NSLog(@"[GameFileCache] Removed %lu AppleDouble/.DS_Store sidecar(s) from the Software folder", (unsigned long)removed);
}

/// Extract orphaned archives in the Software folder before scanning so web uploads and
/// stale `.7z`/`.zip` files are imported through the same pipeline as the document picker.
static void ProcessOrphanedArchivesBeforeRescan(void) {
  NSString* softwareFolder = [UserFolderUtil getSoftwareFolder];
  PurgeAppleDoubleSidecars(softwareFolder);
  DOLArchiveBatchImportResult* batch = [DOLZipImportHelper processOrphanedArchivesInFolder:softwareFolder];
  if (batch.archivesProcessed > 0) {
    NSLog(@"[ArchiveImport] Recovered %ld archive(s), imported %ld game(s), skipped %ld existing, %ld failed",
          (long)batch.archivesProcessed, (long)batch.gamesImported, (long)batch.gamesSkipped, (long)batch.failedArchives);
    NSString* snackbar = [DOLZipImportHelper snackbarTextForBatchImportResult:batch];
    if (snackbar.length > 0) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"DOLShowSnackbar"
                                                            object:nil
                                                          userInfo:@{@"text": snackbar}];
      });
    }
  }
}

@interface GameFileCacheManager () {
  // The game list as of the last cache-queue job. Readers copy this instead of dispatch_sync'ing
  // onto the queue, which a rescan can hold for seconds (ICUBE-F: main-thread Library, Spotlight
  // and ecosystem reads hung 3-5 s). Sharing the pointers is safe because GameFileCache never
  // mutates a GameFile it has handed out: UpdateAdditionalMetadata swaps in an updated copy.
  GameFileSnapshot _published;
  // One TVGameItem per valid game in `_published`, built on the cache queue so reads don't pay
  // for cover and banner decoding. Written only by the cache queue, under `_publishedLock`.
  NSArray<TVGameItem*>* _publishedItems;
  // Languages `_publishedItems` were built in. Titles and makers resolve through the configured
  // language (GameFile::GetConfigLanguage), so a change means no item can be reused.
  DiscIO::Language _itemsGCLanguage;
  DiscIO::Language _itemsWiiLanguage;
  os_unfair_lock _publishedLock;
}
@end

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
    self->_publishedLock = OS_UNFAIR_LOCK_INIT;
    self->_cache = new UICommon::GameFileCache();
    self->_cache->Load();
    [self publishSnapshot];
  }

  return self;
}

/// Republishes `_cache` for readers. Call on the cache queue after anything that can change the
/// cache, and before posting a completion or notification that makes someone read the list.
- (void)publishSnapshot {
  GameFileSnapshot next;
  next.reserve(self->_cache->GetSize());
  self->_cache->ForEach([&next](const std::shared_ptr<const UICommon::GameFile>& game) {
    next.push_back(game);
  });

  // Reuse the item of every game whose GameFile is unchanged: a published GameFile is never
  // mutated, so its item's cover, banner and metadata are still right. The previous items keep
  // their GameFiles alive, so no address in this map can have been reused by a new GameFile.
  // Only the cache queue writes `_publishedItems`, so reading it here without the lock is safe.
  const SConfig& config = SConfig::GetInstance();
  const DiscIO::Language gcLanguage = config.GetCurrentLanguage(false);
  const DiscIO::Language wiiLanguage = config.GetCurrentLanguage(true);
  const bool languageChanged = gcLanguage != self->_itemsGCLanguage || wiiLanguage != self->_itemsWiiLanguage;
  self->_itemsGCLanguage = gcLanguage;
  self->_itemsWiiLanguage = wiiLanguage;

  std::unordered_map<const UICommon::GameFile*, TVGameItem*> previous;
  if (!languageChanged) {
    for (TVGameItem* item in self->_publishedItems) {
      previous.emplace(item.wrapper.gameFile.get(), item);
    }
  }

  NSMutableArray<TVGameItem*>* items = [[NSMutableArray alloc] initWithCapacity:next.size()];
  NSUInteger reused = 0;
  for (const std::shared_ptr<const UICommon::GameFile>& game : next) {
    // Protect against null GameFile shared_ptr in cache
    if (!game) {
      printf("DEBUG CACHE MGR: SKIPPED null GameFile shared_ptr in cache\n");
      continue;
    }

    // Additional safety check - ensure GameFile is valid
    if (!game->IsValid()) {
#ifdef DEBUG
      printf("DEBUG CACHE MGR: SKIPPED invalid GameFile in cache: %s\n", game->GetFilePath().c_str());
#endif
      continue;
    }

    auto it = previous.find(game.get());
    if (it != previous.end()) {
      [items addObject:it->second];
      reused++;
      continue;
    }

    GameFilePtrWrapper* wrapper = [[GameFilePtrWrapper alloc] init];
    wrapper.gameFile = game;
    [items addObject:[[TVGameItem alloc] initWithWrapper:wrapper]];
  }
  NSArray<TVGameItem*>* nextItems = [items copy];

#ifdef DEBUG
  NSLog(@"GameFileCacheManager: published %lu games (%lu reused)", (unsigned long)nextItems.count, (unsigned long)reused);
#endif

  os_unfair_lock_lock(&self->_publishedLock);
  self->_published.swap(next);
  std::swap(self->_publishedItems, nextItems);
  os_unfair_lock_unlock(&self->_publishedLock);
  // The previous list and items are released here, outside the lock.
}

- (GameFileSnapshot)publishedSnapshot {
  os_unfair_lock_lock(&self->_publishedLock);
  GameFileSnapshot snapshot = self->_published;
  os_unfair_lock_unlock(&self->_publishedLock);
  return snapshot;
}

- (void)updateCacheWithShouldUpdateMetadata:(bool)updateMetadata {
  dispatch_async(GameFileCacheQueue(), ^{
    ProcessOrphanedArchivesBeforeRescan();
    NSString* softwareFolder = [UserFolderUtil getSoftwareFolder];
    std::vector<std::string> scanPaths{ FoundationToCppString(softwareFolder) };
    bool cacheUpdated = self->_cache->Update(UICommon::FindAllGamePaths(AsViews(scanPaths), true));
    if (updateMetadata) {
      cacheUpdated |= self->_cache->UpdateAdditionalMetadata();
    }
    if (cacheUpdated) {
      self->_cache->Save();
    }
    [self publishSnapshot];
  });
}

- (void)rescan {
  dispatch_async(GameFileCacheQueue(), ^{
    ProcessOrphanedArchivesBeforeRescan();
    NSString* softwareFolder = [UserFolderUtil getSoftwareFolder];
    // Only scan local folders during rescan - don't preserve old remote URLs
    // Fresh remote URLs should come from WebDAV sources via updateWithExtraPaths
    std::vector<std::string> localRoots{ FoundationToCppString(softwareFolder) };
    std::vector<std::string> all = UICommon::FindAllGamePaths(AsViews(localRoots), true);
    printf("DEBUG CACHE MGR: rescan() - only using %lu local paths (not preserving old remote URLs)\n", (unsigned long)all.size());
    bool updated = self->_cache->Update(all);
    if (updated) {
      self->_cache->Save();
    }
    [self publishSnapshot];
  });
}

- (void)rescanAndFetchMetadataWithCompletionHandler:(nullable void (^)())completion_handler {
  dispatch_async(GameFileCacheQueue(), ^{
    ProcessOrphanedArchivesBeforeRescan();
    NSString* softwareFolder = [UserFolderUtil getSoftwareFolder];

    // Only scan local folders - don't preserve old remote URLs during refresh
    // Fresh remote URLs should come from WebDAV sources via updateWithExtraPaths
    std::vector<std::string> localRoots{ FoundationToCppString(softwareFolder) };
    std::vector<std::string> all = UICommon::FindAllGamePaths(AsViews(localRoots), true);

    printf("DEBUG CACHE MGR: rescanAndFetchMetadata() - only using %lu local paths (not preserving old remote URLs)\n", (unsigned long)all.size());

    bool updated = false;
    @try {
      updated = self->_cache->Update(all);
      try {
        updated |= self->_cache->UpdateAdditionalMetadata();
      } catch (const std::exception& e) {
        NSLog(@"GameFileCache UpdateAdditionalMetadata std::exception: %s -- attempting cache rebuild", e.what());
        // One-shot rebuild on metadata failure
        delete self->_cache;
        self->_cache = new UICommon::GameFileCache();
        bool rebuiltUpdated = self->_cache->Update(all);
        try { rebuiltUpdated |= self->_cache->UpdateAdditionalMetadata(); }
        catch (...) { NSLog(@"GameFileCache metadata failed again after rebuild"); }
        updated |= rebuiltUpdated;
      } catch (...) {
        NSLog(@"GameFileCache UpdateAdditionalMetadata unknown exception -- attempting cache rebuild");
        delete self->_cache;
        self->_cache = new UICommon::GameFileCache();
        bool rebuiltUpdated = self->_cache->Update(all);
        try { rebuiltUpdated |= self->_cache->UpdateAdditionalMetadata(); }
        catch (...) { NSLog(@"GameFileCache metadata failed again after rebuild"); }
        updated |= rebuiltUpdated;
      }
    } @catch (NSException* ex) {
      NSLog(@"GameFileCache rescan exception: %@", ex);
    }

    if (updated) {
      self->_cache->Save();
    }
    [self publishSnapshot];

    if (completion_handler) {
      completion_handler();
    }
  });
}

- (void)rescanLocalAndFetchMetadataWithCompletionHandler:(nullable void (^)())completion_handler {
  dispatch_async(GameFileCacheQueue(), ^{
    [DOLSentryTelemetryBridge traceSyncWithName:@"library.metadata_fetch"
                                      operation:@"library.metadata_fetch"
                                           tags:@{@"source": @"local_remote"}
                                           work:^{
    ProcessOrphanedArchivesBeforeRescan();
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
    std::vector<std::string> all = UICommon::FindAllGamePaths(AsViews(localRoots), true);

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

    bool updated = false;
    @try {
      updated = self->_cache->Update(all);
      try {
        updated |= self->_cache->UpdateAdditionalMetadata();
      } catch (const std::exception& e) {
        NSLog(@"GameFileCache UpdateAdditionalMetadata std::exception: %s -- attempting cache rebuild", e.what());
        delete self->_cache;
        self->_cache = new UICommon::GameFileCache();
        bool rebuiltUpdated = self->_cache->Update(all);
        try { rebuiltUpdated |= self->_cache->UpdateAdditionalMetadata(); }
        catch (...) { NSLog(@"GameFileCache metadata failed again after rebuild"); }
        updated |= rebuiltUpdated;
      } catch (...) {
        NSLog(@"GameFileCache UpdateAdditionalMetadata unknown exception -- attempting cache rebuild");
        delete self->_cache;
        self->_cache = new UICommon::GameFileCache();
        bool rebuiltUpdated = self->_cache->Update(all);
        try { rebuiltUpdated |= self->_cache->UpdateAdditionalMetadata(); }
        catch (...) { NSLog(@"GameFileCache metadata failed again after rebuild"); }
        updated |= rebuiltUpdated;
      }
    } @catch (NSException* ex) {
      NSLog(@"GameFileCache rescanLocal exception: %@", ex);
    }

    if (updated) {
      self->_cache->Save();
    }
    [self publishSnapshot];

    if (completion_handler) {
      completion_handler();
    }
    }];
  });
}

- (NSArray<GameFilePtrWrapper*>*)getGames {
  NSMutableArray<GameFilePtrWrapper*>* array = [[NSMutableArray alloc] init];
  for (const std::shared_ptr<const UICommon::GameFile>& game : [self publishedSnapshot]) {
    GameFilePtrWrapper* wrapper = [[GameFilePtrWrapper alloc] init];
    wrapper.gameFile = game;
    [array addObject:wrapper];
  }

  return array;
}

- (NSArray<TVGameItem*>*)currentGames {
  os_unfair_lock_lock(&self->_publishedLock);
  NSArray<TVGameItem*>* items = self->_publishedItems;
  os_unfair_lock_unlock(&self->_publishedLock);
  return items ?: @[];
}

- (void)updateWithExtraPaths:(NSArray<NSString*>*)extraPaths fetchMetadata:(BOOL)fetch {
  printf("DEBUG CACHE MGR: updateWithExtraPaths called with %lu extra paths\n", (unsigned long)extraPaths.count);
  for (NSUInteger i = 0; i < extraPaths.count; i++) {
    printf("DEBUG CACHE MGR:   input[%lu]: %s\n", (unsigned long)i, [extraPaths[i] UTF8String]);
  }

  // All of this runs on the cache queue: it mutates _cache, and the cache queue is its only writer.
  dispatch_async(GameFileCacheQueue(), ^{
    ProcessOrphanedArchivesBeforeRescan();
    NSString* softwareFolder = [UserFolderUtil getSoftwareFolder];

    // Expand only local folders via FindAllGamePaths
    std::vector<std::string> localRoots{ FoundationToCppString(softwareFolder) };
    std::vector<std::string> all = UICommon::FindAllGamePaths(AsViews(localRoots), true);
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
        try {
          updated |= self->_cache->UpdateAdditionalMetadata();
        } catch (const std::exception& e) {
          NSLog(@"GameFileCache UpdateAdditionalMetadata std::exception: %s", e.what());
        } catch (...) {
          NSLog(@"GameFileCache UpdateAdditionalMetadata unknown exception");
        }
      }
      if (updated) {
        self->_cache->Save();
        NSLog(@"GameFileCacheManager: Cache saved");
      }
    } @catch (NSException* exception) {
      NSLog(@"GameFileCache update failed: %@", exception);
    }
    [self publishSnapshot];
    if (updated) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RemoteLibraryUpdated" object:nil];
      });
    }
  });
}

- (void)enqueueOnCacheQueueForTesting:(void (^)(void))block {
  dispatch_async(GameFileCacheQueue(), block);
}

@end
