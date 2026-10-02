// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "DOLControllerSettingsBridge.h"

#include <algorithm>
#include <cmath>
#include <string>

#include "Core/HW/GCPad.h"
#include "Core/HW/GCPadEmu.h"
#include "Core/HW/Wiimote.h"
#include "Core/HW/WiimoteEmu/Extension/Classic.h"
#include "Core/HW/WiimoteEmu/Extension/Nunchuk.h"
#include "Core/HW/WiimoteEmu/WiimoteEmu.h"
#include "InputCommon/ControlReference/ExpressionParser.h"
#include "InputCommon/ControllerEmu/ControlGroup/ControlGroup.h"
#include "InputCommon/ControllerEmu/ControllerEmu.h"
#include "InputCommon/ControllerEmu/Setting/NumericSetting.h"
#include "InputCommon/InputConfig.h"
#include "FoundationStringUtil.h"
#include "LocalizationUtil.h"

@interface DOLExpressionParseResult ()
@property (nonatomic, readwrite) DOLExpressionStatus status;
@property (nonatomic, readwrite, copy, nullable) NSString* message;
@end

@implementation DOLExpressionParseResult
@end

@interface DOLNumericSettingInfo ()
@property (nonatomic, readwrite) NSInteger index;
@property (nonatomic, readwrite, copy) NSString* name;
@property (nonatomic, readwrite, copy) NSString* suffix;
@property (nonatomic, readwrite) DOLNumericSettingType type;
@property (nonatomic, readwrite) double value;
@property (nonatomic, readwrite) double minimum;
@property (nonatomic, readwrite) double maximum;
@property (nonatomic, readwrite) double defaultValue;
@property (nonatomic, readwrite) BOOL isExpression;
@end

@implementation DOLNumericSettingInfo
@end

// The owner's input config, or nullptr before it is loaded or for a port it does not have.
static InputConfig* ConfigFor(DOLControlGroupOwner owner, int index)
{
  InputConfig* config = owner == DOLControlGroupOwnerGCPad ? Pad::GetConfig() : Wiimote::GetConfig();
  if (!config || index < 0 || index >= config->GetControllerCount())
    return nullptr;
  return config;
}

// Same dispatch as TVControllerMappingBridge's group lookups, for all four owners.
static ControllerEmu::ControlGroup* GroupFor(DOLControlGroupOwner owner, NSInteger portOneBased, NSInteger groupId)
{
  const int index = static_cast<int>(portOneBased - 1);
  if (!ConfigFor(owner, index))
    return nullptr;
  switch (owner)
  {
  case DOLControlGroupOwnerGCPad:
    return Pad::GetGroup(index, static_cast<PadGroup>(groupId));
  case DOLControlGroupOwnerWiimote:
    return Wiimote::GetWiimoteGroup(index, static_cast<WiimoteEmu::WiimoteGroup>(groupId));
  case DOLControlGroupOwnerNunchuk:
    return Wiimote::GetNunchukGroup(index, static_cast<WiimoteEmu::NunchukGroup>(groupId));
  case DOLControlGroupOwnerClassic:
    return Wiimote::GetClassicGroup(index, static_cast<WiimoteEmu::ClassicGroup>(groupId));
  }
  return nullptr;
}

static void SaveConfigFor(DOLControlGroupOwner owner)
{
  InputConfig* config = owner == DOLControlGroupOwnerGCPad ? Pad::GetConfig() : Wiimote::GetConfig();
  if (config)
    config->SaveConfig();
}

@implementation DOLControllerSettingsBridge

+ (DOLExpressionParseResult*)parseExpression:(NSString*)expression
{
  DOLExpressionParseResult* result = [[DOLExpressionParseResult alloc] init];
  const auto parsed = ciface::ExpressionParser::ParseExpression(FoundationToCppString(expression));
  switch (parsed.status)
  {
  case ciface::ExpressionParser::ParseStatus::Successful:
    result.status = DOLExpressionStatusSuccessful;
    break;
  case ciface::ExpressionParser::ParseStatus::SyntaxError:
    result.status = DOLExpressionStatusSyntaxError;
    if (parsed.description)
      result.message = CToFoundationString(parsed.description->c_str());
    break;
  case ciface::ExpressionParser::ParseStatus::EmptyExpression:
    result.status = DOLExpressionStatusEmpty;
    break;
  }
  return result;
}

+ (NSArray<DOLNumericSettingInfo*>*)numericSettingsForOwner:(DOLControlGroupOwner)owner
                                                       port:(NSInteger)portOneBased
                                                      group:(NSInteger)groupId
{
  NSMutableArray<DOLNumericSettingInfo*>* result = [NSMutableArray array];
  auto* group = GroupFor(owner, portOneBased, groupId);
  if (!group)
    return result;
  const auto lock = ControllerEmu::EmulatedController::GetStateLock();
  NSInteger index = 0;
  for (const auto& setting : group->numeric_settings)
  {
    DOLNumericSettingInfo* info = [[DOLNumericSettingInfo alloc] init];
    info.index = index++;
    info.name = DOLCoreLocalizedString(CToFoundationString(setting->GetUIName()));
    const char* suffix = setting->GetUISuffix();
    info.suffix = suffix ? DOLCoreLocalizedString(CToFoundationString(suffix)) : @"";
    info.isExpression = !setting->IsSimpleValue();
    switch (setting->GetType())
    {
    case ControllerEmu::SettingType::Int:
    {
      const auto* typed = static_cast<const ControllerEmu::NumericSetting<int>*>(setting.get());
      info.type = DOLNumericSettingTypeInt;
      info.value = typed->GetValue();
      info.minimum = typed->GetMinValue();
      info.maximum = typed->GetMaxValue();
      info.defaultValue = typed->GetDefaultValue();
      break;
    }
    case ControllerEmu::SettingType::Double:
    {
      const auto* typed = static_cast<const ControllerEmu::NumericSetting<double>*>(setting.get());
      info.type = DOLNumericSettingTypeDouble;
      info.value = typed->GetValue();
      info.minimum = typed->GetMinValue();
      info.maximum = typed->GetMaxValue();
      info.defaultValue = typed->GetDefaultValue();
      break;
    }
    case ControllerEmu::SettingType::Bool:
    {
      const auto* typed = static_cast<const ControllerEmu::NumericSetting<bool>*>(setting.get());
      info.type = DOLNumericSettingTypeBool;
      info.value = typed->GetValue() ? 1 : 0;
      info.minimum = 0;
      info.maximum = 1;
      info.defaultValue = typed->GetDefaultValue() ? 1 : 0;
      break;
    }
    }
    [result addObject:info];
  }
  return result;
}

+ (void)setNumericSettingValue:(double)value
                         index:(NSInteger)settingIndex
                         owner:(DOLControlGroupOwner)owner
                          port:(NSInteger)portOneBased
                         group:(NSInteger)groupId
{
  // NaN or an infinity has no meaningful clamp or round (lround of either is undefined), and a
  // Bool setting would read NaN as "on". Refuse before touching the setting.
  if (!std::isfinite(value))
    return;
  auto* group = GroupFor(owner, portOneBased, groupId);
  if (!group || settingIndex < 0 || static_cast<size_t>(settingIndex) >= group->numeric_settings.size())
    return;
  {
    // The CPU thread reads these settings; Dolphin's own UI holds the state lock to change them.
    const auto lock = ControllerEmu::EmulatedController::GetStateLock();
    auto* setting = group->numeric_settings[settingIndex].get();
    switch (setting->GetType())
    {
    case ControllerEmu::SettingType::Int:
    {
      auto* typed = static_cast<ControllerEmu::NumericSetting<int>*>(setting);
      typed->SetValue(std::clamp(static_cast<int>(std::lround(value)), typed->GetMinValue(), typed->GetMaxValue()));
      break;
    }
    case ControllerEmu::SettingType::Double:
    {
      auto* typed = static_cast<ControllerEmu::NumericSetting<double>*>(setting);
      typed->SetValue(std::clamp(value, typed->GetMinValue(), typed->GetMaxValue()));
      break;
    }
    case ControllerEmu::SettingType::Bool:
      static_cast<ControllerEmu::NumericSetting<bool>*>(setting)->SetValue(value != 0);
      break;
    }
  }
  SaveConfigFor(owner);
}

+ (BOOL)isGroupEnabledForOwner:(DOLControlGroupOwner)owner port:(NSInteger)portOneBased group:(NSInteger)groupId
{
  auto* group = GroupFor(owner, portOneBased, groupId);
  if (!group || !group->enabled_setting)
    return NO;
  const auto lock = ControllerEmu::EmulatedController::GetStateLock();
  return group->enabled.GetValue() ? YES : NO;
}

+ (void)setGroupEnabled:(BOOL)enabled owner:(DOLControlGroupOwner)owner port:(NSInteger)portOneBased group:(NSInteger)groupId
{
  auto* group = GroupFor(owner, portOneBased, groupId);
  if (!group || !group->enabled_setting)
    return;
  {
    const auto lock = ControllerEmu::EmulatedController::GetStateLock();
    group->enabled_setting->SetValue(enabled == YES);
  }
  SaveConfigFor(owner);
}

@end
