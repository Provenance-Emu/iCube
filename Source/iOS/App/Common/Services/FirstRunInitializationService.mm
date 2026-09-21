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
  }

  return true;
}

@end
