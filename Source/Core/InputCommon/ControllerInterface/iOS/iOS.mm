// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "InputCommon/ControllerInterface/iOS/iOS.h"

#include "InputCommon/ControllerInterface/iOS/MFiController.h"
#include "InputCommon/ControllerInterface/iOS/MFiControllerScanner.h"
#include "InputCommon/ControllerInterface/iOS/MFiKeyboard.h"
#include "InputCommon/ControllerInterface/iOS/StateManager.h"
#include "InputCommon/ControllerInterface/iOS/Touchscreen.h"

#if TARGET_OS_MACCATALYST
#import <GameController/GCController.h>
#import <GameController/GCExtendedGamepad.h>
#import <GameController/GCMicroGamepad.h>
#import <GameController/GCKeyboard.h>
#import <GameController/GCDeviceHaptics.h>
#import <GameController/GCDualShockGamepad.h>
#import <GameController/GCDualSenseGamepad.h>
#import <GameController/GCXboxGamepad.h>
#else
#import <GameController/GameController.h>
#endif

namespace ciface::iOS
{
class InputBackend final : public ciface::InputBackend
{
public:
  InputBackend(ControllerInterface* controller_interface);
  ~InputBackend();
  void PopulateDevices() override;

private:
  MFiControllerScanner* m_mfi_scanner;
};

std::unique_ptr<ciface::InputBackend> CreateInputBackend(ControllerInterface* controller_interface)
{
  return std::make_unique<InputBackend>(controller_interface);
}

InputBackend::InputBackend(ControllerInterface* controller_interface)
    : ciface::InputBackend(controller_interface)
{
  StateManager::GetInstance()->Init();

  // Allow input events when the app is not the active window or when running under Catalyst.
  if (@available(iOS 14.0, tvOS 14.0, macCatalyst 14.0, *)) {
    GCController.shouldMonitorBackgroundEvents = YES;
  }

  // Create scanner (registers for GC notifications)
  m_mfi_scanner = [[MFiControllerScanner alloc] init];

#if TARGET_OS_TV
  // On tvOS, proactively start wireless controller discovery.
  NSLog(@"[iCube][Input] iOS InputBackend init (tvOS). Starting controller discovery. Existing controllers: %lu",
        (unsigned long)[GCController controllers].count);
  [GCController startWirelessControllerDiscoveryWithCompletionHandler:^{
    NSLog(@"[iCube][Input] Controller discovery started (completion)");
  }];
#elif TARGET_OS_MACCATALYST
  // On Mac Catalyst, also start discovery to ensure controllers connect reliably.
  NSLog(@"[iCube][Input] iOS InputBackend init (Mac Catalyst). Starting controller discovery. Existing controllers: %lu",
        (unsigned long)[GCController controllers].count);
  [GCController startWirelessControllerDiscoveryWithCompletionHandler:^{
    NSLog(@"[iCube][Input] Controller discovery started (completion, Catalyst)");
  }];
#else
  NSLog(@"[iCube][Input] iOS InputBackend init (iOS). Existing controllers: %lu",
        (unsigned long)[GCController controllers].count);
#endif
}

InputBackend::~InputBackend()
{
  StateManager::GetInstance()->DeInit();

#if TARGET_OS_TV || TARGET_OS_MACCATALYST
  // Stop discovery when tearing down.
  [GCController stopWirelessControllerDiscovery];
  NSLog(@"[iCube][Input] iOS InputBackend deinit (%s). Stopped controller discovery.",
        TARGET_OS_TV ? "tvOS" : "Mac Catalyst");
#endif

  m_mfi_scanner = nil;
}

void InputBackend::PopulateDevices()
{
  for (int i = 0; i < 8; ++i)
    g_controller_interface.AddDevice(std::make_shared<ciface::iOS::Touchscreen>(
        i, i >= 4));

  // Add already-connected controllers
  NSArray<GCController*>* controllers = [GCController controllers];
  NSLog(@"[iCube][Input] PopulateDevices: found %lu GCController(s)", (unsigned long)controllers.count);
  for (GCController* controller in controllers)
  {
    NSLog(@"[iCube][Input] Adding controller: vendor=%@, category=%@, playerIndex=%ld",
          controller.vendorName, controller.productCategory, (long)controller.playerIndex);
    g_controller_interface.AddDevice(std::make_shared<MFiController>(controller));
  }

  for (GCKeyboard* keyboard in [m_mfi_scanner keyboards])
    g_controller_interface.AddDevice(std::make_shared<MFiKeyboard>(keyboard));
}
}  // namespace ciface::iOS
