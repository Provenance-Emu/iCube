#import "DOLWiimoteBridge.h"

#import "Core/Core.h"
#import "Core/System.h"
#include "Core/HW/Wiimote.h"
#include "Core/HW/WiimoteEmu/WiimoteEmu.h"
#include "InputCommon/InputConfig.h"

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
@end
