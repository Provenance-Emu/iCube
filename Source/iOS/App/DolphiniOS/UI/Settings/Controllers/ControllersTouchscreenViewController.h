// Copyright 2024 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ControllersTouchscreenViewController : UITableViewController

#if !TARGET_OS_TV
@property (weak, nonatomic) IBOutlet UISlider* opacitySlider;
#endif
@property (weak, nonatomic) IBOutlet UILabel* irModeLabel;

@end

NS_ASSUME_NONNULL_END
