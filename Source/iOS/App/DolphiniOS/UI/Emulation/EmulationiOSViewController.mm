// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "EmulationiOSViewController.h"

#import "Core/ConfigManager.h"
#import "Core/Config/iOSSettings.h"
#import "Core/Config/MainSettings.h"
#import "Core/Config/WiimoteSettings.h"
#import "Core/HW/GCPad.h"
#import "Core/HW/SI/SI_Device.h"
#import "Core/HW/Wiimote.h"
#import "Core/HW/WiimoteEmu/WiimoteEmu.h"
#import "Core/State.h"
#import "Core/System.h"

#import "InputCommon/InputConfig.h"

#import "VideoCommon/RenderBase.h"
#import "VideoCommon/Present.h"

#import "EmulationCoordinator.h"
#import "HostNotifications.h"
#import "HostQueue.h"
#import "LocalizationUtil.h"
#import "VirtualMFiControllerManager.h"
#import "TVControllerMappingBridge.h"
#import <GameController/GameController.h>

typedef NS_ENUM(NSInteger, DOLEmulationVisibleTouchPad) {
  DOLEmulationVisibleTouchPadNone,
  DOLEmulationVisibleTouchPadGameCube,
  DOLEmulationVisibleTouchPadWiimote,
  DOLEmulationVisibleTouchPadSidewaysWiimote,
  DOLEmulationVisibleTouchPadClassic
};

@interface EmulationiOSViewController ()

@end

@implementation EmulationiOSViewController {
  DOLEmulationVisibleTouchPad _visibleTouchPad;
  int _stateSlot;
}

- (void)viewDidLoad {
  [super viewDidLoad];

  for (int i = 0; i < [self.touchPads count]; i++) {
    TCView* padView = self.touchPads[i];

    if (i + 1 == DOLEmulationVisibleTouchPadGameCube) {
      padView.port = 0;
    } else {
      // Wii pads are mapped to touchscreen device 4
      padView.port = 4;
    }
  }

  if (@available(iOS 15.0, *)) {
    // Stupidity - iOS 15 now uses the scrollEdgeAppearance when the UINavigationBar is off screen.
    // https://developer.apple.com/forums/thread/682420
    UINavigationBar* bar = self.navigationController.navigationBar;
    bar.scrollEdgeAppearance = bar.standardAppearance;

    VirtualMFiControllerManager* virtualMfi = [VirtualMFiControllerManager shared];
    if (virtualMfi.shouldConnectController) {
      [virtualMfi connectControllerToView:self.view];
    }
  }

  _stateSlot = Config::GetBase(Config::MAIN_SELECTED_STATE_SLOT);
  [VirtualMFiControllerManager shared].delegate = (id<VirtualMFiControllerManagerDelegate>)self;
}

// MARK: - VirtualMFiControllerManagerDelegate
- (void)virtualMFiControllerDidConnect {
  [EmulationCoordinator ensurePad1DefaultsToTouchscreen];
}

- (void)virtualMFiControllerDidDisconnect {
  [EmulationCoordinator ensurePad1DefaultsToTouchscreen];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];

  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receiveTitleChangedNotificationiOS) name:DOLHostTitleChangedNotification object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receiveRequestRenderWindowSizeNotificationiOS) name:DOLHostRequestRenderWindowSizeNotification object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receiveEmulationEndNotificationiOS) name:DOLEmulationDidEndNotification object:nil];

  // Refresh touch pad visibility when assignments change via unified manager
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onControllerAssignmentsChanged) name:@"ControllerAssignmentsChanged" object:nil];

  // Physical controller connect/disconnect
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onGCControllerDidConnect:) name:GCControllerDidConnectNotification object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onGCControllerDidDisconnect:) name:GCControllerDidDisconnectNotification object:nil];

  // Reconcile at view appearance to fix phantom controllers after game start
  [[ControllerManager shared] reconcile];
}

- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];

  [[NSNotificationCenter defaultCenter] removeObserver:self name:DOLHostTitleChangedNotification object:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:self name:DOLHostRequestRenderWindowSizeNotification object:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:self name:DOLEmulationDidEndNotification object:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:self name:GCControllerDidConnectNotification object:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:self name:GCControllerDidDisconnectNotification object:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:self name:@"ControllerAssignmentsChanged" object:nil];
}

// MARK: - Physical controller observers
- (void)onGCControllerDidConnect:(NSNotification*)note {
  [[ControllerManager shared] reconcile];
  [EmulationCoordinator autoAssignNewestExternalControllerToFirstAvailableSlot];
  int assignedPort = -1;
  // Detect first available GC port that now has a default device set to a non-touchscreen
  for (int i = 0; i < 4; i++) {
    std::string q = Pad::GetConfig()->GetController(i)->GetDefaultDevice().ToString();
    if (!q.empty() && q.find("Touchscreen") == std::string::npos) { assignedPort = i + 1; break; }
  }
  if (assignedPort > 0) {
    NSString* msg = [NSString stringWithFormat:NSLocalizedString(@"Assigned to Player %d", nil), assignedPort];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"DOLShowSnackbar" object:nil userInfo:@{ @"text": msg }];
  }
  if (Core::System::GetInstance().IsWii()) {
    int wmAssigned = -1;
    const int count = Wiimote::GetConfig() ? Wiimote::GetConfig()->GetControllerCount() : 0;
    for (int i = 0; i < count; i++) {
      std::string q = Wiimote::GetConfig()->GetController(i)->GetDefaultDevice().ToString();
      if (!q.empty() && q.find("Touchscreen") == std::string::npos) { wmAssigned = i + 1; break; }
    }
    if (wmAssigned > 0) {
      NSString* msg = [NSString stringWithFormat:NSLocalizedString(@"Assigned Wiimote %d", nil), wmAssigned];
      [[NSNotificationCenter defaultCenter] postNotificationName:@"DOLShowSnackbar" object:nil userInfo:@{ @"text": msg }];
    }
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    // Prefer reported system; if ambiguous or Wiimote pad not available, default to GameCube
    if (Core::System::GetInstance().IsWii()) {
      if ([self isWiimoteTouchPadAttached]) {
        [self updateVisibleTouchPadToWii];
      } else {
        [self updateVisibleTouchPadToGameCube];
      }
    } else {
      [self updateVisibleTouchPadToGameCube];
    }
  });
}

- (void)onGCControllerDidDisconnect:(NSNotification*)note {
  // On disconnect, ensure Pad1 touch fallback and prefer GC when ambiguous
  if (Core::System::GetInstance().IsWii()) {
    if ([self isWiimoteTouchPadAttached]) {
      [self updateVisibleTouchPadToWii];
    } else {
      [self updateVisibleTouchPadToGameCube];
    }
  } else {
    [self updateVisibleTouchPadToGameCube];
  }
}

- (void)onControllerAssignmentsChanged {
  dispatch_async(dispatch_get_main_queue(), ^{
    [EmulationCoordinator ensurePad1DefaultsToTouchscreen];
    if (Core::System::GetInstance().IsWii()) {
      [self updateVisibleTouchPadToWii];
    } else {
      [self updateVisibleTouchPadToGameCube];
    }
    [self recreateMenu];
  });
}

- (void)recreateMenu {
  NSMutableArray<UIMenuElement*>* controllerActions = [[NSMutableArray alloc] init];

  NSMutableArray<UIMenuElement*>* visibleControllerActions = [[NSMutableArray alloc] init];

  bool wiimoteTouchPadAttached = [self isWiimoteTouchPadAttached] && Core::System::GetInstance().IsWii();
  bool gamecubeTouchPadAttached = [self isGameCubeTouchPadAttached];

  if (wiimoteTouchPadAttached) {
    UIAction* wiimoteAction = [UIAction actionWithTitle:DOLCoreLocalizedString(@"Wii Remote") image:nil identifier:nil handler:^(UIAction*) {
      [self updateVisibleTouchPadToWii];
      [self recreateMenu];

      [self.navigationController setNavigationBarHidden:true animated:true];
    }];

    if (_visibleTouchPad == DOLEmulationVisibleTouchPadWiimote ||
        _visibleTouchPad == DOLEmulationVisibleTouchPadSidewaysWiimote ||
        _visibleTouchPad == DOLEmulationVisibleTouchPadClassic) {
      wiimoteAction.state = UIMenuElementStateOn;
    } else {
      wiimoteAction.state = UIMenuElementStateOff;
    }

    [visibleControllerActions addObject:wiimoteAction];
  }

  if (gamecubeTouchPadAttached) {
    UIAction* gamecubeAction = [UIAction actionWithTitle:DOLCoreLocalizedString(@"GameCube Controller") image:nil identifier:nil handler:^(UIAction*) {
      [self updateVisibleTouchPadToGameCube];
      [self recreateMenu];

      [self.navigationController setNavigationBarHidden:true animated:true];
    }];

    if (_visibleTouchPad == DOLEmulationVisibleTouchPadGameCube) {
      gamecubeAction.state = UIMenuElementStateOn;
    } else {
      gamecubeAction.state = UIMenuElementStateOff;
    }

    [visibleControllerActions addObject:gamecubeAction];
  }

  if (wiimoteTouchPadAttached || gamecubeTouchPadAttached) {
    UIAction* noneAction = [UIAction actionWithTitle:DOLCoreLocalizedString(@"Hide") image:nil identifier:nil handler:^(UIAction*) {
      [self updateVisibleTouchPadWithType:DOLEmulationVisibleTouchPadNone];
      // If neither pad is attached, immediately recover to GC + defaults
      if (![self isWiimoteTouchPadAttached] && ![self isGameCubeTouchPadAttached]) {
        [EmulationCoordinator ensurePad1DefaultsToTouchscreen];
        [self updateVisibleTouchPadWithType:DOLEmulationVisibleTouchPadGameCube];
      }
      [self ensureVisibleTouchPadFallbackIfAmbiguous];
      [self recreateMenu];

      [self.navigationController setNavigationBarHidden:true animated:true];
    }];

    if (_visibleTouchPad == DOLEmulationVisibleTouchPadNone) {
      noneAction.state = UIMenuElementStateOn;
    } else {
      noneAction.state = UIMenuElementStateOff;
    }

    [visibleControllerActions addObject:noneAction];
  }

  UIMenu* visibleControllerMenu = [UIMenu menuWithTitle:@"Touch Controller" image:[UIImage systemImageNamed:@"gamecontroller"] identifier:nil options:0 children:visibleControllerActions];
  [controllerActions addObject:visibleControllerMenu];

  if (wiimoteTouchPadAttached) {
    TCWiiTouchIRMode irMode = (TCWiiTouchIRMode)Config::Get(Config::MAIN_TOUCH_PAD_IR_MODE);

    UIMenu* menu = [UIMenu menuWithTitle:@"Touch IR Pointer" image:[UIImage systemImageNamed:@"hand.point.up.left"] identifier:nil options:0 children:@[
      [UIAction actionWithTitle:@"Disabled" image:nil identifier:nil handler:^(UIAction*) {
        Config::SetBaseOrCurrent(Config::MAIN_TOUCH_PAD_IR_MODE, TCWiiTouchIRModeNone);

        [self updatePointerValuesOnWiiTouchPads];
        [self recreateMenu];

        [self.navigationController setNavigationBarHidden:true animated:true];
      }],
      [UIAction actionWithTitle:@"Follow" image:nil identifier:nil handler:^(UIAction*) {
        Config::SetBaseOrCurrent(Config::MAIN_TOUCH_PAD_IR_MODE, TCWiiTouchIRModeFollow);

        [self updatePointerValuesOnWiiTouchPads];
        [self recreateMenu];

        [self.navigationController setNavigationBarHidden:true animated:true];
      }],
      [UIAction actionWithTitle:@"Drag" image:nil identifier:nil handler:^(UIAction*) {
        Config::SetBaseOrCurrent(Config::MAIN_TOUCH_PAD_IR_MODE, TCWiiTouchIRModeDrag);

        [self updatePointerValuesOnWiiTouchPads];
        [self recreateMenu];

        [self.navigationController setNavigationBarHidden:true animated:true];
      }]
    ]];

    UIAction* selectedAction = (UIAction*)menu.children[(int)irMode];
    selectedAction.state = UIMenuElementStateOn;

    [controllerActions addObject:menu];
  }

  NSMutableArray<UIMenuElement*>* stateSlotActions = [[NSMutableArray alloc] init];

  for (int i = 1; i <= State::NUM_STATES; i++) {
    [stateSlotActions addObject:[UIAction actionWithTitle:[NSString stringWithFormat:@"Slot %d", i] image:nil identifier:nil handler:^(UIAction* action) {
      self->_stateSlot = i;
      Config::SetBase(Config::MAIN_SELECTED_STATE_SLOT, i);

      [self recreateMenu];
    }]];
  }

  UIAction* selectedSlotElement = (UIAction*)[stateSlotActions objectAtIndex:Config::GetBase(Config::MAIN_SELECTED_STATE_SLOT) - 1];
  selectedSlotElement.state = UIMenuElementStateOn;

  self.navigationItem.leftBarButtonItem.menu = [UIMenu menuWithChildren:@[
    [UIMenu menuWithTitle:DOLCoreLocalizedString(@"Controllers") image:nil identifier:nil options:UIMenuOptionsDisplayInline children:controllerActions],
    [UIMenu menuWithTitle:DOLCoreLocalizedString(@"Save State") image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[
      [UIMenu menuWithTitle:DOLCoreLocalizedString(@"Select State Slot") image:nil identifier:nil options:0 children:stateSlotActions],
      [UIAction actionWithTitle:DOLCoreLocalizedString(@"Load State") image:[UIImage systemImageNamed:@"tray.and.arrow.down"] identifier:nil handler:^(UIAction*) {
        DOLHostQueueRunAsync(^{
          State::Load(Core::System::GetInstance(), self->_stateSlot);
        });

        [self.navigationController setNavigationBarHidden:true animated:true];
      }],
      [UIAction actionWithTitle:DOLCoreLocalizedString(@"Save State") image:[UIImage systemImageNamed:@"tray.and.arrow.up"] identifier:nil handler:^(UIAction*) {
        DOLHostQueueRunAsync(^{
          State::Save(Core::System::GetInstance(), self->_stateSlot);
        });

        [self.navigationController setNavigationBarHidden:true animated:true];
      }]
    ]]
  ]];
}

- (void)viewDidLayoutSubviews {
  if (g_presenter) {
    g_presenter->ResizeSurface();
  }

#if TARGET_OS_IOS
  [[TCDeviceMotion shared] statusBarOrientationChanged];
#endif

  [self updatePointerValuesOnWiiTouchPads];
}

- (BOOL)prefersHomeIndicatorAutoHidden {
  return true;
}

- (void)receiveTitleChangedNotificationiOS {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (Core::System::GetInstance().IsWii()) {
      [self updateVisibleTouchPadToWii];
    } else {
      [self updateVisibleTouchPadToGameCube];
    }

    [self recreateMenu];
  });
}

- (void)receiveRequestRenderWindowSizeNotificationiOS {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (Core::System::GetInstance().IsWii()) {
      [self updatePointerValuesOnWiiTouchPads];
    }
  });
}

- (bool)isWiimoteTouchPadAttached {
  if (Config::Get(Config::GetInfoForWiimoteSource(0)) != WiimoteSource::Emulated) {
    // Nothing is plugged in to this port.
    return false;
  }

  const auto wiimote = static_cast<WiimoteEmu::Wiimote*>(Wiimote::GetConfig()->GetController(0));

  if (wiimote->GetDefaultDevice().source != "iOS") {
    // A real controller is mapped to this port.
    return false;
  }

  return true;
}

- (bool)isGameCubeTouchPadAttached {
  if (Config::Get(Config::GetInfoForSIDevice(0)) == SerialInterface::SIDEVICE_NONE) {
    // Nothing is plugged in to this port.
    return false;
  }

  const auto device = Pad::GetConfig()->GetController(0);

  if (device->GetDefaultDevice().source != "iOS") {
    // A real controller is mapped to this port.
    return false;
  }

  return true;
}

- (void)updateVisibleTouchPadWithType:(DOLEmulationVisibleTouchPad)touchPad {
  if (_visibleTouchPad == touchPad) {
    return;
  }

#if TARGET_OS_IOS
  TCDeviceMotion* motion = [TCDeviceMotion shared];

  if (touchPad == DOLEmulationVisibleTouchPadWiimote || touchPad == DOLEmulationVisibleTouchPadSidewaysWiimote || touchPad == DOLEmulationVisibleTouchPadClassic) {
    [motion setMotionEnabled:true];
    [motion setPort:4]; // Touchscreen device 4 is used for the Wiimote
  } else {
    [motion setMotionEnabled:false];
  }
#endif

  _visibleTouchPad = touchPad;
  [self setNeedsStatusBarAppearanceUpdate];
}

/// Ensures an on-screen pad is always chosen even with ambiguous mappings
- (void)ensureVisibleTouchPadFallbackIfAmbiguous {
  const BOOL hasWii = [self isWiimoteTouchPadAttached];
  const BOOL hasGC  = [self isGameCubeTouchPadAttached];
  if (!hasWii && !hasGC) {
    // Ambiguous or none attached: force GC pad visible and default touchscreen mapping
    [EmulationCoordinator ensurePad1DefaultsToTouchscreen];
    [self updateVisibleTouchPadWithType:DOLEmulationVisibleTouchPadGameCube];
  }
}

// Call the ambiguity guard after choosing a target
- (void)updateVisibleTouchPadToWii {
  // Per-game override
  NSString* overrideStr = [[NSUserDefaults standardUserDefaults] stringForKey:@"current_profile_touch_override"];
  if (overrideStr && [overrideStr isEqualToString:@"forceGameCube"]) {
    [self updateVisibleTouchPadToGameCube];
    return;
  }
  const BOOL autoSystem = [[NSUserDefaults standardUserDefaults] objectForKey:@"auto_touchpad_by_system"] ? [[NSUserDefaults standardUserDefaults] boolForKey:@"auto_touchpad_by_system"] : YES;
  if (!autoSystem) {
    if (![self isWiimoteTouchPadAttached]) { [self updateVisibleTouchPadToGameCube]; [self ensureVisibleTouchPadFallbackIfAmbiguous]; return; }
  }
  if (![self isWiimoteTouchPadAttached]) {
    [self updateVisibleTouchPadToGameCube];
    [self ensureVisibleTouchPadFallbackIfAmbiguous];
    return;
  }

  DOLEmulationVisibleTouchPad targetTouchPad;
  const auto wiimote = static_cast<WiimoteEmu::Wiimote*>(Wiimote::GetConfig()->GetController(0));
  if (wiimote->GetActiveExtensionNumber() == WiimoteEmu::ExtensionNumber::CLASSIC) {
    targetTouchPad = DOLEmulationVisibleTouchPadClassic;
  } else if (wiimote->IsSideways()) {
    targetTouchPad = DOLEmulationVisibleTouchPadSidewaysWiimote;
  } else {
    targetTouchPad = DOLEmulationVisibleTouchPadWiimote;
  }
  [self updateVisibleTouchPadWithType:targetTouchPad];
  [self updatePointerValuesOnWiiTouchPads];
  [self ensureVisibleTouchPadFallbackIfAmbiguous];
}

- (void)updateVisibleTouchPadToGameCube {
  // Per-game override
  NSString* overrideStr = [[NSUserDefaults standardUserDefaults] stringForKey:@"current_profile_touch_override"];
  if (overrideStr && [overrideStr isEqualToString:@"forceWii"]) {
    [self updateVisibleTouchPadToWii];
    return;
  }
  const BOOL autoSystem = [[NSUserDefaults standardUserDefaults] objectForKey:@"auto_touchpad_by_system"] ? [[NSUserDefaults standardUserDefaults] boolForKey:@"auto_touchpad_by_system"] : YES;
  if (!autoSystem) {
    if (![self isGameCubeTouchPadAttached]) { [self ensureVisibleTouchPadFallbackIfAmbiguous]; return; }
  }
  if (![self isGameCubeTouchPadAttached]) {
    if (Core::System::GetInstance().IsWii() && [self isWiimoteTouchPadAttached]) {
      [self updateVisibleTouchPadToWii];
    } else {
      // Force GC as universal fallback
      [EmulationCoordinator ensurePad1DefaultsToTouchscreen];
      [self updateVisibleTouchPadWithType:DOLEmulationVisibleTouchPadGameCube];
    }
    [self ensureVisibleTouchPadFallbackIfAmbiguous];
    return;
  }
  [self updateVisibleTouchPadWithType:DOLEmulationVisibleTouchPadGameCube];
  [self ensureVisibleTouchPadFallbackIfAmbiguous];
}

- (void)updatePointerValuesOnWiiTouchPads {
  if (!g_presenter) {
    return;
  }

  TCWiiTouchIRMode irMode = TCWiiTouchIRModeNone;

  if ([self isWiimoteTouchPadAttached]) {
    irMode = (TCWiiTouchIRMode)Config::Get(Config::MAIN_TOUCH_PAD_IR_MODE);

    ControllerEmu::ControlGroup* group = Wiimote::GetWiimoteGroup(0, WiimoteEmu::WiimoteGroup::IMUPoint);
    group->enabled = irMode == TCWiiTouchIRModeNone;
  }

  for (int i = 0; i < [self.touchPads count]; i++) {
    TCView* padView = self.touchPads[i];

    if ([padView isKindOfClass:[TCWiiPad class]]) {
      TCWiiPad* wiiPadView = (TCWiiPad*)padView;

      [wiiPadView setTouchIRMode:irMode];
      [wiiPadView resetPointer];
      [wiiPadView recalculatePointerValuesWithNew_rect:self.rendererView.bounds game_aspect:g_presenter->CalculateDrawAspectRatio()];
    }
  }
}

- (IBAction)pullDownPressed:(id)sender {
  [self updateNavigationBar:false];
}

- (void)receiveEmulationEndNotificationiOS {
  if (@available(iOS 15.0, *)) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [[VirtualMFiControllerManager shared] disconnectController];
    });
  }

#if TARGET_OS_IOS
  [[TCDeviceMotion shared] setMotionEnabled:false];
#endif
}

@end
