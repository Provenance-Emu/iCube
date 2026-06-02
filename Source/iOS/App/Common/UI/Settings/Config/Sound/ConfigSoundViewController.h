// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <UIKit/UIKit.h>

#import "DOLSwitch.h"

NS_ASSUME_NONNULL_BEGIN

@interface ConfigSoundViewController : UITableViewController

@property (weak, nonatomic) IBOutlet UILabel* backendLabel;
#if !TARGET_OS_TV
@property (weak, nonatomic) IBOutlet UISlider* volumeSlider;
#endif
@property (weak, nonatomic) IBOutlet UILabel* volumeLabel;
@property (weak, nonatomic) IBOutlet DOLSwitch* stretchingSwitch;
#if !TARGET_OS_TV
@property (weak, nonatomic) IBOutlet UISlider* bufferSizeSlider;
#endif
@property (weak, nonatomic) IBOutlet UILabel* bufferSizeLabel;
@property (weak, nonatomic) IBOutlet DOLSwitch* muteSpeedLimitSwitch;
@property (weak, nonatomic) IBOutlet DOLSwitch* muteModeSwitch;

@end

NS_ASSUME_NONNULL_END
