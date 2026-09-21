// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/// Posted when a hardware Menu button press should open the pause menu.
/// Deliberately a *request*, not `DOLShowPauseMenu`: the Swift side
/// (`PauseGestureTracker.requestPauseMenu`) is the single sink that gates on
/// emulation actually running, coalesces duplicate routes for one physical
/// press, and pauses the core before showing the overlay.
FOUNDATION_EXPORT NSNotificationName const DOLRequestPauseMenuNotification;

#if TARGET_OS_MACCATALYST
@interface EmuEventVC : UIViewController
#else
#import <GameController/GameController.h>

@interface EmuEventVC : GCEventViewController
#endif
@end
