// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "MsgAlertManager.h"

#import <mutex>
#import <UIKit/UIKit.h>

#import "Common/Event.h"
#import "Common/MsgHandler.h"

#import "FoundationStringUtil.h"
#import "LocalizationUtil.h"
#import "MainSceneCoordinator.h"

@interface MsgAlertManager ()

// We need to declare this early so the static function below can see it.
- (bool)handleAlertWithCaption:(const char*)caption text:(const char*)text question:(bool)question style:(Common::MsgType)style;

@end

static bool MsgAlert(const char* caption, const char* text, bool question, Common::MsgType style) {
  return [[MsgAlertManager shared] handleAlertWithCaption:caption text:text question:question style:style];
}

@implementation MsgAlertManager {
  std::mutex _alertLock;
  Common::Event _waitEvent;
}

+ (MsgAlertManager*)shared {
  static MsgAlertManager* sharedInstance = nil;
  static dispatch_once_t onceToken;

  dispatch_once(&onceToken, ^{
    sharedInstance = [[self alloc] init];
  });

  return sharedInstance;
}

- (void)registerHandler {
  Common::RegisterMsgAlertHandler(MsgAlert);
}

- (bool)handleAlertWithCaption:(const char*)caption text:(const char*)text question:(bool)question style:(Common::MsgType)style {
  std::lock_guard<std::mutex> guard(_alertLock);
  
  NSString* foundationCaption = CToFoundationString(caption);
  NSString* foundationText = CToFoundationString(text);

  // Log to console as a backup
  NSLog(@"MsgAlert - %@: %@ (question: %d)", foundationCaption, foundationText, question ? 1 : 0);

  // iCube: the GameCube BIOS/IPL "could not be found" panic is confusing on its own — the user has no
  // idea what an IPL is or where to get one. Detect it and (a) replace the generic message with a
  // clear explanation, (b) add a "Learn More" button to the help page. Boot behaviour is unchanged;
  // this is messaging only. The pre-boot check in EmulationCoordinator handles the disc-launch case
  // before this fires; this remains the safety net for the direct "Load GameCube Menu" boot.
  //
  // Match "GC IPL" (NOT just "IPL"): only the two MISSING-dump panics (Boot.cpp 620/622) contain it,
  // and both keep "GC IPL" as a Latin token in every shipped locale (Core.strings en/ja). The other
  // IPL panics — "The IPL file is not a known good dump" (412) and "PAL/NTSC IPL found in …" (419) —
  // mean the dump EXISTS but is bad/wrong-region, where "isn't installed" would be flatly wrong, so a
  // bare "IPL" match would misfire on exactly those.
  const bool isGCIPLAlert = !question && foundationText != nil &&
      [foundationText rangeOfString:@"GC IPL"].location != NSNotFound;
  if (isGCIPLAlert) {
    foundationText = DOLCoreLocalizedString(@"The GameCube BIOS (IPL) isn't installed. It's required to boot the GameCube menu. You can play games without it by turning off \"Load GameCube Main Menu\" in Settings → Config → GameCube. Learn More explains how to install a GameCube BIOS dump.");
  }
  
  UIWindowScene* mainScene = [MainSceneCoordinator shared].mainScene;

  if (mainScene == nil) {
    // Dunno what we can do here - the main scene is somehow disconnected?
    return false;
  }
  
  __block bool confirmed = false;
  
  dispatch_async(dispatch_get_main_queue(), ^{
    UIWindow* window = [[UIWindow alloc] initWithWindowScene:mainScene];
    window.frame = [UIScreen mainScreen].bounds;
    window.rootViewController = [[UIViewController alloc] init];
    window.windowLevel = UIWindowLevelAlert;
    
    UIWindow* topWindow = mainScene.windows.lastObject;
    window.windowLevel = topWindow.windowLevel + 1;
    
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:foundationCaption message:foundationText preferredStyle:UIAlertControllerStyleAlert];
    
    void (^finish)() = ^void() {
      [window setHidden:true];
      self->_waitEvent.Set();
    };

    if (question) {
      [alert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"No") style:UIAlertActionStyleDefault
        handler:^(UIAlertAction* action) {
        confirmed = false;

        finish();
      }]];

      [alert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"Yes") style:UIAlertActionStyleDefault
        handler:^(UIAlertAction * action) {
        confirmed = true;

        finish();
      }]];
    }
    else
    {
      // iCube: offer a Learn More link to the GameCube BIOS help page on the IPL-missing panic.
      if (isGCIPLAlert) {
        [alert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"Learn More") style:UIAlertActionStyleDefault
          handler:^(UIAlertAction* action) {
          NSURL* url = [NSURL URLWithString:@"https://icube-emu.com/help/gamecube-bios"];
          [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
          confirmed = true;
          finish();
        }]];
      }

      [alert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"OK") style:UIAlertActionStyleDefault
        handler:^(UIAlertAction* action) {
        confirmed = true;

        finish();
      }]];
    }

    [window makeKeyAndVisible];

    [window.rootViewController presentViewController:alert animated:true completion:nil];
  });

  // Wait for a button press
  _waitEvent.Wait();

  return confirmed;
}

@end
