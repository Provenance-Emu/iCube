// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <TargetConditionals.h>

#if TARGET_OS_IOS

#import "DOLUIKitSwitch.h"
typedef DOLUIKitSwitch DOLSwitch;

#elif TARGET_OS_TV

#import "DolphiniOS-Swift.h"
typedef DOLTVSwitch DOLSwitch;

#else

#error Unsupported platform

#endif
