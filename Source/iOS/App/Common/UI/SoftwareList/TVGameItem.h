// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class GameFilePtrWrapper;

NS_ASSUME_NONNULL_BEGIN

@interface TVGameItem : NSObject

@property (nonatomic, readonly) NSString *id;
@property (nonatomic, readonly) NSString *title;
@property (nonatomic, readonly) NSString *filePath;
@property (nonatomic, readonly) BOOL isNKit;
@property (nonatomic, readonly) UIImage *coverImage;
@property (nonatomic, readonly) GameFilePtrWrapper *wrapper;
@property (nonatomic, readonly) NSString *gameID;
@property (nonatomic, readonly) NSInteger discNumber;
@property (nonatomic, readonly) NSInteger revision;
@property (nonatomic, readonly) NSString *countryName;
@property (nonatomic, readonly) NSString *makerLong;
@property (nonatomic, readonly, nullable) NSString *apploaderDateString;
@property (nonatomic, readonly, nullable) NSString *titleIDHex;
@property (nonatomic, readonly) NSString *gametdbID;

- (instancetype)initWithWrapper:(GameFilePtrWrapper *)wrapper NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
