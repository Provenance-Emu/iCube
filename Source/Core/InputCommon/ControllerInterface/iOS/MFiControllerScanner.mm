// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "InputCommon/ControllerInterface/iOS/MFiControllerScanner.h"

#include <TargetConditionals.h>

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

#include "InputCommon/ControllerInterface/ControllerInterface.h"
#include "InputCommon/ControllerInterface/iOS/MFiController.h"
#include "InputCommon/ControllerInterface/iOS/MFiKeyboard.h"
#include "Core/HW/GCPad.h"
#include "InputCommon/InputConfig.h"
#include "InputCommon/ControllerEmu/ControllerEmu.h"

@implementation MFiControllerScanner

- (id)init
{
  if (self = [super init])
  {
    _keyboards = [[NSMutableArray alloc] init];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(controllerConnected:)
                                                 name:GCControllerDidConnectNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(controllerDisconnected:)
                                                 name:GCControllerDidDisconnectNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardConnected:)
                                                 name:GCKeyboardDidConnectNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardDisconnected:)
                                                 name:GCKeyboardDidDisconnectNotification
                                               object:nil];

    NSLog(@"[iCube][Input] MFiControllerScanner initialized. Current controllers=%lu",
          (unsigned long)[GCController controllers].count);

#if TARGET_OS_TV
    [self autoAssignPlayerIndicesIfNeeded];
#endif
  }

  return self;
}

// tvOS: Assign MFi controllers to lowest slots, then Siri Remote, without reassigning already-set indices
#if TARGET_OS_TV
- (void)autoAssignPlayerIndicesIfNeeded
{
  NSArray<GCController*>* controllers = [GCController controllers];
  if (controllers.count == 0)
    return;

  // Partition controllers: MFi (extended/gamepad) first, then Siri Remote (microGamepad)
  NSMutableArray<GCController*>* mfi = [NSMutableArray array];
  NSMutableArray<GCController*>* siri = [NSMutableArray array];

  for (GCController* c in controllers)
  {
    // Prefer extended/standard profiles as MFi even if a micro profile also exists
    if (c.extendedGamepad != nil || c.gamepad != nil) {
      [mfi addObject:c];
    } else if (c.microGamepad != nil) {
      [siri addObject:c];
    } else {
      // Fallback to MFi bucket
      [mfi addObject:c];
    }
  }

  // Deterministically assign: fill 0.. with MFi, then Siri Remote in remaining slots
  NSUInteger nextIndex = 0;
  for (GCController* c in mfi)
  {
    if (nextIndex >= 4) break;
    if ((NSUInteger)c.playerIndex != nextIndex)
    {
      c.playerIndex = (GCControllerPlayerIndex)nextIndex;
      NSLog(@"[iCube][Input] Auto-assign MFi %@ (%@) -> playerIndex=%lu",
            c.vendorName, c.productCategory, (unsigned long)nextIndex);
    }
    nextIndex++;
  }
  for (GCController* c in siri)
  {
    if (nextIndex >= 4) break;
    if ((NSUInteger)c.playerIndex != nextIndex)
    {
      c.playerIndex = (GCControllerPlayerIndex)nextIndex;
      NSLog(@"[iCube][Input] Auto-assign Siri Remote %@ (%@) -> playerIndex=%lu",
            c.vendorName, c.productCategory, (unsigned long)nextIndex);
    }
    nextIndex++;
  }
}
#endif

- (void)dealloc
{
  NSLog(@"[iCube][Input] MFiControllerScanner dealloc. Removing observers");
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)controllerConnected:(NSNotification*)notification
{
  GCController* controller = (GCController*)notification.object;
  NSLog(@"[iCube][Input] Controller connected: vendor=%@, category=%@, playerIndex=%ld",
        controller.vendorName, controller.productCategory, (long)controller.playerIndex);
#if TARGET_OS_TV
  // Assign a slot if needed without disturbing existing assignments
  [self autoAssignPlayerIndicesIfNeeded];
#endif
  g_controller_interface.AddDevice(std::make_shared<ciface::iOS::MFiController>(controller));
#if TARGET_OS_TV
  if (Pad::GetConfig() && Pad::GetConfig()->GetControllerCount() > 0)
  {
    // Find the just-added device matching this GCController
    std::string qualifier;
    const auto devices = g_controller_interface.GetAllDevices();
    for (const auto& dev : devices)
    {
      if (!dev || dev->GetSource() != "MFi")
        continue;
      const auto* mfi = dynamic_cast<const ciface::iOS::MFiController*>(dev.get());
      if (mfi && mfi->IsSameController(controller))
      {
        qualifier = dev->GetQualifiedName();
        break;
      }
    }

    auto* pad0 = Pad::GetConfig()->GetController(0);
    if (!qualifier.empty())
    {
      pad0->SetDefaultDevice(qualifier);
      NSLog(@"[iCube][Input] Pad1 default device => %s", qualifier.c_str());
    }
    pad0->UpdateReferences(g_controller_interface);
  }
#endif
}

- (void)controllerDisconnected:(NSNotification*)notification
{
  GCController* gc_controller = (GCController*)notification.object;
  NSLog(@"[iCube][Input] Controller disconnected: vendor=%@, category=%@, playerIndex=%ld",
        gc_controller.vendorName, gc_controller.productCategory, (long)gc_controller.playerIndex);
  g_controller_interface.RemoveDevice([&gc_controller](const auto* device) {
    const ciface::iOS::MFiController* controller =
        dynamic_cast<const ciface::iOS::MFiController*>(device);
    return controller && controller->IsSameController(gc_controller);
  });
#if TARGET_OS_TV
  // Fill freed slots for any remaining unassigned devices
  [self autoAssignPlayerIndicesIfNeeded];
#endif
}

- (void)keyboardConnected:(NSNotification*)notification
{
  GCKeyboard* keyboard = (GCKeyboard*)notification.object;
  NSLog(@"[iCube][Input] Keyboard connected: %@", keyboard);
  g_controller_interface.AddDevice(std::make_shared<ciface::iOS::MFiKeyboard>(keyboard));
  [_keyboards addObject:keyboard];
}

- (void)keyboardDisconnected:(NSNotification*)notification
{
  NSLog(@"[iCube][Input] Keyboard disconnected: %@", notification.object);
  g_controller_interface.RemoveDevice([](const auto* device) {
    const ciface::iOS::MFiKeyboard* keyboard =
        dynamic_cast<const ciface::iOS::MFiKeyboard*>(device);
    return keyboard != nullptr;
  });
  [_keyboards removeObject:notification.object];
}

@end
