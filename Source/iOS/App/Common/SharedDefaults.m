// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
#import "SharedDefaults.h"

NSString * const DOLAppGroupIdentifier = @"group.com.joemattiello.icube";

NSUserDefaults *DOLSharedUserDefaults(void) {
  static NSUserDefaults *shared = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSURL *container = [[NSFileManager defaultManager]
        containerURLForSecurityApplicationGroupIdentifier:DOLAppGroupIdentifier];
    NSUserDefaults *suite = container ? [[NSUserDefaults alloc] initWithSuiteName:DOLAppGroupIdentifier] : nil;
    shared = suite ?: [NSUserDefaults standardUserDefaults];
  });
  return shared;
}
