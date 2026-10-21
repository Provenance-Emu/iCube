// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "EmuEventVC.h"
#import "ICubeLog.h"
#import <UIKit/UIKit.h>
#import <UIKit/UIGestureRecognizerSubclass.h>

NSNotificationName const DOLRequestPauseMenuNotification = @"DOLRequestPauseMenu";
NSNotificationName const DOLRecenterPointerNotification = @"DOLRecenterPointer";
NSNotificationName const DOLPointerModeDidChangeNotification = @"DOLPointerModeDidChange";
NSNotificationName const DOLOnScreenControlsChosenNotification = @"DOLOnScreenControlsChosen";
NSNotificationName const DOLEditTouchLayoutNotification = @"DOLEditTouchLayout";
NSNotificationName const DOLMotionSettingsChangedNotification = @"DOLMotionSettingsChanged";
NSNotificationName const DOLMenuPressChangedNotification = @"DOLMenuPressChanged";
NSNotificationName const DOLGameplayInputBeganNotification = @"DOLGameplayInputBegan";
static BOOL sPauseOverlayVisible = NO;
static BOOL sMenuPressActive = NO;
static NSUInteger sGameplayTouchCount = 0;
const NSTimeInterval DOLMenuLongPressDuration = 2.0;

// Observe descendants without cancelling their touch handling or competing with gestures.
@interface DOLGameplayTouchObserver : UIGestureRecognizer
@end
@implementation DOLGameplayTouchObserver {
  NSUInteger _touchCount;
}
- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  _touchCount += touches.count;
  sGameplayTouchCount += touches.count;
  if (!sPauseOverlayVisible)
    [[NSNotificationCenter defaultCenter] postNotificationName:DOLGameplayInputBeganNotification object:nil];
}
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  const NSUInteger released = MIN(_touchCount, touches.count);
  _touchCount -= released;
  sGameplayTouchCount -= MIN(sGameplayTouchCount, released);
  if (_touchCount == 0) self.state = UIGestureRecognizerStateFailed;
}
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  [self touchesEnded:touches withEvent:event];
}
- (void)reset {
  sGameplayTouchCount -= MIN(sGameplayTouchCount, _touchCount);
  _touchCount = 0;
  [super reset];
}
- (void)dealloc { sGameplayTouchCount -= MIN(sGameplayTouchCount, _touchCount); }
- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer*)other { return NO; }
- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer*)other { return NO; }
@end

#if TARGET_OS_TV
@interface EmuFocusTrapView : UIView
@end

@implementation EmuFocusTrapView
- (BOOL)canBecomeFocused { return YES; }
// Forward press events to the next responder (the GCEventViewController) so it can handle them.
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
    DOLDebugLog(@"[INPUT] EmuFocusTrapView pressesBegan forwarding %lu presses", (unsigned long)presses.count);
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
  BOOL _menuPressOwnedByGame;
#endif
  id _pauseShownObs;
  id _pauseHiddenObs;
}

+ (BOOL)isPauseOverlayVisible { return sPauseOverlayVisible; }
+ (BOOL)gameplayTouchIsActive { return sGameplayTouchCount > 0; }
+ (BOOL)menuPressIsActive { return sMenuPressActive; }
- (BOOL)canBecomeFirstResponder { return YES; }
- (void)viewDidLoad {
  [super viewDidLoad];
  DOLGameplayTouchObserver* touchObserver = [[DOLGameplayTouchObserver alloc] initWithTarget:nil action:nil];
  touchObserver.cancelsTouchesInView = NO;
  touchObserver.delaysTouchesBegan = NO;
  touchObserver.delaysTouchesEnded = NO;
  [self.view addGestureRecognizer:touchObserver];
  DOLDebugLog(@"[INPUT] EmuEventVC viewDidLoad (unconditional)");
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
    DOLDebugLog(@"[INPUT] EmuEventVC viewDidLoad – focus trap installed");
  }
#endif
  // Track pause overlays on both platforms; only tvOS has a focus trap to relinquish.
  __weak typeof(self) weakSelf = self;
  _pauseShownObs = [[NSNotificationCenter defaultCenter] addObserverForName:@"DOLPauseOverlayShown" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification * _Nonnull note) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf) return;
    sPauseOverlayVisible = YES;
#if TARGET_OS_TV
    strongSelf->_focusTrap.hidden = YES;
#endif
  }];
  _pauseHiddenObs = [[NSNotificationCenter defaultCenter] addObserverForName:@"DOLPauseOverlayHidden" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification * _Nonnull note) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf) return;
    sPauseOverlayVisible = NO;
#if TARGET_OS_TV
    strongSelf->_focusTrap.hidden = NO;
#endif
  }];
}
- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  DOLDebugLog(@"[INPUT] EmuEventVC viewDidAppear (unconditional)");
  [self becomeFirstResponder];
#if TARGET_OS_TV
  [self setNeedsFocusUpdate];
  [self updateFocusIfNeeded];
  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
    DOLDebugLog(@"[INPUT] EmuEventVC viewDidAppear – isFirstResponder=%d", self.isFirstResponder);
  }
#endif
}

- (void)handleMenuLongPress:(UILongPressGestureRecognizer*)gr {
#if TARGET_OS_TV
  if (!_menuPressOwnedByGame) return;
#endif
  if (gr.state == UIGestureRecognizerStateBegan) {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
      DOLDebugLog(@"[INPUT] Menu long-press began – posting DOLEmulationRequestExitToLibrary");
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
  for (UIPress* press in presses) { if (press.type == UIPressTypeMenu) sMenuPressActive = YES; }
#ifdef DEBUG
  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
    for (UIPress* p in presses) {
      DOLDebugLog(@"[INPUT] pressesBegan type=%ld force=%.2f timestamp=%.3f", (long)p.type, p.force, p.timestamp);
    }
  }
#endif
#if TARGET_OS_TV
  BOOL handledMenu = NO;
  // Only intercept Menu while the GAME owns the screen. With the pause overlay
  // up (focus trap hidden) Menu is the conventional tvOS "back", and swallowing
  // it there would leave no way to dismiss the overlay with the remote.
  const BOOL gameOwnsScreen = (_focusTrap != nil && !_focusTrap.hidden);
  // Fallback long-press detection using a timer in case the gesture recognizer doesn't fire
  for (UIPress* p in presses) {
    if (p.type != UIPressTypeMenu) continue;
    _menuPressOwnedByGame = gameOwnsScreen;
    [[NSNotificationCenter defaultCenter] postNotificationName:DOLMenuPressChangedNotification object:nil
      userInfo:@{@"pressed": @YES, @"overlayOwned": @(!gameOwnsScreen)}];
    if (!gameOwnsScreen) continue;
    handledMenu = YES;
    if (_menuLongPressTimer != nil)
      continue;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
      DOLDebugLog(@"[INPUT] Starting Menu long-press timer (%.1fs)", DOLMenuLongPressDuration);
    }
    __weak typeof(self) weakSelf = self;
    _menuLongPressTimer = [NSTimer scheduledTimerWithTimeInterval:DOLMenuLongPressDuration repeats:NO block:^(__unused NSTimer * _Nonnull t) {
      if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
        DOLDebugLog(@"[INPUT] Menu long-press timer fired – posting DOLEmulationRequestExitToLibrary");
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
#ifdef DEBUG
  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
    for (UIPress* p in presses) {
      DOLDebugLog(@"[INPUT] pressesChanged type=%ld force=%.2f timestamp=%.3f", (long)p.type, p.force, p.timestamp);
    }
  }
#endif
#if TARGET_OS_TV
  return;
#else
  [super pressesChanged:presses withEvent:event];
#endif
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
  for (UIPress* press in presses) { if (press.type == UIPressTypeMenu) sMenuPressActive = NO; }
#ifdef DEBUG
  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
    for (UIPress* p in presses) {
      DOLDebugLog(@"[INPUT] pressesEnded type=%ld force=%.2f timestamp=%.3f", (long)p.type, p.force, p.timestamp);
    }
  }
#endif
#if TARGET_OS_TV
  BOOL handledMenu = NO;
  for (UIPress* p in presses) {
    if (p.type != UIPressTypeMenu) continue;
    [[NSNotificationCenter defaultCenter] postNotificationName:DOLMenuPressChangedNotification object:nil
      userInfo:@{@"pressed": @NO, @"cancelled": @(_menuPressOwnedByGame && _menuLongPressTimer == nil)}];
    if (!_menuPressOwnedByGame) continue;
    handledMenu = YES;
    [_menuLongPressTimer invalidate];
    _menuLongPressTimer = nil;
    _menuPressOwnedByGame = NO;
  }
  if (handledMenu)
    return;
#endif
  [super pressesEnded:presses withEvent:event];
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
  for (UIPress* press in presses) { if (press.type == UIPressTypeMenu) sMenuPressActive = NO; }
#if TARGET_OS_TV
  for (UIPress* press in presses) {
    if (press.type == UIPressTypeMenu)
      [[NSNotificationCenter defaultCenter] postNotificationName:DOLMenuPressChangedNotification object:nil
        userInfo:@{@"pressed": @NO, @"cancelled": @YES}];
  }
  _menuPressOwnedByGame = NO;
  if (_menuLongPressTimer) {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
      DOLDebugLog(@"[INPUT] Cancelling Menu long-press timer (press cancelled)");
    }
    [_menuLongPressTimer invalidate];
    _menuLongPressTimer = nil;
  }
  #endif
  [super pressesCancelled:presses withEvent:event];
}

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
    DOLDebugLog(@"[INPUT] Consumed Exit/Back key command (Escape)");
  }
}
#endif

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

@end
