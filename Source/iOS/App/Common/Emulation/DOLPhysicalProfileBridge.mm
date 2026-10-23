// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "DOLPhysicalProfileBridge.h"

#include <string>
#include <vector>

#include "InputCommon/ControllerInterface/iOS/PhysicalProfileMapping.h"

namespace PP = ciface::iOS::PhysicalProfile;

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

+ (NSDictionary<NSString*, NSString*>*)bindingsForElementNames:(NSArray<NSString*>*)names
                                                      isN64Pad:(BOOL)isN64Pad
{
  std::vector<std::string> element_names;
  for (NSString* name in names)
    element_names.push_back(std::string([name UTF8String]));

  const PP::Bindings bindings = PP::ResolveBindings(element_names, isN64Pad);
  if (!PP::IsUsable(bindings))
    return @{};

  NSMutableDictionary<NSString*, NSString*>* result = [NSMutableDictionary dictionary];
  for (const auto& [name, input] : bindings)
  {
    std::string input_name;
    switch (input)
    {
    case PP::Input::DPad:
      input_name = "D-Pad";
      break;
    case PP::Input::LeftStick:
      input_name = "L Stick";
      break;
    case PP::Input::RightStick:
      input_name = "R Stick";
      break;
    default:
      input_name = PP::InputName(input);
      break;
    }
    result[[NSString stringWithUTF8String:name.c_str()]] =
        [NSString stringWithUTF8String:input_name.c_str()];
  }
  return result;
}

@end
