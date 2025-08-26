// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "TVGameItem.h"

#import "GameFilePtrWrapper.h"
#import "FoundationStringUtil.h"
#import "UICommon/GameFile.h"
#import "DiscIO/Enums.h"

@implementation TVGameItem {
    GameFilePtrWrapper *_wrapper;
    NSString *_title;
    NSString *_filePath;
    BOOL _isNKit;
    UIImage *_coverImage;
    NSString *_gameID;
    NSInteger _discNumber;
    NSInteger _revision;
    NSString *_countryName;
    NSString *_makerLong;
    NSString *_Nullable _apploaderDateString;
    NSString *_Nullable _titleIDHex;
    NSString *_gametdbID;
}

- (instancetype)initWithWrapper:(GameFilePtrWrapper *)wrapper {
    self = [super init];
    if (self) {
        _wrapper = wrapper;

        const UICommon::GameFile &game = *wrapper.gameFile;
        _title = CppToFoundationString(game.GetName(UICommon::GameFile::Variant::LongAndPossiblyCustom));
        _filePath = CppToFoundationString(game.GetFilePath());
        _isNKit = game.IsNKit();

        const UICommon::GameCover &cover = game.GetCoverImage();
        UIImage *result = nil;
        if (cover.buffer.empty()) {
            result = [UIImage imageNamed:@"NoCover"];
        } else {
            NSData *data = [NSData dataWithBytes:cover.buffer.data() length:cover.buffer.size()];
            result = [UIImage imageWithData:data];
        }

        if (!result) {
            const CGSize size = CGSizeMake(200, 300);
            UIGraphicsBeginImageContextWithOptions(size, YES, 0);
            [[UIColor colorWithWhite:0.12 alpha:1.0] setFill];
            UIRectFill(CGRectMake(0, 0, size.width, size.height));
            result = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
        }

        _coverImage = result;

        _gameID = CppToFoundationString(game.GetGameID());
        _discNumber = (NSInteger)game.GetDiscNumber();
        _revision = (NSInteger)game.GetRevision();
        _countryName = CppToFoundationString(DiscIO::GetName(game.GetCountry(), true));
        _makerLong = CppToFoundationString(game.GetMaker(UICommon::GameFile::Variant::LongAndNotCustom));
        const std::string apploaderDate = game.GetApploaderDate();
        if (!apploaderDate.empty()) {
            _apploaderDateString = CppToFoundationString(apploaderDate);
        } else {
            _apploaderDateString = nil;
        }
        if (const u64 titleId = game.GetTitleID()) {
            _titleIDHex = [NSString stringWithFormat:@"%016llx", titleId];
        } else {
            _titleIDHex = nil;
        }
        _gametdbID = CppToFoundationString(game.GetGameTDBID());
    }
    return self;
}

- (NSString *)title { return _title; }
- (NSString *)filePath { return _filePath; }
- (BOOL)isNKit { return _isNKit; }
- (UIImage *)coverImage { return _coverImage; }
- (GameFilePtrWrapper *)wrapper { return _wrapper; }
- (NSString *)gameID { return _gameID; }
- (NSInteger)discNumber { return _discNumber; }
- (NSInteger)revision { return _revision; }
- (NSString *)countryName { return _countryName; }
- (NSString *)makerLong { return _makerLong; }
- (NSString * _Nullable)apploaderDateString { return _apploaderDateString; }
- (NSString * _Nullable)titleIDHex { return _titleIDHex; }
- (NSString *)gametdbID { return _gametdbID; }

@end
