// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "EmulationViewController.h"
#import <UIKit/UIKit.h>
#include <TargetConditionals.h>

#if !TARGET_OS_TV && !TARGET_OS_MACCATALYST
#import <FirebaseAnalytics/FirebaseAnalytics.h>
#endif

#if TARGET_OS_MACCATALYST
#import <GameController/GCController.h>
#import <GameController/GCExtendedGamepad.h>
#import <GameController/GCMicroGamepad.h>
#import <GameController/GCDeviceHaptics.h>
#import <GameController/GCDualShockGamepad.h>
#import <GameController/GCDualSenseGamepad.h>
#import <GameController/GCXboxGamepad.h>
#else
#import <GameController/GameController.h>
#endif

#import "Core/ConfigManager.h"
#import "Core/Config/MainSettings.h"
#import "Common/Config/Config.h"
#import "Core/Core.h"
#import "Core/Host.h"
#import "Core/PowerPC/PowerPC.h"
#import "Core/System.h"

#import "EmulationBootParameter.h"
#import "EmulationCoordinator.h"
#import "FoundationStringUtil.h"
#import "HostNotifications.h"
#import "LocalizationUtil.h"
#import "JitManager.h"
#import "NKitWarningViewController.h"

#if TARGET_OS_TV
@interface FocusTrapView : UIView
@end

@implementation FocusTrapView
- (BOOL)canBecomeFocused { return YES; }
@end
#endif

@interface EmulationViewController ()

@end

@implementation EmulationViewController {
  bool _didStartEmulation;
#if TARGET_OS_TV
  NSTimer* _navAutoHideTimer;
  FocusTrapView* _focusTrap;
#endif
}

- (void)viewDidLoad {
  [super viewDidLoad];

  _didStartEmulation = false;

  [[EmulationCoordinator shared] registerMainDisplayView:self.rendererView];

  self.rendererView.alpha = 1.0f;

#if TARGET_OS_TV
  // Prevent focus on child UI elements during gameplay; prefer focus on the renderer.
  self.rendererView.userInteractionEnabled = YES;

  // Add a focusable trap view over the renderer to capture focus and keep it there.
  _focusTrap = [[FocusTrapView alloc] initWithFrame:self.view.bounds];
  _focusTrap.translatesAutoresizingMaskIntoConstraints = NO;
  _focusTrap.backgroundColor = [UIColor clearColor];
  [self.view addSubview:_focusTrap];
  [self.view bringSubviewToFront:_focusTrap];
  [NSLayoutConstraint activateConstraints:@[
    [_focusTrap.topAnchor constraintEqualToAnchor:self.view.topAnchor],
    [_focusTrap.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    [_focusTrap.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [_focusTrap.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
  ]];

  // Show nav bar only on long-press of the Menu button.
  UILongPressGestureRecognizer* menuHold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleMenuLongPress:)];
  menuHold.minimumPressDuration = 0.6;
  menuHold.allowedPressTypes = @[ @(UIPressTypeMenu) ];
  [self.view addGestureRecognizer:menuHold];
#endif

  // Create right bar button items
  self.stopButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemStop target:self action:@selector(stopPressed)];
  self.pauseButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemPause target:self action:@selector(pausePressed)];
  self.playButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemPlay target:self action:@selector(playPressed)];
  self.hideBarButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"eye.slash"] style:UIBarButtonItemStylePlain target:self action:@selector(hideBarPressed)];
  self.fastForwardButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"forward.fill"] style:UIBarButtonItemStylePlain target:self action:@selector(fastForwardPressed)];

  self.navigationItem.rightBarButtonItems = @[ self.stopButton, self.pauseButton, self.fastForwardButton, self.hideBarButton ];

  [self updateFastForwardIcon];

  [self.navigationController setNavigationBarHidden:true animated:true];
}

#if TARGET_OS_TV
- (void)handleMenuLongPress:(UILongPressGestureRecognizer*)gr {
  if (gr.state == UIGestureRecognizerStateBegan) {
    const BOOL currentlyHidden = self.navigationController.navigationBarHidden;
    [self updateNavigationBar:!currentlyHidden];

    // Auto-hide after a short delay when shown
    [_navAutoHideTimer invalidate];
    _navAutoHideTimer = nil;
    if (!self.navigationController.navigationBarHidden) {
      _navAutoHideTimer = [NSTimer scheduledTimerWithTimeInterval:4.0 target:self selector:@selector(_autoHideNavBar) userInfo:nil repeats:NO];
    }
  }
}

- (void)_autoHideNavBar {
  [self updateNavigationBar:true];
  [_navAutoHideTimer invalidate];
  _navAutoHideTimer = nil;
}
#endif

#if TARGET_OS_TV
- (NSArray<UIFocusGuide *> *)preferredFocusEnvironments {
  // Always keep focus on the focus trap to funnel controller input to the core
  return @[ _focusTrap ?: (UIView*)self.view ];
}

- (UIView *)preferredFocusedView {
  return _focusTrap ?: self.view;
}

- (BOOL)shouldUpdateFocusInContext:(UIFocusUpdateContext *)context {
  // Prevent focus from moving away from the trap during emulation
  return (context.nextFocusedView == _focusTrap || context.nextFocusedView == self.view);
}

- (BOOL)canBecomeFirstResponder { return YES; }

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
  // Forward controller presses to allow GameController to update input state
  [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
  [super pressesEnded:presses withEvent:event];
}
- (void)pressesChanged:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
  [super pressesChanged:presses withEvent:event];
}
- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
  [super pressesCancelled:presses withEvent:event];
}
#endif

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];

  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receiveTitleChangedNotification) name:DOLHostTitleChangedNotification object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receiveEmulationEndNotification) name:DOLEmulationDidEndNotification object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];

#if TARGET_OS_TV
  [self setNeedsFocusUpdate];
  [self updateFocusIfNeeded];
  [self becomeFirstResponder];
#endif

  if (!_didStartEmulation) {
    const PowerPC::CPUCore current_core = Config::Get(Config::MAIN_CPU_CORE);
    const bool is_interpreter_core = current_core == PowerPC::CPUCore::Interpreter || current_core == PowerPC::CPUCore::CachedInterpreter;

    if (![JitManager shared].acquiredJit && !is_interpreter_core) {
      JitWaitViewController* jitController = [[JitWaitViewController alloc] initWithNibName:@"JitWait" bundle:nil];
      jitController.delegate = self;
      jitController.modalInPresentation = true;

      [self presentViewController:jitController animated:true completion:nil];
    } else if ([self checkIfNeedToShowNKitWarning]) {
      [self showNKitWarning];
    } else {
      [self startEmulation];
    }

    _didStartEmulation = true;
  }
}

- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];

  [[NSNotificationCenter defaultCenter] removeObserver:self name:DOLHostTitleChangedNotification object:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:self name:DOLEmulationDidEndNotification object:nil];
}

- (void)didFinishJitScreenWithResult:(JitWaitViewControllerResult)result sender:(id)sender {
  [self dismissViewControllerAnimated:true completion:^{
    if (result == JitWaitViewControllerResultCancel) {
      [self.navigationController dismissViewControllerAnimated:true completion:nil];
      return;
    }

    if (result == JitWaitViewControllerResultNoJitRequested) {
      // Respect the current CPU core; do not override to CachedInterpreter.
    }

    if ([self checkIfNeedToShowNKitWarning]) {
      [self showNKitWarning];
    } else {
      [self startEmulation];
    }
  }];
}

- (BOOL)checkIfNeedToShowNKitWarning {
  if (Config::GetBase(Config::MAIN_SKIP_NKIT_WARNING)) {
    return false;
  }

  return self.bootParameter.isNKit;
}

- (void)showNKitWarning {
  NKitWarningViewController* nkitController = [[NKitWarningViewController alloc] initWithNibName:@"NKitWarning" bundle:nil];
  nkitController.delegate = self;
  nkitController.modalInPresentation = true;

  [self presentViewController:nkitController animated:true completion:nil];
}

- (void)didFinishNKitWarningScreenWithResult:(BOOL)result sender:(id)sender {
  [self dismissViewControllerAnimated:true completion:^{
    if (result) {
      [self startEmulation];
    } else {
      [self.navigationController dismissViewControllerAnimated:true completion:nil];
    }
  }];
}

- (void)startEmulation {
  [[EmulationCoordinator shared] runEmulationWithBootParameter:self.bootParameter];
}

- (void)updateNavigationBar:(bool)hidden {
  [self.navigationController setNavigationBarHidden:hidden animated:true];

#if !TARGET_OS_TV
  [self setNeedsStatusBarAppearanceUpdate];
#endif

  // Adjust the safe area insets.
  UIEdgeInsets insets = self.additionalSafeAreaInsets;
  if (hidden) {
    insets.top = 0;
  } else {
    // The safe area should extend behind the navigation bar.
    // This makes the bar "float" on top of the content.
    insets.top = -(self.navigationController.navigationBar.bounds.size.height);
  }

  self.additionalSafeAreaInsets = insets;
}

#if !TARGET_OS_TV
- (BOOL)prefersStatusBarHidden {
    return YES;
}
#endif

- (void)stopPressed {
  if (Core::GetState(Core::System::GetInstance()) == Core::State::Starting) {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Emulation Starting" message:@"Emulation is still starting. Please wait for emulation to start before requesting for it to stop." preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"OK") style:UIAlertActionStyleDefault handler:nil]];

    [self presentViewController:alert animated:true completion:nil];

    return;
  }

  void (^stop)() = ^{
    Host_Message(HostMessageID::WMUserStop);
  };

  if (Config::Get(Config::MAIN_CONFIRM_ON_STOP)) {
  UIAlertController* alert = [UIAlertController alertControllerWithTitle:DOLCoreLocalizedString(@"Confirm") message:DOLCoreLocalizedString(@"Do you want to stop the current emulation?") preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"No") style:UIAlertActionStyleDefault handler:nil]];

    [alert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"Yes") style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
      stop();
    }]];

    [self presentViewController:alert animated:true completion:nil];
  } else {
    stop();
  }
}

- (void)pausePressed {
  if (!Core::IsRunningOrStarting(Core::System::GetInstance())) {
    return;
  }

  [EmulationCoordinator shared].userRequestedPause = true;

  self.navigationItem.rightBarButtonItems = @[
    self.stopButton, self.playButton, self.fastForwardButton, self.hideBarButton
  ];
  [self updateFastForwardIcon];
}

- (void)playPressed {
  if (!Core::IsRunningOrStarting(Core::System::GetInstance())) {
    return;
  }

  [EmulationCoordinator shared].userRequestedPause = false;

  self.navigationItem.rightBarButtonItems = @[
    self.stopButton, self.pauseButton, self.fastForwardButton, self.hideBarButton
  ];
  [self updateFastForwardIcon];
}

- (void)fastForwardPressed {
  const bool enableTurbo = !Core::GetIsThrottlerTempDisabled();
  Core::SetIsThrottlerTempDisabled(enableTurbo);

  if (enableTurbo) {
    if (!Config::Get(Config::MAIN_AUDIO_MUTED) &&
        Config::Get(Config::MAIN_AUDIO_MUTE_ON_DISABLED_SPEED_LIMIT)) {
      Config::SetCurrent(Config::MAIN_AUDIO_MUTED, true);
    }
  } else {
    if (Config::Get(Config::MAIN_AUDIO_MUTED) &&
        Config::GetActiveLayerForConfig(Config::MAIN_AUDIO_MUTED) == Config::LayerType::CurrentRun) {
      Config::DeleteKey(Config::LayerType::CurrentRun, Config::MAIN_AUDIO_MUTED);
    }
  }

  [self updateFastForwardIcon];
}

- (void)hideBarPressed {
  [self updateNavigationBar:true];
}

- (void)updateFastForwardIcon {
  const bool fast = Core::GetIsThrottlerTempDisabled();
  if (@available(iOS 13.0, *)) {
    self.fastForwardButton.image = [UIImage systemImageNamed:(fast ? @"forward.fill" : @"forward")];
  }
  self.fastForwardButton.accessibilityLabel = fast ? @"Fast Forward On" : @"Fast Forward Off";
}

- (void)receiveTitleChangedNotification {
  if (Config::Get(Config::MAIN_ANALYTICS_ENABLED)) {
    NSMutableArray<NSString*>* controllerList = [[NSMutableArray alloc] init];

    for (GCController* controller in [GCController controllers]) {
      NSString* controllerType = @"Unknown";

      if (controller.extendedGamepad != nil) {
        controllerType = @"Extended";
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
      } else if (controller.gamepad != nil) {
#pragma clang diagnostic pop
        controllerType = @"Normal";
      } else if (controller.microGamepad != nil) {
        controllerType = @"Micro";
      } else {
        controllerType = @"Unknown";
      }

      [controllerList addObject:[NSString stringWithFormat:@"%@ (%@)", [controller vendorName], controllerType]];
    }

    NSString* title = CppToFoundationString(SConfig::GetInstance().GetTitleDescription());

    if ([title isEqualToString:@""]) {
      title = @"Unknown";
    }

#if !TARGET_OS_TV && !TARGET_OS_MACCATALYST
    [FIRAnalytics logEventWithName:@"game_start" parameters:@{
      @"game_uid" : title,
      @"is_returning" : @"false", // TODO
      @"connected_controllers" : [controllerList count] != 0 ? [controllerList componentsJoinedByString:@", "] : @"none"
    }];
#endif
  }
}

- (void)receiveEmulationEndNotification {
  dispatch_async(dispatch_get_main_queue(), ^{
    [UIView animateWithDuration:0.25f animations:^{
      self.rendererView.alpha = 0.0f;
    } completion:^(bool) {
      // Reset speed on exit
      Config::SetBaseOrCurrent(Config::MAIN_EMULATION_SPEED, 1.0f);
      // Ensure turbo/throttle and audio mute are restored on exit
      Core::SetIsThrottlerTempDisabled(false);
      if (Config::Get(Config::MAIN_AUDIO_MUTED) &&
          Config::GetActiveLayerForConfig(Config::MAIN_AUDIO_MUTED) == Config::LayerType::CurrentRun) {
        Config::DeleteKey(Config::LayerType::CurrentRun, Config::MAIN_AUDIO_MUTED);
      }
      [self updateFastForwardIcon];
      if (![EmulationCoordinator shared].isExternalDisplayConnected) {
        [[EmulationCoordinator shared] clearMetalLayer];
      }

      [self.navigationController dismissViewControllerAnimated:true completion:nil];
    }];
  });
}

@end
