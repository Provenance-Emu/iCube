// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

@class TVGameItem;

NS_ASSUME_NONNULL_BEGIN

@interface TVLibraryBridge : NSObject

+ (NSArray<TVGameItem*>*)currentGames;
+ (void)rescanAndFetchMetadataWithCompletion:(void(^)(void))completion;
+ (void)loadGameCubeMainMenu;
+ (void)performOnlineSystemUpdate;
+ (void)performOnlineSystemUpdateWithRegion:(NSString*)regionCode;

@end

NS_ASSUME_NONNULL_END
