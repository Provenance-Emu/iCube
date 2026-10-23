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

/// Element name -> MFi input name: `Button A`, `R Shoulder`, `Menu`, the C cluster as the
/// R Stick direction it drives (`R Stick Y+`), and `D-Pad` / `L Stick` / `R Stick` for
/// direction-pad elements. Only usable profiles (a direction input and a face button) return
/// a non-empty dictionary.
+ (NSDictionary<NSString*, NSString*>*)bindingsForElementNames:(NSArray<NSString*>*)names
                                                      isN64Pad:(BOOL)isN64Pad;

@end

NS_ASSUME_NONNULL_END
