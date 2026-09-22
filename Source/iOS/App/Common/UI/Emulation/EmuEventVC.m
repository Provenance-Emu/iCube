// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "EmuEventVC.h"
#import <UIKit/UIKit.h>

NSNotificationName const DOLRequestPauseMenuNotification = @"DOLRequestPauseMenu";
const NSTimeInterval DOLMenuLongPressDuration = 2.0;

#if TARGET_OS_TV
@interface EmuFocusTrapView : UIView
@end

@implementation EmuFocusTrapView
- (BOOL)canBecomeFocused { return YES; }
// Forward press events to the next responder (the GCEventViewController) so it can handle them.
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
    NSLog(@"[INPUT] EmuFocusTrapView pressesBegan forwarding %lu presses", (unsigned long)presses.count);
  }
  [self.nextResponder pressesBegan:presses withEvent:event];
}
- (void)pressesChanged:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
  [self.nextResponder pressesChanged:presses withEvent:event];
}
- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
  [self.nextResponder pressesEnded:presses withEvent:event];
}
@end
#endif

@implementation EmuEventVC {
#if TARGET_OS_TV
  EmuFocusTrapView* _focusTrap;
  NSTimer* _menuLongPressTimer;
  id _pauseShownObs;
  id _pauseHiddenObs;
#endif
}

- (BOOL)canBecomeFirstResponder { return YES; }
- (void)viewDidLoad {
  [super viewDidLoad];
  NSLog(@"[INPUT] EmuEventVC viewDidLoad (unconditional)");
  // Long-press on tvOS Menu button to exit back to library
  UILongPressGestureRecognizer* lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleMenuLongPress:)];
  lp.minimumPressDuration = DOLMenuLongPressDuration;
  lp.allowedPressTypes = @[ @(UIPressTypeMenu) ];
  [self.view addGestureRecognizer:lp];

#if TARGET_OS_TV
  // Add a focusable trap view to capture and keep focus during emulation
  _focusTrap = [[EmuFocusTrapView alloc] initWithFrame:self.view.bounds];
  _focusTrap.translatesAutoresizingMaskIntoConstraints = NO;
  _focusTrap.backgroundColor = [UIColor clearColor];
  [self.view addSubview:_focusTrap];
  [NSLayoutConstraint activateConstraints:@[
    [_focusTrap.topAnchor constraintEqualToAnchor:self.view.topAnchor],
    [_focusTrap.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    [_focusTrap.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [_focusTrap.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
  ]];
  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
    NSLog(@"[INPUT] EmuEventVC viewDidLoad – focus trap installed");
  }
  // Observe pause overlay visibility to relinquish focus
  __weak typeof(self) weakSelf = self;
  _pauseShownObs = [[NSNotificationCenter defaultCenter] addObserverForName:@"DOLPauseOverlayShown" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification * _Nonnull note) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf) return;
    strongSelf->_focusTrap.hidden = YES;
  }];
  _pauseHiddenObs = [[NSNotificationCenter defaultCenter] addObserverForName:@"DOLPauseOverlayHidden" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification * _Nonnull note) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf) return;
    strongSelf->_focusTrap.hidden = NO;
  }];
#endif
}
- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  NSLog(@"[INPUT] EmuEventVC viewDidAppear (unconditional)");
  [self becomeFirstResponder];
#if TARGET_OS_TV
  [self setNeedsFocusUpdate];
  [self updateFocusIfNeeded];
  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
    NSLog(@"[INPUT] EmuEventVC viewDidAppear – isFirstResponder=%d", self.isFirstResponder);
  }
#endif
}

- (void)handleMenuLongPress:(UILongPressGestureRecognizer*)gr {
  if (gr.state == UIGestureRecognizerStateBegan) {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
      NSLog(@"[INPUT] Menu long-press began – posting DOLEmulationRequestExitToLibrary");
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      [[NSNotificationCenter defaultCenter] postNotificationName:@"DOLEmulationRequestExitToLibrary" object:nil];
    });
  }
}

// tvOS remote and controller presses.
//
// Menu is the app's pause button during emulation, and a 2-second hold is the
// exit-to-library gesture. Both live here because a short press is only knowable
// at RELEASE: pressesBegan arms the long-press timer, pressesEnded decides.
// Menu presses are NOT forwarded to super — the superclass hands them to the
// system, which is part of why the Siri Remote's Menu was a dead key during
// gameplay. The UILongPressGestureRecognizer installed in viewDidLoad receives
// press events independently of the responder chain, so skipping super does not
// disable it.
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
    for (UIPress* p in presses) {
      NSLog(@"[INPUT] pressesBegan type=%ld force=%.2f timestamp=%.3f", (long)p.type, p.force, p.timestamp);
    }
  }
#if TARGET_OS_TV
  BOOL handledMenu = NO;
  // Only intercept Menu while the GAME owns the screen. With the pause overlay
  // up (focus trap hidden) Menu is the conventional tvOS "back", and swallowing
  // it there would leave no way to dismiss the overlay with the remote.
  const BOOL gameOwnsScreen = (_focusTrap != nil && !_focusTrap.hidden);
  // Fallback long-press detection using a timer in case the gesture recognizer doesn't fire
  for (UIPress* p in presses) {
    if (p.type != UIPressTypeMenu || !gameOwnsScreen)
      continue;
    handledMenu = YES;
    if (_menuLongPressTimer != nil)
      continue;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
      NSLog(@"[INPUT] Starting Menu long-press timer (%.1fs)", DOLMenuLongPressDuration);
    }
    __weak typeof(self) weakSelf = self;
    _menuLongPressTimer = [NSTimer scheduledTimerWithTimeInterval:DOLMenuLongPressDuration repeats:NO block:^(__unused NSTimer * _Nonnull t) {
      if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
        NSLog(@"[INPUT] Menu long-press timer fired – posting DOLEmulationRequestExitToLibrary");
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        // Clearing the handle is what tells pressesEnded this was a LONG press,
        // so the eventual release does not also open the pause menu.
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
          strongSelf->_menuLongPressTimer = nil;
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:@"DOLEmulationRequestExitToLibrary" object:nil];
      });
    }];
  }
  if (handledMenu)
    return;
#endif
  [super pressesBegan:presses withEvent:event];
}

- (void)pressesChanged:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
    for (UIPress* p in presses) {
      NSLog(@"[INPUT] pressesChanged type=%ld force=%.2f timestamp=%.3f", (long)p.type, p.force, p.timestamp);
    }
  }
#if TARGET_OS_TV
  return;
#else
  [super pressesChanged:presses withEvent:event];
#endif
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
    for (UIPress* p in presses) {
      NSLog(@"[INPUT] pressesEnded type=%ld force=%.2f timestamp=%.3f", (long)p.type, p.force, p.timestamp);
    }
  }
#if TARGET_OS_TV
  BOOL handledMenu = NO;
  const BOOL gameOwnsScreen = (_focusTrap != nil && !_focusTrap.hidden);
  for (UIPress* p in presses) {
    if (p.type != UIPressTypeMenu || !gameOwnsScreen)
      continue;
    handledMenu = YES;
    if (_menuLongPressTimer == nil)
      continue;  // the long press already fired (exit posted); swallow the release
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
      NSLog(@"[INPUT] Menu released before %.1fs – requesting pause menu", DOLMenuLongPressDuration);
    }
    [_menuLongPressTimer invalidate];
    _menuLongPressTimer = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
      [[NSNotificationCenter defaultCenter] postNotificationName:DOLRequestPauseMenuNotification object:nil];
    });
  }
  if (handledMenu)
    return;
#endif
  [super pressesEnded:presses withEvent:event];
}

#if TARGET_OS_TV
- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
  if (_menuLongPressTimer) {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
      NSLog(@"[INPUT] Cancelling Menu long-press timer (press cancelled)");
    }
    [_menuLongPressTimer invalidate];
    _menuLongPressTimer = nil;
  }
  [super pressesCancelled:presses withEvent:event];
}
#endif

#if TARGET_OS_TV
- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
  // Keep focus on the trap unless a SwiftUI pause overlay is visible
  if (_focusTrap && !_focusTrap.hidden) {
    return @[ _focusTrap ];
  }
  // Defer focus to outer SwiftUI overlay when trap is hidden
  return @[];
}

- (BOOL)shouldUpdateFocusInContext:(UIFocusUpdateContext *)context {
  if (_focusTrap && !_focusTrap.hidden) {
    return (context.nextFocusedView == _focusTrap || context.nextFocusedView == self.view);
  }
  return YES;
}
#endif

#if TARGET_OS_TV
- (NSArray<UIKeyCommand *> *)keyCommands {
  UIKeyCommand* exit = [UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:0 action:@selector(handleExitKey:)];
  return @[ exit ];
}

- (void)handleExitKey:(UIKeyCommand *)command {
  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
    NSLog(@"[INPUT] Consumed Exit/Back key command (Escape)");
  }
}
#endif

#if TARGET_OS_TV
- (void)dealloc {
  if (_pauseShownObs) {
    [[NSNotificationCenter defaultCenter] removeObserver:_pauseShownObs];
    _pauseShownObs = nil;
  }
  if (_pauseHiddenObs) {
    [[NSNotificationCenter defaultCenter] removeObserver:_pauseHiddenObs];
    _pauseHiddenObs = nil;
  }
}
#endif

@end
