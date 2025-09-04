#import "DOLWiimoteBridge.h"

#import "Core/Core.h"
#import "Core/System.h"
#include "Core/HW/Wiimote.h"
#include "Core/HW/WiimoteEmu/WiimoteEmu.h"
#include "InputCommon/InputConfig.h"
#include "InputCommon/ControllerEmu/ControlGroup/Attachments.h"
#include "InputCommon/ControllerEmu/Setting/NumericSetting.h"

@implementation DOLWiimoteBridge
+ (BOOL)isClassicActiveForWiimote:(NSInteger)index
{
  if (!Wiimote::GetConfig() || Wiimote::GetConfig()->GetControllerCount() <= index) return NO;
  auto* wm_base = Wiimote::GetConfig()->GetController((int)index);
  if (!wm_base) return NO;
  auto* wm = static_cast<WiimoteEmu::Wiimote*>(wm_base);
  return wm->GetActiveExtensionNumber() == WiimoteEmu::ExtensionNumber::CLASSIC;
}

+ (BOOL)isSidewaysForWiimote:(NSInteger)index
{
  if (!Wiimote::GetConfig() || Wiimote::GetConfig()->GetControllerCount() <= index) return NO;
  auto* wm_base = Wiimote::GetConfig()->GetController((int)index);
  if (!wm_base) return NO;
  auto* wm = static_cast<WiimoteEmu::Wiimote*>(wm_base);
  return wm->IsSideways();
}

+ (void)setExtensionForWiimote:(NSInteger)index extension:(NSInteger)extRaw
{
  if (!Wiimote::GetConfig() || Wiimote::GetConfig()->GetControllerCount() <= index) return;
  auto* wm_base = Wiimote::GetConfig()->GetController((int)index);
  if (!wm_base) return;
  auto* wm = static_cast<WiimoteEmu::Wiimote*>(wm_base);
  auto* attachments = static_cast<ControllerEmu::Attachments*>(wm->GetWiimoteGroup(WiimoteEmu::WiimoteGroup::Attachments));
  if (!attachments) return;
  int maxVal = (int)WiimoteEmu::ExtensionNumber::MAX - 1;
  int val = std::max(0, std::min((int)extRaw, maxVal));
  attachments->GetSelectionSetting().SetValue(val);
}

+ (void)setSidewaysForWiimote:(NSInteger)index enabled:(BOOL)enabled
{
  if (!Wiimote::GetConfig() || Wiimote::GetConfig()->GetControllerCount() <= index) return;
  auto* wm_base = Wiimote::GetConfig()->GetController((int)index);
  if (!wm_base) return;
  auto* wm = static_cast<WiimoteEmu::Wiimote*>(wm_base);
  auto* options = wm->GetWiimoteGroup(WiimoteEmu::WiimoteGroup::Options);
  if (!options) return;
  for (auto& setting : options->numeric_settings) {
    if (setting->GetType() == ControllerEmu::SettingType::Bool && std::string(setting->GetININame()) == WiimoteEmu::Wiimote::SIDEWAYS_OPTION) {
      // Cast to bool numeric setting and set
      auto* boolSetting = static_cast<ControllerEmu::NumericSetting<bool>*>(setting.get());
      boolSetting->SetValue((bool)enabled);
      break;
    }
  }
}
@end
