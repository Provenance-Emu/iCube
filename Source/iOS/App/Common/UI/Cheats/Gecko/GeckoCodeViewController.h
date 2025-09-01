// Copyright 2023 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <string>

#import <UIKit/UIKit.h>

#import "Common/CommonTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface GeckoCodeViewController : UITableViewController

@property (nonatomic) std::string gameId;
@property (nonatomic) std::string gametdbId;
@property (nonatomic) u16 revision;

- (void)setGameIdString:(NSString*)value;
- (void)setGametdbIdString:(NSString*)value;
- (void)setRevisionNumber:(NSNumber*)value;

@end

NS_ASSUME_NONNULL_END
