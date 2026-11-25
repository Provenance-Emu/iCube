// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "DOLPhysicalProfileBridge.h"

#include <string>
#include <vector>

#include "InputCommon/ControllerInterface/iOS/MFiController.h"
#include "InputCommon/ControllerInterface/iOS/PhysicalProfileMapping.h"

namespace PP = ciface::iOS::PhysicalProfile;

namespace
{
std::string ToString(NSString* string)
{
  return std::string([string ?: @"" UTF8String]);
}

std::vector<std::string> ToVector(NSArray<NSString*>* names)
{
  std::vector<std::string> result;
  for (NSString* name in names)
    result.push_back(std::string([name UTF8String]));
  return result;
}

// The value Swift's `SynthesizedInput` knows each input by.
std::string SynthesizedName(PP::Input input)
{
  switch (input)
  {
  case PP::Input::DPad:
    return "D-Pad";
  case PP::Input::LeftStick:
    return "L Stick";
  case PP::Input::RightStick:
    return "R Stick";
  case PP::Input::LStickButton:
    return "L Stick Button";
  case PP::Input::RStickButton:
    return "R Stick Button";
  default:
    return PP::InputName(input);
  }
}

NSDictionary<NSString*, NSString*>* ToDictionary(const PP::Bindings& bindings)
{
  if (!PP::IsUsable(bindings))
    return @{};

  NSMutableDictionary<NSString*, NSString*>* result = [NSMutableDictionary dictionary];
  for (const auto& [name, input] : bindings)
  {
    result[[NSString stringWithUTF8String:name.c_str()]] =
        [NSString stringWithUTF8String:SynthesizedName(input).c_str()];
  }
  return result;
}
}  // namespace

@implementation DOLPhysicalProfileBridge

+ (GCController*)baseController:(GCController*)controller
{
  if ([controller conformsToProtocol:@protocol(DOLPhysicalBaseController)])
    return [(id<DOLPhysicalBaseController>)controller dol_baseController];
  return controller;
}

+ (BOOL)isN64PadWithVendorName:(NSString*)vendorName productCategory:(NSString*)productCategory
{
  return PP::IsN64Pad(std::string([vendorName ?: @"" UTF8String]),
                      std::string([productCategory ?: @"" UTF8String]));
}

+ (BOOL)isSnesPadWithVendorName:(NSString*)vendorName productCategory:(NSString*)productCategory
{
  return PP::IsSnesPad(std::string([vendorName ?: @"" UTF8String]),
                       std::string([productCategory ?: @"" UTF8String]));
}

+ (BOOL)isSwitchOnlinePadWithVendorName:(NSString*)vendorName
                        productCategory:(NSString*)productCategory
{
  return PP::IsSwitchOnlinePad(std::string([vendorName ?: @"" UTF8String]),
                               std::string([productCategory ?: @"" UTF8String]));
}

+ (BOOL)isRemoteProductCategory:(NSString*)productCategory
{
  return PP::IsRemote(ToString(productCategory));
}

+ (NSDictionary<NSString*, NSString*>*)bindingsForElementNames:(NSArray<NSString*>*)names
                                                      isN64Pad:(BOOL)isN64Pad
{
  return ToDictionary(PP::ResolveBindings(ToVector(names), isN64Pad));
}

+ (NSDictionary<NSString*, NSString*>*)bindingsForVendorName:(NSString*)vendorName
                                             productCategory:(NSString*)productCategory
                                                 buttonNames:(NSArray<NSString*>*)buttonNames
                                              directionNames:(NSArray<NSString*>*)directionNames
                                                   axisNames:(NSArray<NSString*>*)axisNames
{
  return ToDictionary(PP::ResolveForPad(ToString(vendorName), ToString(productCategory),
                                        ToVector(buttonNames), ToVector(directionNames),
                                        ToVector(axisNames)));
}

+ (NSDictionary<NSString*, NSString*>*)bindingsForController:(GCController*)controller
{
  return ToDictionary(
      ciface::iOS::MFiController::PhysicalBindingsFor([self baseController:controller]));
}

+ (NSString*)preferredNameAmongAliases:(NSArray<NSString*>*)aliases
{
  return [NSString stringWithUTF8String:PP::PreferredName(ToVector(aliases)).c_str()];
}

+ (float)triggerValueForAxisValue:(float)value restsAtMinusOne:(BOOL*)restsAtMinusOne
{
  bool rests = *restsAtMinusOne;
  const float result = PP::TriggerValueFromAxis(value, rests);
  *restsAtMinusOne = rests;
  return result;
}

+ (NSString*)fallbackNameForProductCategory:(NSString*)productCategory
{
  return [NSString stringWithUTF8String:PP::FallbackName(ToString(productCategory)).c_str()];
}

+ (NSString*)coreNameForController:(GCController*)controller
{
  const std::string name = ciface::iOS::MFiController::NameFor([self baseController:controller]);
  return [NSString stringWithUTF8String:name.c_str()];
}

@end
