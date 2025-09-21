// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#if TARGET_OS_MACCATALYST
@interface EmuEventVC : UIViewController
#else
#import <GameController/GameController.h>

@interface EmuEventVC : GCEventViewController
#endif
@end
