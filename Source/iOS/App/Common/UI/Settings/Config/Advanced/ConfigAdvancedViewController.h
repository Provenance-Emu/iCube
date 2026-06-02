// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <UIKit/UIKit.h>

#import "DOLSwitch.h"

NS_ASSUME_NONNULL_BEGIN

@interface ConfigAdvancedViewController : UITableViewController

@property (weak, nonatomic) IBOutlet UILabel* engineLabel;
@property (weak, nonatomic) IBOutlet DOLSwitch* mmuSwitch;
@property (weak, nonatomic) IBOutlet DOLSwitch* panicPauseSwitch;
@property (weak, nonatomic) IBOutlet DOLSwitch* writeBackCacheSwitch;
@property (weak, nonatomic) IBOutlet DOLSwitch* cpuClockSwitch;
#if !TARGET_OS_TV
@property (weak, nonatomic) IBOutlet UISlider* cpuClockSlider;
#endif
@property (weak, nonatomic) IBOutlet UILabel* cpuClockLabel;
@property (weak, nonatomic) IBOutlet DOLSwitch* vbiClockSwitch;
#if !TARGET_OS_TV
@property (weak, nonatomic) IBOutlet UISlider* vbiClockSlider;
#endif
@property (weak, nonatomic) IBOutlet UILabel* vbiClockLabel;
@property (weak, nonatomic) IBOutlet DOLSwitch* memorySwitch;
#if !TARGET_OS_TV
@property (weak, nonatomic) IBOutlet UISlider* memOneSlider;
#endif
@property (weak, nonatomic) IBOutlet UILabel* memOneLabel;
#if !TARGET_OS_TV
@property (weak, nonatomic) IBOutlet UISlider* memTwoSlider;
#endif
@property (weak, nonatomic) IBOutlet UILabel* memTwoLabel;
@property (weak, nonatomic) IBOutlet DOLSwitch* rtcSwitch;
#if !TARGET_OS_TV
@property (weak, nonatomic) IBOutlet UIDatePicker* rtcPicker;
#endif
@property (weak, nonatomic) IBOutlet DOLSwitch* disableICacheSwitch;
@property (weak, nonatomic) IBOutlet DOLSwitch* lowDCBZHackSwitch;
@property (weak, nonatomic) IBOutlet DOLSwitch* adaptiveClockSwitch;
@property (weak, nonatomic) IBOutlet UITableViewCell* achievementsCell;

@end

NS_ASSUME_NONNULL_END
