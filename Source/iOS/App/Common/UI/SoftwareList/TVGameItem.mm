// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "TVGameItem.h"

#import "GameFilePtrWrapper.h"
#import "FoundationStringUtil.h"
#import "UICommon/GameFile.h"
#import "DiscIO/Enums.h"

@implementation TVGameItem {
    GameFilePtrWrapper *_wrapper;
    NSString *_id;
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
    NSUInteger _fileSize;
}

- (instancetype)initWithWrapper:(GameFilePtrWrapper *)wrapper {
    self = [super init];
    if (self) {
        _wrapper = wrapper;

        // Critical safety check - ensure GameFile shared_ptr is not null
        if (!wrapper.gameFile) {
            NSLog(@"TVGameItem: ERROR - null GameFile shared_ptr in wrapper, creating invalid item");
            _title = @"<null GameFile>";
            _filePath = @"<null>";
            _id = @"<null>";
            return self;
        }

        const UICommon::GameFile &game = *wrapper.gameFile;

        // Protect against invalid GameFile objects that can crash string conversion
        std::string gameName;
        std::string gamePath;

        try {
            gameName = game.GetName(UICommon::GameFile::Variant::LongAndPossiblyCustom);
            gamePath = game.GetFilePath();
        } catch (...) {
            gameName = "<error>";
            gamePath = "<error>";
        }

        // Ensure non-empty strings for Foundation conversion
        if (gameName.empty()) gameName = "<unknown>";
        if (gamePath.empty()) gamePath = "<unknown>";

        _title = CppToFoundationString(gameName);
        _filePath = CppToFoundationString(gamePath);
        _id = _filePath; // Use filePath as unique identifier
        _isNKit = game.IsNKit();

        const UICommon::GameCover &cover = game.GetCoverImage();
        UIImage *result = nil;
        if (cover.buffer.empty()) {
            result = [UIImage imageNamed:@"NoCover"];
        } else {
            const size_t maxCoverBytes = 32 * 1024 * 1024; // 32MB sanity cap
            const size_t len = cover.buffer.size();
            if (len > 0 && len <= maxCoverBytes) {
                NSData *data = [NSData dataWithBytes:cover.buffer.data() length:len];
                result = [UIImage imageWithData:data];
            } else {
                NSLog(@"TVGameItem: cover size invalid (%zu), using placeholder", len);
                result = [UIImage imageNamed:@"NoCover"];
            }
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

        // Protected string conversions for all GameFile properties
        std::string gameID = game.GetGameID();
        std::string countryName = DiscIO::GetName(game.GetCountry(), true);
        std::string makerLong = game.GetMaker(UICommon::GameFile::Variant::LongAndNotCustom);
        std::string apploaderDate = game.GetApploaderDate();

        if (gameID.empty()) gameID = "<unknown>";
        if (countryName.empty()) countryName = "<unknown>";
        if (makerLong.empty()) makerLong = "<unknown>";

        _gameID = CppToFoundationString(gameID);
        _discNumber = (NSInteger)game.GetDiscNumber();
        _revision = (NSInteger)game.GetRevision();
        _countryName = CppToFoundationString(countryName);
        _makerLong = CppToFoundationString(makerLong);

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

        std::string gametdbID = game.GetGameTDBID();
        if (gametdbID.empty()) gametdbID = "<unknown>";
        _gametdbID = CppToFoundationString(gametdbID);

        _fileSize = (NSUInteger)game.GetFileSize();

        // Debug logging for file size
        NSLog(@"TVGameItem: %@ - GameFile.GetFileSize() = %llu, TVGameItem.fileSize = %lu",
              _title, game.GetFileSize(), (unsigned long)_fileSize);
    }
    return self;
}

- (NSString *)id { return _id; }
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
- (NSUInteger)fileSize { return _fileSize; }

@end
