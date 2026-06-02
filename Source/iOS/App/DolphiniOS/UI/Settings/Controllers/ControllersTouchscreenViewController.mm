// Copyright 2024 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "ControllersTouchscreenViewController.h"

#import "Core/Config/iOSSettings.h"
#include <Metal/Metal.h>
#include "Swift.h"

@interface ControllersTouchscreenViewController ()

@end

@implementation ControllersTouchscreenViewController

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  
#if !TARGET_OS_TV
  self.opacitySlider.value = Config::Get(Config::MAIN_TOUCH_PAD_OPACITY);
#endif
  
  TCWiiTouchIRMode irMode = (TCWiiTouchIRMode)Config::Get(Config::MAIN_TOUCH_PAD_IR_MODE);
  NSString* irModeString;
  
  if (irMode == TCWiiTouchIRModeNone) {
    irModeString = @"Disabled";
  } else if (irMode == TCWiiTouchIRModeFollow) {
    irModeString = @"Follow";
  } else {
    irModeString = @"Drag";
  }
  
  self.irModeLabel.text = irModeString;
}

#if !TARGET_OS_TV
- (IBAction)opacitySliderChanged:(id)sender {
  Config::SetBaseOrCurrent(Config::MAIN_TOUCH_PAD_OPACITY, self.opacitySlider.value);
}
#endif

@end
