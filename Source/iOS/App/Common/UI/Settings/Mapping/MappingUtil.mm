// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "MappingUtil.h"

#import <atomic>
#import <chrono>
#import <memory>
#import <thread>

#import <UIKit/UIKit.h>

#import "Core/HW/WiimoteEmu/WiimoteEmu.h"

#import "InputCommon/ControlReference/ControlReference.h"
#import "InputCommon/ControllerInterface/ControllerInterface.h"
#import "InputCommon/ControllerInterface/MappingCommon.h"

#import "FoundationStringUtil.h"
#import "LocalizationUtil.h"

@implementation MappingUtil

+ (NSString*)getLocalizedStringForWiimoteExtension:(WiimoteEmu::ExtensionNumber)extension {
  NSString* localizable;
  switch (extension) {
    case WiimoteEmu::ExtensionNumber::NONE:
      localizable = @"";
      break;
    case WiimoteEmu::ExtensionNumber::NUNCHUK:
      localizable = @"Nunchuk";
      break;
    case WiimoteEmu::ExtensionNumber::CLASSIC:
      localizable = @"Classic Controller";
      break;
    case WiimoteEmu::ExtensionNumber::GUITAR:
      localizable = @"Guitar";
      break;
    case WiimoteEmu::ExtensionNumber::DRUMS:
      localizable = @"Drum Kit";
      break;
    case WiimoteEmu::ExtensionNumber::TURNTABLE:
      localizable = @"DJ Turntable";
      break;
    case WiimoteEmu::ExtensionNumber::UDRAW_TABLET:
      localizable = @"uDraw GameTablet";
      break;
    case WiimoteEmu::ExtensionNumber::DRAWSOME_TABLET:
      localizable = @"Drawsome Tablet";
      break;
    case WiimoteEmu::ExtensionNumber::TATACON:
      localizable = @"Taiko Drum";
      break;
    default:
      localizable = @"Error";
      break;
  }

  return DOLCoreLocalizedString(localizable);
}

// This is super unwieldy...
+ (void)detectExpressionWithDefaultDevice:(const ciface::Core::DeviceQualifier&)defaultDevice
                               allDevices:(bool)allDevices
                                    quote:(ciface::MappingCommon::Quote)quote
                           viewController:(UIViewController*)viewController
                                 callback:(void (^)(std::string))callback {
  // Shared so the Cancel action (main queue) and the detection loop (background
  // queue) can coordinate without a data race.
  auto cancelled = std::make_shared<std::atomic<bool>>(false);

  // TODO: Localization
  UIAlertController* inputAlert = [UIAlertController alertControllerWithTitle:@"Detecting Input" message:@"Press an input on your controller…" preferredStyle:UIAlertControllerStyleAlert];
  [inputAlert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"Cancel") style:UIAlertActionStyleCancel handler:^(UIAlertAction*) {
    cancelled->store(true);
  }]];

  [viewController presentViewController:inputAlert animated:true completion:^{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      // Give the user a real window to start pressing, then a longer ceiling so a
      // press-and-hold still resolves before timing out.
      constexpr auto initial_time = std::chrono::seconds(5);
      constexpr auto confirmation_time = std::chrono::milliseconds(0);
      constexpr auto maximum_time = std::chrono::seconds(10);

      std::vector<std::string> devices;

      if (allDevices) {
        devices = g_controller_interface.GetAllDeviceStrings();
      } else {
        devices = {defaultDevice.ToString()};
      }

      ciface::Core::InputDetector detector;
      {
        const auto lock = ControllerEmu::EmulatedController::GetStateLock();
        detector.Start(g_controller_interface, devices);
      }

      // InputDetector::Update is a single non-blocking poll; it must be driven in
      // a loop, and outside active emulation nothing else pumps the controller
      // interface, so refresh device input ourselves each iteration until the
      // detector completes (input captured or timed out) or the user cancels.
      while (!detector.IsComplete() && !cancelled->load()) {
        g_controller_interface.UpdateInput();
        {
          const auto lock = ControllerEmu::EmulatedController::GetStateLock();
          detector.Update(initial_time, confirmation_time, maximum_time);
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
      }

      auto detections = detector.TakeResults();
      ciface::MappingCommon::RemoveSpuriousTriggerCombinations(&detections);

      const bool was_cancelled = cancelled->load();
      std::string expression = was_cancelled ? std::string() : BuildExpression(detections, defaultDevice, quote);

      dispatch_async(dispatch_get_main_queue(), ^{
        void (^finish)(void) = ^{
          callback(expression);

          if (expression.empty() && !was_cancelled) {
            UIAlertController* noInputAlert = [UIAlertController alertControllerWithTitle:@"No input was detected." message:nil preferredStyle:UIAlertControllerStyleAlert];
            [noInputAlert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"OK") style:UIAlertActionStyleDefault handler:nil]];

            [viewController presentViewController:noInputAlert animated:true completion:nil];
          }
        };

        // Tapping Cancel already dismissed the alert; dismissing again would tear
        // down the presenting controller, so only dismiss on the timeout/detected
        // path.
        if (was_cancelled) {
          finish();
        } else {
          [viewController dismissViewControllerAnimated:true completion:finish];
        }
      });
    });
  }];
}

@end
