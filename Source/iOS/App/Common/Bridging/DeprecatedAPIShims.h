// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>

@class SentryOptions;

NS_ASSUME_NONNULL_BEGIN

/// Calls to APIs Apple and Sentry have deprecated but that we still need for behavior no replacement
/// covers. They live in one ObjC file so the deprecation is silenced in one place, with the reason next
/// to each call, instead of as a warning in the Swift build.
@interface DeprecatedAPIShims : NSObject

/// Sentry app-hang tracking is paused while a game runs (the main thread idles by design) and resumed
/// after. Sentry deprecates it in favor of MetricKit, which tvOS does not have.
/// Reports only fully blocking hangs (`enableReportNonFullyBlockingAppHangs = NO`), the Sentry default being YES.
+ (void)disableNonFullyBlockingAppHangReportsOn:(SentryOptions*)options;
+ (void)pauseAppHangTracking;
+ (void)resumeAppHangTracking;

/// `GCController.controllerPausedHandler` is deprecated, but setting it is how the system is told the Menu
/// press is claimed; without a handler the press falls through to the system.
+ (void)setPausedHandler:(nullable void (^)(GCController* controller))handler onController:(GCController*)controller;

@end

NS_ASSUME_NONNULL_END
