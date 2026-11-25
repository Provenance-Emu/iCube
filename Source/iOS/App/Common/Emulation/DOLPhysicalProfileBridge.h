// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>

NS_ASSUME_NONNULL_BEGIN

/// A `GCController` stand-in the app substitutes for a pad the system exposes without an
/// extended gamepad and that the core binds through its physical profile
/// (`PhysicalProfileController`). The core's MFi device holds the
/// real controller, so anything that resolves a controller to a core device goes through
/// `+[DOLPhysicalProfileBridge baseController:]` first.
@protocol DOLPhysicalBaseController <NSObject>
@property (nonatomic, readonly) GCController* dol_baseController;
@end

/// Swift access to the core's physical-profile mapping
/// (`InputCommon/ControllerInterface/iOS/PhysicalProfileMapping.h`), the single table that
/// decides what each element of such a pad means for GameCube / Wii.
NS_SWIFT_NAME(PhysicalProfileBridge)
@interface DOLPhysicalProfileBridge : NSObject

/// The real controller behind a wrapper, or `controller` itself.
+ (GCController*)baseController:(GCController*)controller;

/// True for the Nintendo Switch Online N64 controller.
+ (BOOL)isN64PadWithVendorName:(nullable NSString*)vendorName
               productCategory:(nullable NSString*)productCategory;

/// True for the Nintendo Switch Online SNES controller (`Switch SNES Controller`).
+ (BOOL)isSnesPadWithVendorName:(nullable NSString*)vendorName
                productCategory:(nullable NSString*)productCategory;

/// True for the Switch Online pads (N64, SNES) the core binds through their physical profile
/// whenever the system gives them no extended gamepad.
+ (BOOL)isSwitchOnlinePadWithVendorName:(nullable NSString*)vendorName
                        productCategory:(nullable NSString*)productCategory;

/// True when the product category names a remote. A remote is never wrapped or bound by position.
+ (BOOL)isRemoteProductCategory:(nullable NSString*)productCategory;

/// Element name -> MFi input name: `Button A`, `R Shoulder`, `Menu`, the C cluster as the
/// R Stick direction it drives (`R Stick Y+`), `D-Pad` / `L Stick` / `R Stick` for
/// direction-pad elements and `L Stick Button` / `R Stick Button` for the stick clicks (the core
/// publishes those as `L Stick` / `R Stick`, the names the stick elements have here). Only usable
/// profiles (a direction input and a face button) return a non-empty dictionary.
///
/// Resolves by name alone, as for a Switch Online pad.
+ (NSDictionary<NSString*, NSString*>*)bindingsForElementNames:(NSArray<NSString*>*)names
                                                      isN64Pad:(BOOL)isN64Pad;

/// The bindings the core uses for a pad, from its element names by kind
/// (`physicalInputProfile.buttons` / `.dpads` / `.axes`). A Switch Online pad and a remote
/// resolve by name alone; any other pad (a plain HID pad) also takes leftover elements by
/// position, and an axis named as a trigger when no button took that trigger. Same values as
/// `bindingsForElementNames:isN64Pad:`.
+ (NSDictionary<NSString*, NSString*>*)bindingsForVendorName:(nullable NSString*)vendorName
                                             productCategory:(nullable NSString*)productCategory
                                                 buttonNames:(NSArray<NSString*>*)buttonNames
                                              directionNames:(NSArray<NSString*>*)directionNames
                                                   axisNames:(NSArray<NSString*>*)axisNames;

/// A trigger read from an axis, in 0...1. `restsAtMinusOne` is the axis's own state: start it at
/// NO and pass the same variable every time; it is set once the axis reports a negative value.
+ (float)triggerValueForAxisValue:(float)value restsAtMinusOne:(BOOL*)restsAtMinusOne;

/// The name of a pad that reports none (`<product category> Gamepad`), as the core names it.
+ (NSString*)fallbackNameForProductCategory:(nullable NSString*)productCategory;

@end

NS_ASSUME_NONNULL_END
