// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "InputOverriderBridge.h"

#import <TargetConditionals.h>
#if TARGET_OS_TV
#include "InputCommon/ControllerInterface/Touch/InputOverrider.h"
#endif

@implementation InputOverriderBridge

+ (void)registerGameCubeOverrideForController:(NSInteger)index {
#if TARGET_OS_TV
	ciface::Touch::RegisterGameCubeInputOverrider((int)index);
#endif
}

+ (void)unregisterGameCubeOverrideForController:(NSInteger)index {
#if TARGET_OS_TV
	ciface::Touch::UnregisterGameCubeInputOverrider((int)index);
#endif
}

+ (void)setControl:(IOControlID)control controller:(NSInteger)index value:(double)value {
#if TARGET_OS_TV
	ciface::Touch::SetControlState((int)index, (ciface::Touch::ControlID)control, value);
#endif
}

+ (void)clearControl:(IOControlID)control controller:(NSInteger)index {
#if TARGET_OS_TV
	ciface::Touch::ClearControlState((int)index, (ciface::Touch::ControlID)control);
#endif
}

@end
