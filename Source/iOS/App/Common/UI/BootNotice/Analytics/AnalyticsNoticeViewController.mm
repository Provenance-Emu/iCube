// Copyright 2023 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "AnalyticsNoticeViewController.h"

#if !TARGET_OS_TV && !TARGET_OS_MACCATALYST
#import "Core/Config/MainSettings.h"

@interface AnalyticsNoticeViewController ()

@end

@implementation AnalyticsNoticeViewController

- (void)viewDidLoad {
  [super viewDidLoad];
}

- (void)HandleResponse:(bool)response {
  Config::SetBaseOrCurrent(Config::MAIN_ANALYTICS_PERMISSION_ASKED, true);
  Config::SetBaseOrCurrent(Config::MAIN_ANALYTICS_ENABLED, response);

  // Firebase Analytics/Crashlytics removed — the prior FIRAnalytics/FIRCrashlytics collection
  // toggles are gone. The MAIN_ANALYTICS_* config keys are still recorded for any future reporting.

  [self.navigationController popViewControllerAnimated:true];
  
  [self.delegate didFinishAnalyticsNoticeWithResult:response sender:self];
}

- (IBAction)optInPressed:(id)sender {
  [self HandleResponse:true];
}

- (IBAction)optOutPressed:(id)sender {
  [self HandleResponse:false];
}

@end
#endif
