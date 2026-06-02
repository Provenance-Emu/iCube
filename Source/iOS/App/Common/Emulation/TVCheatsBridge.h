// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TVGeckoCodeInfo : NSObject
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, readonly) BOOL userDefined;
- (instancetype)initWithName:(NSString*)name enabled:(BOOL)enabled userDefined:(BOOL)userDefined;
@end

@interface TVActionReplayCodeInfo : NSObject
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, readonly) BOOL userDefined;
- (instancetype)initWithName:(NSString*)name enabled:(BOOL)enabled userDefined:(BOOL)userDefined;
@end

@interface TVCheatsBridge : NSObject

+ (void)downloadGeckoCodesForGameId:(NSString*)gameId
                           revision:(NSInteger)revision
                          gametdbId:(NSString*)gametdbId
                          completion:(void(^)(BOOL success, NSInteger downloadedCount, NSInteger addedCount))completion NS_SWIFT_NAME(downloadGeckoCodes(forGameId:revision:gametdbId:completion:));

+ (BOOL)addGeckoCodeForGameId:(NSString*)gameId
                      revision:(NSInteger)revision
                          name:(NSString*)name
                       creator:(NSString*)creator
                       codeText:(NSString*)codeText
                      notesText:(NSString*)notesText NS_SWIFT_NAME(addGeckoCode(forGameId:revision:name:creator:codeText:notesText:));

+ (BOOL)addActionReplayCodeForGameId:(NSString*)gameId
                             revision:(NSInteger)revision
                                  name:(NSString*)name
                               codeText:(NSString*)codeText NS_SWIFT_NAME(addActionReplayCode(forGameId:revision:name:codeText:));

+ (NSArray<TVGeckoCodeInfo*>*)geckoCodesForGameId:(NSString*)gameId revision:(NSInteger)revision NS_SWIFT_NAME(geckoCodes(forGameId:revision:));
+ (BOOL)setGeckoCodeEnabled:(BOOL)enabled atIndex:(NSInteger)index forGameId:(NSString*)gameId revision:(NSInteger)revision NS_SWIFT_NAME(setGeckoCodeEnabled(_:at:forGameId:revision:));

+ (NSArray<TVActionReplayCodeInfo*>*)actionReplayCodesForGameId:(NSString*)gameId revision:(NSInteger)revision NS_SWIFT_NAME(actionReplayCodes(forGameId:revision:));
+ (BOOL)setActionReplayCodeEnabled:(BOOL)enabled atIndex:(NSInteger)index forGameId:(NSString*)gameId revision:(NSInteger)revision NS_SWIFT_NAME(setActionReplayCodeEnabled(_:at:forGameId:revision:));

@end

NS_ASSUME_NONNULL_END
