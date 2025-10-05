// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "TVControllerMappingBridge.h"

// Dolphin includes
#include "InputCommon/ControllerInterface/ControllerInterface.h"
#include "InputCommon/ControllerInterface/iOS/MFiController.h"
#include "Core/HW/GCPad.h"
#include "Core/HW/Wiimote.h"
#include "Core/HW/WiimoteEmu/WiimoteEmu.h"
#include "InputCommon/InputConfig.h"
#include "InputCommon/ControllerEmu/ControllerEmu.h"
#include "InputCommon/ControllerEmu/ControlGroup/Attachments.h"
#include "InputCommon/ControllerInterface/MappingCommon.h"
#include "Core/ConfigManager.h"
#include "Common/FileUtil.h"
#include "Common/FileSearch.h"
#include "Common/IniFile.h"
#include "FoundationStringUtil.h"
#include "LocalizationUtil.h"
#include <unordered_set>

NSString* const TVControllerDevicesChangedNotification = @"TVControllerDevicesChangedNotification";

@implementation TVControllerMappingBridge

static ControllerInterface::HotplugCallbackHandle s_hotplugHandle;
static BOOL s_posting = NO;

static inline bool IsDisconnectedPlaceholder(const std::shared_ptr<ciface::Core::Device>& dev)
{
  if (!dev) return true;
  const std::string q = dev->GetQualifiedName();
  const std::string n = dev->GetName();
  auto contains_dis = [](const std::string& s) {
    for (size_t i = 0; i + 11 <= s.size(); ++i) {
      char c0 = s[i];
      // compare case-insensitively for "disconnected"
      if ((c0 == 'd' || c0 == 'D') && strncasecmp(s.c_str() + i, "disconnected", 12) == 0) return true;
    }
    return false;
  };
  return contains_dis(q) || contains_dis(n);
}

+ (void)beginPostingDevicesChangedNotifications
{
  if (s_posting) return;
  if (!g_controller_interface.IsInit()) {
    // Retry registration shortly until ControllerInterface is ready
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [self beginPostingDevicesChangedNotifications];
    });
    return;
  }
  __weak Class weakSelf = self;
  s_hotplugHandle = g_controller_interface.RegisterDevicesChangedCallback([weakSelf]() {
    dispatch_async(dispatch_get_main_queue(), ^{
      [[NSNotificationCenter defaultCenter] postNotificationName:TVControllerDevicesChangedNotification object:nil];
    });
  });
  s_posting = YES;
}

+ (void)endPostingDevicesChangedNotifications
{
  if (!s_posting) return;
  if (g_controller_interface.IsInit()) {
    g_controller_interface.UnregisterDevicesChangedCallback(s_hotplugHandle);
  }
  s_posting = NO;
}

+ (NSString*)qualifiedNameForController:(GCController*)controller
{
  std::string qualifier;
  const auto devices = g_controller_interface.GetAllDevices();
  for (const auto& dev : devices)
  {
    if (!dev || dev->GetSource() != "MFi" || IsDisconnectedPlaceholder(dev))
      continue;
    const auto* mfi = dynamic_cast<const ciface::iOS::MFiController*>(dev.get());
    if (mfi && mfi->IsSameController(controller))
    {
      qualifier = dev->GetQualifiedName();
      break;
    }
  }
  return [NSString stringWithUTF8String:qualifier.c_str()];
}

+ (void)assignController:(GCController*)controller toGCPort:(NSInteger)portOneBased
{
  if (portOneBased < 1 || portOneBased > 4)
    return;

  NSString* q = [self qualifiedNameForController:controller];
  if (q.length == 0)
  {
    // Fallback: if we cannot match the specific GCController, pick the first connected MFi device
    const auto devices = g_controller_interface.GetAllDevices();
    for (const auto& dev : devices)
    {
      if (dev && dev->GetSource() == std::string("MFi") && !IsDisconnectedPlaceholder(dev)) { q = [NSString stringWithUTF8String:dev->GetQualifiedName().c_str()]; break; }
    }
    if (q.length == 0)
      return;
  }

  auto* cfg = Pad::GetConfig();
  if (!cfg)
    return;
  const int port = static_cast<int>(portOneBased - 1);
  auto* pad = cfg->GetController(port);
  if (!pad)
    return;
  pad->SetDefaultDevice([q UTF8String]);
  // Load default bindings for this device, then refresh references
  pad->LoadDefaults(g_controller_interface);
  pad->UpdateReferences(g_controller_interface);
  Pad::GetConfig()->SaveConfig();

  controller.playerIndex = (GCControllerPlayerIndex)port;
}

+ (NSString*)defaultDeviceForGCPort:(NSInteger)portOneBased
{
  auto* cfg = Pad::GetConfig();
  if (!cfg)
    return @"";
  const int port = static_cast<int>(portOneBased - 1);
  auto* pad = cfg->GetController(port);
  if (!pad)
    return @"";
  const auto def = pad->GetDefaultDevice().ToString();
  return [NSString stringWithUTF8String:def.c_str()];
}

+ (void)clearDefaultDeviceForGCPort:(NSInteger)portOneBased
{
  auto* cfg = Pad::GetConfig();
  if (!cfg)
    return;
  const int port = static_cast<int>(portOneBased - 1);
  auto* pad = cfg->GetController(port);
  if (!pad)
    return;
  pad->SetDefaultDevice("");
  pad->UpdateReferences(g_controller_interface);
}

+ (void)reconcileAssignments
{
  auto* cfg = Pad::GetConfig();
  if (!cfg)
    return;

  // Build set of qualified names for currently enumerated physical devices (MFi/DSU)
  std::unordered_set<std::string> connected_qnames;
  const auto devices = g_controller_interface.GetAllDevices();
  for (const auto& dev : devices)
  {
    if (!dev || IsDisconnectedPlaceholder(dev))
      continue;
    const std::string src = dev->GetSource();
    if (src == "MFi" || src == "DSUClient")
      connected_qnames.insert(dev->GetQualifiedName());
  }

  // Clear phantom defaults
  const int count = cfg->GetControllerCount();
  bool did_mutate = false;
  for (int i = 0; i < count; ++i)
  {
    auto* pad = cfg->GetController(i);
    if (!pad) continue;
    const auto dq = pad->GetDefaultDevice();
    const auto q = dq.ToString();
    if (!q.empty() && connected_qnames.find(q) == connected_qnames.end())
    {
      if (!(dq.source == "iOS" && dq.name == "Touchscreen"))
      {
        pad->SetDefaultDevice("");
        pad->UpdateReferences(g_controller_interface);
        did_mutate = true;
      }
    }
  }

  // Unified policy:
  // 1) If any port has a connected physical device assigned, respect user assignments and stop.
  // 2) Otherwise, if a physical device is connected, assign it to Pad 1.
  // 3) Otherwise, assign Touchscreen to Pad 1.

  bool any_connected_physical_assigned = false;
  for (int i = 0; i < count && !any_connected_physical_assigned; ++i)
  {
    auto* pad = cfg->GetController(i);
    if (!pad) continue;
    const auto dq = pad->GetDefaultDevice();
    const bool is_touch = (dq.source == "iOS" && dq.name == "Touchscreen");
    if (!is_touch && connected_qnames.find(dq.ToString()) != connected_qnames.end())
      any_connected_physical_assigned = true;
  }

  if (any_connected_physical_assigned)
  {
    if (did_mutate) Pad::GetConfig()->SaveConfig();
    return;
  }

  // Try to find a connected physical device to assign to Pad 1
  std::shared_ptr<ciface::Core::Device> candidate_physical;
  for (const auto& dev : devices)
  {
    if (!dev || IsDisconnectedPlaceholder(dev))
      continue;
    const std::string src = dev->GetSource();
    if (!(src == "MFi" || src == "DSUClient"))
      continue;
    // Skip if already assigned anywhere
    ciface::Core::DeviceQualifier dq_new; dq_new.FromDevice(dev.get());
    bool already = false;
    for (int i = 0; i < count; ++i)
    {
      auto* pad = cfg->GetController(i);
      if (pad && pad->GetDefaultDevice() == dq_new) { already = true; break; }
    }
    if (!already) { candidate_physical = dev; break; }
  }

  if (candidate_physical)
  {
    auto* pad1 = cfg->GetController(0);
    if (pad1)
    {
      ciface::Core::DeviceQualifier dq_new; dq_new.FromDevice(candidate_physical.get());
      if (!(pad1->GetDefaultDevice() == dq_new))
      {
        pad1->SetDefaultDevice(dq_new);
        pad1->LoadDefaults(g_controller_interface);
        pad1->UpdateReferences(g_controller_interface);
        did_mutate = true;
      }
    }
    if (did_mutate) Pad::GetConfig()->SaveConfig();
    return;
  }

  // No physicals connected: ensure Touchscreen on Pad 1
  [self assignTouchscreenToGCPort:1];
  // assignTouchscreenToGCPort saves config
}

+ (void)assignTouchscreenToGCPort:(NSInteger)portOneBased
{
  if (portOneBased < 1 || portOneBased > 4)
    return;
  auto* cfg = Pad::GetConfig();
  if (!cfg)
    return;
  const auto devices = g_controller_interface.GetAllDevices();
  std::shared_ptr<ciface::Core::Device> touchscreen_dev;
  for (const auto& dev : devices)
  {
    if (dev && dev->GetSource() == std::string("iOS") && dev->GetName() == std::string("Touchscreen"))
    {
      touchscreen_dev = dev; break;
    }
  }
  if (!touchscreen_dev)
    return;
  ciface::Core::DeviceQualifier dq; dq.FromDevice(touchscreen_dev.get());
  const int port = (int)portOneBased - 1;
  auto* pad = cfg->GetController(port);
  if (!pad) return;
  pad->SetDefaultDevice(dq);
  bool loaded_profile = false;
  {
    const std::string sysDir = pad->GetConfig()->GetSysProfileDirectoryPath();
    const std::string userDir = pad->GetConfig()->GetUserProfileDirectoryPath();
    const std::string sysProfile = sysDir + (sysDir.empty() || sysDir.back() == '/' ? "" : "/") + std::string("Touchscreen.ini");
    const std::string userProfile = userDir + (userDir.empty() || userDir.back() == '/' ? "" : "/") + std::string("Touchscreen.ini");

    Common::IniFile ini;
    if (File::Exists(userProfile) && ini.Load(userProfile))
    {
      pad->LoadConfig(ini.GetOrCreateSection("Profile"));
      loaded_profile = true;
    }
    else if (File::Exists(sysProfile) && ini.Load(sysProfile))
    {
      pad->LoadConfig(ini.GetOrCreateSection("Profile"));
      loaded_profile = true;
    }
  }

  if (!loaded_profile)
  {
    // Fallback to defaults, then ensure Touchscreen stays the default device
    pad->LoadDefaults(g_controller_interface);
    pad->SetDefaultDevice(dq);
  }

  pad->UpdateReferences(g_controller_interface);
  Pad::GetConfig()->SaveConfig();
}

+ (NSArray<NSString*>*)allQualifiedDevices
{
  NSMutableArray<NSString*>* result = [NSMutableArray array];
  // Enumerate current devices (hotplug callback will post updates)
  const auto devices = g_controller_interface.GetAllDevices();
  for (const auto& dev : devices)
  {
    if (!dev || IsDisconnectedPlaceholder(dev))
      continue;
    const std::string src = dev->GetSource();
    if (src == "iOS" || src == "MFi" || src == "DSUClient")
    {
      [result addObject:[NSString stringWithUTF8String:dev->GetQualifiedName().c_str()]];
    }
  }
  return result;
}

+ (void)setDefaultDevice:(NSString*)qualified forGCPort:(NSInteger)portOneBased
{
  auto* cfg = Pad::GetConfig();
  if (!cfg) return;
  const int port = (int)portOneBased - 1;
  auto* pad = cfg->GetController(port);
  if (!pad) return;
  pad->SetDefaultDevice([qualified UTF8String]);
  pad->UpdateReferences(g_controller_interface);
  Pad::GetConfig()->SaveConfig();
}

+ (NSString*)defaultDeviceForWiimote:(NSInteger)indexOneBased
{
  auto* cfg = Wiimote::GetConfig();
  if (!cfg) return @"";
  const int idx = (int)indexOneBased - 1;
  auto* wm = cfg->GetController(idx);
  if (!wm) return @"";
  const auto def = wm->GetDefaultDevice().ToString();
  return [NSString stringWithUTF8String:def.c_str()];
}

+ (void)setDefaultDevice:(NSString*)qualified forWiimote:(NSInteger)indexOneBased
{
  auto* cfg = Wiimote::GetConfig();
  if (!cfg) return;
  const int idx = (int)indexOneBased - 1;
  auto* wm = cfg->GetController(idx);
  if (!wm) return;
  wm->SetDefaultDevice([qualified UTF8String]);
  wm->UpdateReferences(g_controller_interface);
  Wiimote::GetConfig()->SaveConfig();
}

+ (NSArray<NSString*>*)inputsForQualifiedDevice:(NSString*)qualified
{
  NSMutableArray<NSString*>* names = [NSMutableArray array];
  ciface::Core::DeviceQualifier dq; dq.FromString([qualified UTF8String]);
  auto dev = g_controller_interface.FindDevice(dq);
  if (!dev)
    return names;
  for (const auto& input : dev->Inputs())
  {
    [names addObject:[NSString stringWithUTF8String:input->GetName().c_str()]];
  }
  return names;
}

+ (NSArray<NSNumber*>*)inputStatesForQualifiedDevice:(NSString*)qualified
{
  NSMutableArray<NSNumber*>* values = [NSMutableArray array];
  ciface::Core::DeviceQualifier dq; dq.FromString([qualified UTF8String]);
  auto dev = g_controller_interface.FindDevice(dq);
  if (!dev)
    return values;
  for (const auto& input : dev->Inputs())
  {
    [values addObject:@(input->GetState())];
  }
  return values;
}

+ (NSArray<NSString*>*)wiimoteAttachmentDisplayNamesForIndex:(NSInteger)indexOneBased
{
  NSMutableArray<NSString*>* result = [NSMutableArray array];
  const int idx = (int)indexOneBased - 1;
  auto* attachments = static_cast<ControllerEmu::Attachments*>(Wiimote::GetWiimoteGroup(idx, WiimoteEmu::WiimoteGroup::Attachments));
  if (!attachments) return result;
  for (const auto& att : attachments->GetAttachmentList())
  {
    [result addObject:[NSString stringWithUTF8String:att->GetDisplayName().c_str()]];
  }
  return result;
}

+ (NSInteger)selectedWiimoteAttachmentForIndex:(NSInteger)indexOneBased
{
  const int idx = (int)indexOneBased - 1;
  auto* attachments = static_cast<ControllerEmu::Attachments*>(Wiimote::GetWiimoteGroup(idx, WiimoteEmu::WiimoteGroup::Attachments));
  if (!attachments) return 0;
  return (NSInteger)attachments->GetSelectedAttachment();
}

+ (void)setSelectedWiimoteAttachment:(NSInteger)attachmentIndex forWiimote:(NSInteger)indexOneBased
{
  const int idx = (int)indexOneBased - 1;
  auto* attachments = static_cast<ControllerEmu::Attachments*>(Wiimote::GetWiimoteGroup(idx, WiimoteEmu::WiimoteGroup::Attachments));
  if (!attachments) return;
  attachments->SetSelectedAttachment((u32)attachmentIndex);
}

+ (NSArray<NSString*>*)profilesForGCPort:(NSInteger)portOneBased
{
  NSMutableArray<NSString*>* result = [NSMutableArray array];
  auto* cfg = Pad::GetConfig();
  if (!cfg) return result;
  const int port = (int)portOneBased - 1;
  auto* pad = cfg->GetController(port);
  if (!pad) return result;
  std::unordered_set<std::string> names;
  for (const auto& filename : Common::DoFileSearch({pad->GetConfig()->GetUserProfileDirectoryPath()}, {".ini"}))
  {
    std::string basename;
    SplitPath(filename, nullptr, &basename, nullptr);
    if (!basename.empty()) names.insert(basename);
  }
  for (const auto& filename : Common::DoFileSearch({pad->GetConfig()->GetSysProfileDirectoryPath()}, {".ini"}))
  {
    std::string basename;
    SplitPath(filename, nullptr, &basename, nullptr);
    if (!basename.empty()) names.insert(basename);
  }
  for (const auto& n : names) { [result addObject:[NSString stringWithUTF8String:n.c_str()]]; }
  return result;
}

+ (NSArray<NSString*>*)profilesForWiimote:(NSInteger)indexOneBased
{
  NSMutableArray<NSString*>* result = [NSMutableArray array];
  auto* cfg = Wiimote::GetConfig();
  if (!cfg) return result;
  const int idx = (int)indexOneBased - 1;
  auto* wm = cfg->GetController(idx);
  if (!wm) return result;
  std::unordered_set<std::string> names;
  for (const auto& filename : Common::DoFileSearch({wm->GetConfig()->GetUserProfileDirectoryPath()}, {".ini"}))
  {
    std::string basename;
    SplitPath(filename, nullptr, &basename, nullptr);
    if (!basename.empty()) names.insert(basename);
  }
  for (const auto& filename : Common::DoFileSearch({wm->GetConfig()->GetSysProfileDirectoryPath()}, {".ini"}))
  {
    std::string basename;
    SplitPath(filename, nullptr, &basename, nullptr);
    if (!basename.empty()) names.insert(basename);
  }
  for (const auto& n : names) { [result addObject:[NSString stringWithUTF8String:n.c_str()]]; }
  return result;
}

+ (BOOL)loadProfile:(NSString*)name forGCPort:(NSInteger)portOneBased restoreDevice:(BOOL)restore
{
  auto* cfg = Pad::GetConfig();
  if (!cfg) return NO;
  const int port = (int)portOneBased - 1;
  auto* pad = cfg->GetController(port);
  if (!pad) return NO;
  const std::string n = [name UTF8String];
  const std::string sysDir = pad->GetConfig()->GetSysProfileDirectoryPath();
  const std::string userDir = pad->GetConfig()->GetUserProfileDirectoryPath();
  const std::string sysPath = sysDir + (sysDir.empty() || sysDir.back() == '/' ? "" : "/") + n + ".ini";
  const std::string userPath = userDir + (userDir.empty() || userDir.back() == '/' ? "" : "/") + n + ".ini";
  std::string loadPath;
  if (File::Exists(userPath)) loadPath = userPath;
  else if (File::Exists(sysPath)) loadPath = sysPath;
  else return NO;
  Common::IniFile ini;
  if (!ini.Load(loadPath)) return NO;
  const auto selectedDev = pad->GetDefaultDevice();
  pad->LoadConfig(ini.GetOrCreateSection("Profile"));
  if (restore) pad->SetDefaultDevice(selectedDev);
  pad->UpdateReferences(g_controller_interface);
  Pad::GetConfig()->SaveConfig();
  return YES;
}

+ (BOOL)loadProfile:(NSString*)name forWiimote:(NSInteger)indexOneBased restoreDevice:(BOOL)restore
{
  auto* cfg = Wiimote::GetConfig();
  if (!cfg) return NO;
  const int idx = (int)indexOneBased - 1;
  auto* wm = cfg->GetController(idx);
  if (!wm) return NO;
  const std::string n = [name UTF8String];
  const std::string sysDir = wm->GetConfig()->GetSysProfileDirectoryPath();
  const std::string userDir = wm->GetConfig()->GetUserProfileDirectoryPath();
  const std::string sysPath = sysDir + (sysDir.empty() || sysDir.back() == '/' ? "" : "/") + n + ".ini";
  const std::string userPath = userDir + (userDir.empty() || userDir.back() == '/' ? "" : "/") + n + ".ini";
  std::string loadPath;
  if (File::Exists(userPath)) loadPath = userPath;
  else if (File::Exists(sysPath)) loadPath = sysPath;
  else return NO;
  Common::IniFile ini;
  if (!ini.Load(loadPath)) return NO;
  const auto selectedDev = wm->GetDefaultDevice();
  wm->LoadConfig(ini.GetOrCreateSection("Profile"));
  if (restore) wm->SetDefaultDevice(selectedDev);
  wm->UpdateReferences(g_controller_interface);
  Wiimote::GetConfig()->SaveConfig();
  return YES;
}

+ (NSArray<NSString*>*)padControlNamesForGroup:(NSInteger)portOneBased group:(NSInteger)groupId
{
  NSMutableArray<NSString*>* result = [NSMutableArray array];
  auto* cfg = Pad::GetConfig(); if (!cfg) return result;
  const int port = (int)portOneBased - 1;
  auto* controller = cfg->GetController(port); if (!controller) return result;
  auto* group = Pad::GetGroup(port, (PadGroup)groupId);
  if (!group) return result;
  const auto lock = ControllerEmu::EmulatedController::GetStateLock();
  for (const auto& control : group->controls) {
    NSString* name = CppToFoundationString(control->ui_name);
    if (control->translate == ControllerEmu::Translatability::Translate) name = DOLCoreLocalizedString(name);
    [result addObject:name];
  }
  return result;
}

+ (NSArray<NSString*>*)padControlExpressionsForGroup:(NSInteger)portOneBased group:(NSInteger)groupId
{
  NSMutableArray<NSString*>* result = [NSMutableArray array];
  auto* cfg = Pad::GetConfig(); if (!cfg) return result;
  const int port = (int)portOneBased - 1;
  auto* controller = cfg->GetController(port); if (!controller) return result;
  auto* group = Pad::GetGroup(port, (PadGroup)groupId);
  if (!group) return result;
  for (const auto& control : group->controls) {
    const std::string expr = control->control_ref->GetExpression();
    [result addObject:expr.empty() ? @"—" : [NSString stringWithUTF8String:expr.c_str()]];
  }
  return result;
}

+ (void)setPadControlExpressionForPort:(NSInteger)portOneBased group:(NSInteger)groupId index:(NSInteger)controlIndex expression:(NSString*)expression
{
  auto* cfg = Pad::GetConfig(); if (!cfg) return;
  const int port = (int)portOneBased - 1;
  auto* controller = cfg->GetController(port); if (!controller) return;
  auto* group = Pad::GetGroup(port, (PadGroup)groupId);
  if (!group) return;
  if (controlIndex < 0 || (size_t)controlIndex >= group->controls.size()) return;
  auto& controlRef = group->controls[controlIndex]->control_ref;
  controlRef->SetExpression([expression UTF8String]);
  controller->UpdateSingleControlReference(g_controller_interface, controlRef.get());
  Pad::GetConfig()->SaveConfig();
}

+ (NSArray<NSString*>*)wiimoteControlNamesForGroup:(NSInteger)indexOneBased group:(NSInteger)groupId
{
  NSMutableArray<NSString*>* result = [NSMutableArray array];
  auto* cfg = Wiimote::GetConfig(); if (!cfg) return result;
  const int idx = (int)indexOneBased - 1;
  auto* controller = cfg->GetController(idx); if (!controller) return result;
  auto* group = Wiimote::GetWiimoteGroup(idx, (WiimoteEmu::WiimoteGroup)groupId);
  if (!group) return result;
  const auto lock = ControllerEmu::EmulatedController::GetStateLock();
  for (const auto& control : group->controls) {
    NSString* name = CppToFoundationString(control->ui_name);
    if (control->translate == ControllerEmu::Translatability::Translate) name = DOLCoreLocalizedString(name);
    [result addObject:name];
  }
  return result;
}

+ (NSArray<NSString*>*)wiimoteControlExpressionsForGroup:(NSInteger)indexOneBased group:(NSInteger)groupId
{
  NSMutableArray<NSString*>* result = [NSMutableArray array];
  auto* cfg = Wiimote::GetConfig(); if (!cfg) return result;
  const int idx = (int)indexOneBased - 1;
  auto* controller = cfg->GetController(idx); if (!controller) return result;
  auto* group = Wiimote::GetWiimoteGroup(idx, (WiimoteEmu::WiimoteGroup)groupId);
  if (!group) return result;
  for (const auto& control : group->controls) {
    const std::string expr = control->control_ref->GetExpression();
    [result addObject:expr.empty() ? @"—" : [NSString stringWithUTF8String:expr.c_str()]];
  }
  return result;
}

+ (void)setWiimoteControlExpressionForIndex:(NSInteger)indexOneBased group:(NSInteger)groupId index:(NSInteger)controlIndex expression:(NSString*)expression
{
  auto* cfg = Wiimote::GetConfig(); if (!cfg) return;
  const int idx = (int)indexOneBased - 1;
  auto* controller = cfg->GetController(idx); if (!controller) return;
  auto* group = Wiimote::GetWiimoteGroup(idx, (WiimoteEmu::WiimoteGroup)groupId);
  if (!group) return;
  if (controlIndex < 0 || (size_t)controlIndex >= group->controls.size()) return;
  auto& controlRef = group->controls[controlIndex]->control_ref;
  controlRef->SetExpression([expression UTF8String]);
  controller->UpdateSingleControlReference(g_controller_interface, controlRef.get());
  Wiimote::GetConfig()->SaveConfig();
}

+ (void)refreshDevices
{
  if (!g_controller_interface.IsInit())
    return;
  g_controller_interface.RefreshDevices(ControllerInterface::RefreshReason::Other);
  dispatch_async(dispatch_get_main_queue(), ^{
    [[NSNotificationCenter defaultCenter] postNotificationName:TVControllerDevicesChangedNotification object:nil];
  });
}

@end
