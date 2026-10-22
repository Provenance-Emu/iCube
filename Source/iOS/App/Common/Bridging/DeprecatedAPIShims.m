// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "DeprecatedAPIShims.h"

@import Sentry;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@implementation DeprecatedAPIShims

+ (void)disableNonFullyBlockingAppHangReportsOn:(SentryOptions*)options {
  options.enableReportNonFullyBlockingAppHangs = NO;
}

+ (void)pauseAppHangTracking {
  [SentrySDK pauseAppHangTracking];
}

+ (void)resumeAppHangTracking {
  [SentrySDK resumeAppHangTracking];
}

+ (void)setPausedHandler:(void (^)(GCController* controller))handler onController:(GCController*)controller {
  controller.controllerPausedHandler = handler;
}

@end

#pragma clang diagnostic pop
