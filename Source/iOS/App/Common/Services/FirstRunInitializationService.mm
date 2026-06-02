// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "FirstRunInitializationService.h"

#import "Common/FileUtil.h"
#import "Common/IniFile.h"

#import "Core/Config/MainSettings.h"
#import "Core/HW/GCPad.h"
#import "Core/HW/Wiimote.h"
#import "Core/PowerPC/PowerPC.h" // for PowerPC::CPUCore enum
#include "Common/Config/Config.h"

#import "InputCommon/ControllerEmu/ControllerEmu.h"
#import "InputCommon/InputConfig.h"

#import "BootNoticeManager.h"
#import "UnofficialBuildNoticeViewController.h"
#if TARGET_OS_TV
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#endif

@implementation FirstRunInitializationService

- (void)importDefaultProfileForInputConfig:(InputConfig*)config {
  ControllerEmu::EmulatedController* controller = config->GetController(0);

  const std::string builtInPath = config->GetSysProfileDirectoryPath() + "Touchscreen.ini";

  Common::IniFile iniFile;
  iniFile.Load(builtInPath);

  controller->LoadConfig(iniFile.GetOrCreateSection("Profile"));
  controller->UpdateReferences(g_controller_interface);

  config->SaveConfig();
}

- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(nullable NSDictionary<UIApplicationLaunchOptionsKey,id>*)launchOptions {
  NSUserDefaults* userDefaults = NSUserDefaults.standardUserDefaults;

  NSURL* defaultsPath = [[NSBundle mainBundle] URLForResource:@"DefaultPreferences" withExtension:@"plist"];
  NSDictionary* defaultsDict = [NSDictionary dictionaryWithContentsOfURL:defaultsPath];
  [userDefaults registerDefaults:defaultsDict];

  NSInteger launchTimes = [userDefaults integerForKey:@"launch_times"];

  [userDefaults setInteger:launchTimes + 1 forKey:@"launch_times"];

  if (launchTimes == 0) {
    [self importDefaultProfileForInputConfig:Pad::GetConfig()];
    [self importDefaultProfileForInputConfig:Wiimote::GetConfig()];

    if (Config::GetActiveLayerForConfig(Config::MAIN_GFX_BACKEND) == Config::LayerType::Base) {
      Config::SetBase(Config::MAIN_GFX_BACKEND, "Metal");
    } else {
      NSLog(@"[Config] Skipping Base default MAIN_GFX_BACKEND because higher layer is active");
    }

#if TARGET_OS_TV
    // Default CPU core on tvOS: prefer CachedInterpreter on newer systems (major >= 26),
    // use JIT on older systems where you support it.
    NSOperatingSystemVersion osv = NSProcessInfo.processInfo.operatingSystemVersion;
    (void)osv; // Do not override CPU core by default; respect user configuration.
#endif

    // Present boot notice. On tvOS we don't ship the XIB; try SwiftUI-hosted equivalent if available.
#if TARGET_OS_TV
    typedef UIViewController* (*MakeNoticeFunc)(void);
    MakeNoticeFunc makeFn = (MakeNoticeFunc)dlsym(RTLD_DEFAULT, "TVOSMakeUnofficialBuildNoticeController");
    if (makeFn) {
      [[BootNoticeManager shared] enqueueViewController:makeFn()];
    } else {
      // Fallback lightweight notice to avoid hard failure if Swift file isn't linked to the target
      UIViewController* vc = [UIViewController new];
      vc.view.backgroundColor = [UIColor blackColor];
      UILabel* label = [[UILabel alloc] initWithFrame:CGRectZero];
      label.text = @"Unofficial Build";
      label.textColor = [UIColor whiteColor];
      label.font = [UIFont boldSystemFontOfSize:42];
      label.translatesAutoresizingMaskIntoConstraints = NO;
      [vc.view addSubview:label];
      [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:vc.view.centerYAnchor]
      ]];
      [[BootNoticeManager shared] enqueueViewController:vc];
    }
#else
    [[BootNoticeManager shared] enqueueViewController:[[UnofficialBuildNoticeViewController alloc] initWithNibName:@"UnofficialBuildNotice" bundle:nil]];
#endif
  }

  return true;
}

@end
