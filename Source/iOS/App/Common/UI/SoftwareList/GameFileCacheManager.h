// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

#ifdef __cplusplus
namespace UICommon {
  class GameFileCache;
}

typedef UICommon::GameFileCache GameFileCache;
#else
typedef void GameFileCache;
#endif

@class GameFilePtrWrapper;
@class TVGameItem;

NS_ASSUME_NONNULL_BEGIN

@interface GameFileCacheManager : NSObject {
  GameFileCache* _cache;
}

+ (GameFileCacheManager*)sharedManager;

- (void)rescan;
- (void)rescanAndFetchMetadataWithCompletionHandler:(nullable void (^)(void))completion_handler;
- (void)rescanLocalAndFetchMetadataWithCompletionHandler:(nullable void (^)(void))completion_handler;

- (NSArray<GameFilePtrWrapper*>*)getGames;
- (NSArray<TVGameItem*>*)currentGames;

/// Updates the cache by merging local scan paths with the provided extra absolute paths (file or URL strings).
- (void)updateWithExtraPaths:(NSArray<NSString*>*)extraPaths fetchMetadata:(BOOL)fetch;

@end

NS_ASSUME_NONNULL_END
