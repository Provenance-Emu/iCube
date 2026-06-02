// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

#import "Core/HW/SI/SI_Device.h"
#import "Core/HW/Wiimote.h"

NS_ASSUME_NONNULL_BEGIN

@interface ControllersSettingsUtil : NSObject

+ (NSString*)getLocalizedStringForSIDevice:(SerialInterface::SIDevices)device;
+ (NSString*)getLocalizedStringForWiimoteSource:(WiimoteSource)source;

// Swift-friendly helpers (avoid exposing C++ enums to Swift)
+ (NSString*)localizedSIDeviceForInt:(int)device;
+ (NSString*)localizedWiimoteSourceForInt:(int)source;

@end

NS_ASSUME_NONNULL_END
