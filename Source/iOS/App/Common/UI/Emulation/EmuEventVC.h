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

/// Posted when the user asks to recenter the Wii pointer (pause menu / top bar action). The touch
/// IR pads observe it to drop their drag state; the gyro pointer is recentered directly through
/// `TCDeviceMotion.recenterPointer`.
FOUNDATION_EXPORT NSNotificationName const DOLRecenterPointerNotification;

/// How long Menu must be held to exit to the library. A release before this is a
/// short press and opens the pause menu instead. Exported so the GCController
/// Menu handlers use the same threshold as the UIPress path.
FOUNDATION_EXPORT const NSTimeInterval DOLMenuLongPressDuration;

#if TARGET_OS_MACCATALYST
@interface EmuEventVC : UIViewController
#else
#import <GameController/GameController.h>

@interface EmuEventVC : GCEventViewController
#endif
@end
