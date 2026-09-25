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

// 2512: RegisterDevicesChangedCallback returns a Common::EventHook; dropping it unregisters.
static Common::EventHook s_hotplugHandle;
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
    s_hotplugHandle.reset();
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

  // NO POLICY HERE. Choosing which device owns which port is the Swift
  // AssignmentEngine's job; this method only removes bindings that point at
  // devices the ControllerInterface no longer enumerates, so the engine sees an
  // accurate snapshot. The three competing auto-assign policies that used to
  // live below this line (and in EmulationCoordinator) were the reason a single
  // connect event could assign, re-decide and reassign the same controller.
  if (did_mutate)
    Pad::GetConfig()->SaveConfig();
}

+ (void)assignTouchscreenToGCPort:(NSInteger)portOneBased
{
  if (portOneBased < 1 || portOneBased > 4)
    return;
  auto* cfg = Pad::GetConfig();
  if (!cfg)
    return;
  // Touchscreen instance ids 0-3 carry the GC pad inputs for ports 1-4 (iOS.mm PopulateDevices);
  // a name-only lookup always returned instance 0 and aliased every port onto Pad 1.
  const int port = (int)portOneBased - 1;
  std::shared_ptr<ciface::Core::Device> touchscreen_dev;
  for (const auto& dev : g_controller_interface.GetAllDevices())
  {
    if (dev && dev->GetSource() == std::string("iOS") && dev->GetName() == std::string("Touchscreen") &&
        dev->GetId() == port)
    {
      touchscreen_dev = dev; break;
    }
  }
  if (!touchscreen_dev)
    return;
  ciface::Core::DeviceQualifier dq; dq.FromDevice(touchscreen_dev.get());
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

// Mirror of loadProfile:… in reverse. `SaveConfig` (ControllerEmu.h:245) writes the
// device line, every control expression and every numeric setting into the
// section — the same shape the bundled Data/Sys/Profiles/*.ini files have.
static BOOL SaveControllerProfile(ControllerEmu::EmulatedController* controller, NSString* name)
{
  if (!controller || name.length == 0) return NO;
  const std::string n = [name UTF8String];
  std::string userDir = controller->GetConfig()->GetUserProfileDirectoryPath();
  if (userDir.empty()) return NO;
  if (userDir.back() != '/') userDir += '/';
  if (!File::CreateFullPath(userDir)) return NO;
  const std::string userPath = userDir + n + ".ini";
  Common::IniFile ini;
  controller->SaveConfig(ini.GetOrCreateSection("Profile"));
  return ini.Save(userPath) ? YES : NO;
}

+ (BOOL)saveProfile:(NSString*)name forGCPort:(NSInteger)portOneBased
{
  auto* cfg = Pad::GetConfig();
  if (!cfg) return NO;
  return SaveControllerProfile(cfg->GetController((int)portOneBased - 1), name);
}

+ (BOOL)saveProfile:(NSString*)name forWiimote:(NSInteger)indexOneBased
{
  auto* cfg = Wiimote::GetConfig();
  if (!cfg) return NO;
  return SaveControllerProfile(cfg->GetController((int)indexOneBased - 1), name);
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
