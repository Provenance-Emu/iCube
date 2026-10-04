// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "TVControllerMappingBridge.h"

// Dolphin includes
#include "InputCommon/ControllerInterface/ControllerInterface.h"
#include "InputCommon/ControllerInterface/iOS/MFiController.h"
#include "Core/HW/GCPad.h"
#include "Core/HW/Wiimote.h"
#include "Core/HW/WiimoteEmu/WiimoteEmu.h"
#include "Core/HW/WiimoteEmu/Extension/Nunchuk.h"
#include "Core/HW/WiimoteEmu/Extension/Classic.h"
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

#include "ProfileLoading.h"

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

// Mirrors the file-static `HasAnyBoundControl` in EmulationCoordinator.mm (not exported, so
// duplicated here rather than shared). No state lock: matches the other read-only accessors in
// this file (e.g. padControlExpressionsForGroup:) rather than the name/translation readers that
// take `EmulatedController::GetStateLock()`.
static BOOL ControllerHasAnyBoundControl(const ControllerEmu::EmulatedController* controller)
{
  if (!controller)
    return NO;
  for (const auto& group : controller->groups)
    for (const auto& control : group->controls)
      if (control->control_ref && !control->control_ref->GetExpression().empty())
        return YES;
  return NO;
}

+ (BOOL)padHasAnyBinding:(NSInteger)portOneBased
{
  auto* cfg = Pad::GetConfig();
  if (!cfg)
    return NO;
  const int port = static_cast<int>(portOneBased - 1);
  return ControllerHasAnyBoundControl(cfg->GetController(port));
}

+ (BOOL)wiimoteHasAnyBinding:(NSInteger)indexOneBased
{
  auto* cfg = Wiimote::GetConfig();
  if (!cfg)
    return NO;
  const int idx = static_cast<int>(indexOneBased - 1);
  return ControllerHasAnyBoundControl(cfg->GetController(idx));
}

// Takes the state lock, unlike `ControllerHasAnyBoundControl`: `BoundCount` walks the parsed
// expression tree, which a hotplug `UpdateReferences` rewrites under that lock.
static BOOL ControllerMappingBindsDevice(const ControllerEmu::EmulatedController* controller)
{
  if (!controller)
    return NO;
  const auto lock = ControllerEmu::EmulatedController::GetStateLock();
  for (const auto& group : controller->groups)
    for (const auto& control : group->controls)
      if (control->control_ref && control->control_ref->BoundCount() > 0)
        return YES;
  return NO;
}

+ (BOOL)padMappingBindsDevice:(NSInteger)portOneBased
{
  auto* cfg = Pad::GetConfig();
  if (!cfg)
    return NO;
  const int port = static_cast<int>(portOneBased - 1);
  return ControllerMappingBindsDevice(cfg->GetController(port));
}

+ (BOOL)wiimoteMappingBindsDevice:(NSInteger)indexOneBased
{
  auto* cfg = Wiimote::GetConfig();
  if (!cfg)
    return NO;
  const int idx = static_cast<int>(indexOneBased - 1);
  return ControllerMappingBindsDevice(cfg->GetController(idx));
}

// The iOS backend's on-screen device, `iOS/<id>/Touchscreen` (ids 0-3 GameCube pads, 4-7 Wii
// Remotes; iOS.mm PopulateDevices).
static bool IsTouchscreenDevice(const ciface::Core::DeviceQualifier& dq)
{
  return dq.source == "iOS" && dq.name == "Touchscreen";
}

// `idx` is zero-based. False for an out-of-range index (`GetController` is `vector::at`).
static bool WiimoteIsOnTouchscreen(int idx)
{
  auto* cfg = Wiimote::GetConfig();
  if (!cfg || idx < 0 || idx >= cfg->GetControllerCount())
    return false;
  const auto* wm = cfg->GetController(idx);
  return wm && IsTouchscreenDevice(wm->GetDefaultDevice());
}

// The core's motion pointer (`IMUIR/Enabled`) aims the IR camera from the IMU axes, which the app
// fills with the phone's own motion whenever the overlay is up. On a touchscreen slot the app
// writes IR itself, so with it on, holding the phone upright points the remote at the ceiling and
// the pointer vanishes. The physical-remote profiles (`Physical Controller`, `Wii Remote with
// MotionPlus Pointing`) and the core's `LoadDefaults` all turn it on, so every load onto a
// touchscreen slot must end here. Does not save; returns whether it changed anything.
static bool DisableCoreIMUPointerIfTouchscreen(int idx)
{
  if (!WiimoteIsOnTouchscreen(idx))
    return false;
  const auto lock = ControllerEmu::EmulatedController::GetStateLock();
  auto* group = Wiimote::GetWiimoteGroup(idx, WiimoteEmu::WiimoteGroup::IMUPoint);
  if (!group || (group->enabled.IsSimpleValue() && !group->enabled.GetValue()))
    return false;
  group->enabled.SetValue(false);
  NSLog(@"[iCube][Input] Wiimote%d: core IMU pointer disabled (touchscreen drives IR)", idx + 1);
  return true;
}

// The pointer block of the bundled Data/Sys/Profiles/Wiimote/Touchscreen.ini, in the Cursor
// group's control order (`named_directions`: Up, Down, Left, Right; axis ids in ButtonType.h).
static constexpr int kIRDirectionCount = 4;
static constexpr const char* kTouchscreenIRExpressions[kIRDirectionCount] = {
    "`Axis 112`", "`Axis 113`", "`Axis 114`", "`Axis 115`"};

// True when all four IR direction controls (`IR/Up`, `Down`, `Left`, `Right`) of the Wii Remote
// have an expression and, when the slot's device is currently enumerated, each one binds an input
// on it. A profile without `IR/` keys loads them as "" (ControlGroup::LoadConfig); the core's
// LoadDefaults writes `Cursor Y-` and friends, which are not empty but name no input on iOS.
static bool WiimoteHasIRPointerBinding(int idx)
{
  auto* cfg = Wiimote::GetConfig();
  if (!cfg || idx < 0 || idx >= cfg->GetControllerCount())
    return false;
  const auto* wm = cfg->GetController(idx);
  auto* ir = Wiimote::GetWiimoteGroup(idx, WiimoteEmu::WiimoteGroup::Point);
  if (!wm || !ir || ir->controls.size() < static_cast<size_t>(kIRDirectionCount))
    return false;
  // Before the state lock: the device lookup takes the device list's own mutex, and a hotplug
  // holds that one while it re-resolves references under the state lock.
  const bool device_present = g_controller_interface.HasConnectedDevice(wm->GetDefaultDevice());
  const auto lock = ControllerEmu::EmulatedController::GetStateLock();
  for (int i = 0; i < kIRDirectionCount; ++i)
  {
    const auto& ref = ir->controls[i]->control_ref;
    if (!ref || ref->GetExpression().empty())
      return false;
    if (device_present && ref->BoundCount() == 0)
      return false;
  }
  return true;
}

// Re-applies only the IR block of the bundled Touchscreen profile (`IR/Up..Right = Axis 112..115`,
// `IR/Auto-Hide = False`) to a touchscreen slot whose pointer directions are unbound, leaving every
// other binding as the user has it. Auto-Hide is reset too because a pointer that sat still while
// unbound is hidden after 2.5 s (Cursor.cpp) and stays hidden until it moves. Does not save;
// returns whether it changed anything.
static bool RepairTouchscreenIRPointer(int idx)
{
  if (!WiimoteIsOnTouchscreen(idx) || WiimoteHasIRPointerBinding(idx))
    return false;
  auto* wm = Wiimote::GetConfig()->GetController(idx);
  auto* ir = Wiimote::GetWiimoteGroup(idx, WiimoteEmu::WiimoteGroup::Point);
  if (!wm || !ir || ir->controls.size() < static_cast<size_t>(kIRDirectionCount))
    return false;
  {
    const auto lock = ControllerEmu::EmulatedController::GetStateLock();
    for (int i = 0; i < kIRDirectionCount; ++i)
      ir->SetControlExpression(i, kTouchscreenIRExpressions[i]);
    for (auto& setting : ir->numeric_settings)
    {
      if (setting->GetType() == ControllerEmu::SettingType::Bool &&
          std::string_view(setting->GetININame()) == "Auto-Hide")
      {
        static_cast<ControllerEmu::NumericSetting<bool>*>(setting.get())->SetValue(false);
      }
    }
  }
  wm->UpdateReferences(g_controller_interface);
  NSLog(@"[iCube][Input] Wiimote%d: IR pointer rebound to the touchscreen", idx + 1);
  return true;
}

+ (BOOL)wiimoteUsesTouchscreen:(NSInteger)indexOneBased
{
  return WiimoteIsOnTouchscreen(static_cast<int>(indexOneBased - 1)) ? YES : NO;
}

+ (BOOL)wiimoteHasIRPointerBinding:(NSInteger)indexOneBased
{
  return WiimoteHasIRPointerBinding(static_cast<int>(indexOneBased - 1)) ? YES : NO;
}

+ (BOOL)enforceTouchscreenPointerForWiimote:(NSInteger)indexOneBased
{
  const int idx = static_cast<int>(indexOneBased - 1);
  const bool imu_changed = DisableCoreIMUPointerIfTouchscreen(idx);
  const bool ir_changed = RepairTouchscreenIRPointer(idx);
  if (imu_changed || ir_changed)
    Wiimote::GetConfig()->SaveConfig();
  return (imu_changed || ir_changed) ? YES : NO;
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
  // As the coordinator's BindTouchscreen: the on-screen profile is loaded only when the port
  // changes device or has no mapping, so a touch mapping the user edited survives a re-bind (and
  // the boot pass, which offers Pad 1 to the Touchscreen at every launch).
  const bool rebinding = !(pad->GetDefaultDevice() == dq);
  bool loaded_profile = false;
  if (rebinding || !ControllerHasAnyBoundControl(pad))
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
    if (!loaded_profile)
      pad->LoadDefaults(g_controller_interface);
  }

  {
    // `LoadConfig` applies the profile's own `Device =` line, and a user profile saved as
    // "Touchscreen" from a pad's port names that pad: the port followed it and the on-screen
    // controls drove nothing. The port is the Touchscreen's whatever the profile says.
    const auto lock = ControllerEmu::EmulatedController::GetStateLock();
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

// Bundled profiles for hardware no iOS/tvOS backend reaches: SDL and hidapi (real Wii Remotes)
// are not built for IOS (root CMakeLists.txt), so `Bluetooth/0/Wii Remote` and the SDL gamepad
// never exist and every control of these profiles is dead.
static bool IsUnsupportedProfile(const std::string& name)
{
  return name == "Wii Remote with MotionPlus Pointing" || name == "SDL Gamepad";
}

// True when the profile's `Device =` line names an on-screen `iOS/<id>/Touchscreen`.
static bool ProfileTargetsTouchscreen(const std::string& path)
{
  Common::IniFile ini;
  if (!ini.Load(path))
    return false;
  const auto* section = ini.GetSection("Profile");
  std::string device;
  if (!section || !section->Get("Device", &device))
    return false;
  ciface::Core::DeviceQualifier dq;
  dq.FromString(device);
  return IsTouchscreenDevice(dq);
}

// The profile names the player screen offers for a slot. The user directory is searched first
// because a user profile shadows a bundled one of the same name (`loadProfile:` loads it), and
// each filter looks at the file that would actually load: the unsupported names are dropped
// only for the bundled copies (a user may save anything under those names), and on a slot bound
// to the Touchscreen only profiles whose `Device =` line is an on-screen device are offered,
// the bundled `Touchscreen` included: a physical-controller profile's inputs (`Button A`, ...)
// do not exist on it, and loading one left the Wii pointer unbound and the core's motion pointer
// on. With `filter` false, every name on disk (what a save would collide with).
static NSArray<NSString*>*
ProfilesForController(const ControllerEmu::EmulatedController* controller, bool filter)
{
  NSMutableArray<NSString*>* result = [NSMutableArray array];
  if (!controller)
    return result;
  const InputConfig* config = controller->GetConfig();
  const bool touchscreen_slot = filter && IsTouchscreenDevice(controller->GetDefaultDevice());
  std::unordered_set<std::string> seen;
  const std::string sys_dir = config->GetSysProfileDirectoryPath();
  for (const std::string& dir : {config->GetUserProfileDirectoryPath(), sys_dir})
  {
    const bool bundled = dir == sys_dir;
    for (const auto& filename : Common::DoFileSearch(dir, ".ini"))
    {
      std::string basename;
      SplitPath(filename, nullptr, &basename, nullptr);
      if (basename.empty() || !seen.insert(basename).second)
        continue;
      if (filter && bundled && IsUnsupportedProfile(basename))
        continue;
      if (touchscreen_slot && !ProfileTargetsTouchscreen(filename))
        continue;
      [result addObject:CppToFoundationString(basename)];
    }
  }
  return result;
}

static const ControllerEmu::EmulatedController* PadAt(NSInteger portOneBased)
{
  auto* cfg = Pad::GetConfig();
  const int port = static_cast<int>(portOneBased - 1);
  if (!cfg || port < 0 || port >= cfg->GetControllerCount())
    return nullptr;
  return cfg->GetController(port);
}

static const ControllerEmu::EmulatedController* WiimoteAt(NSInteger indexOneBased)
{
  auto* cfg = Wiimote::GetConfig();
  const int idx = static_cast<int>(indexOneBased - 1);
  if (!cfg || idx < 0 || idx >= cfg->GetControllerCount())
    return nullptr;
  return cfg->GetController(idx);
}

+ (NSArray<NSString*>*)profilesForGCPort:(NSInteger)portOneBased
{
  return ProfilesForController(PadAt(portOneBased), true);
}

+ (NSArray<NSString*>*)profilesForWiimote:(NSInteger)indexOneBased
{
  return ProfilesForController(WiimoteAt(indexOneBased), true);
}

+ (NSArray<NSString*>*)allProfilesForGCPort:(NSInteger)portOneBased
{
  return ProfilesForController(PadAt(portOneBased), false);
}

+ (NSArray<NSString*>*)allProfilesForWiimote:(NSInteger)indexOneBased
{
  return ProfilesForController(WiimoteAt(indexOneBased), false);
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
  LoadProfileKeepingExtension(wm, ini.GetOrCreateSection("Profile"));
  if (restore) wm->SetDefaultDevice(selectedDev);
  wm->UpdateReferences(g_controller_interface);
  DisableCoreIMUPointerIfTouchscreen(idx);
  RepairTouchscreenIRPointer(idx);
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

// The profile names in the controller type's user directory: the ones a delete can remove.
static NSArray<NSString*>* UserProfileNames(const ControllerEmu::EmulatedController* controller)
{
  NSMutableArray<NSString*>* result = [NSMutableArray array];
  if (!controller)
    return result;
  const std::string dir = controller->GetConfig()->GetUserProfileDirectoryPath();
  if (dir.empty())
    return result;
  for (const auto& filename : Common::DoFileSearch(dir, ".ini"))
  {
    std::string basename;
    SplitPath(filename, nullptr, &basename, nullptr);
    if (!basename.empty())
      [result addObject:CppToFoundationString(basename)];
  }
  return result;
}

// Deletes `<user profile dir>/<name>.ini` and nothing else: the sys (bundled) directory is never
// looked at, and a name that would leave the user directory is refused.
static BOOL DeleteUserProfile(const ControllerEmu::EmulatedController* controller, NSString* name)
{
  if (!controller || name.length == 0)
    return NO;
  const std::string n = FoundationToCppString(name);
  if (n.find('/') != std::string::npos)
    return NO;
  std::string userDir = controller->GetConfig()->GetUserProfileDirectoryPath();
  if (userDir.empty())
    return NO;
  if (userDir.back() != '/')
    userDir += '/';
  const std::string path = userDir + n + ".ini";
  if (!File::Exists(path))
    return NO;
  return File::Delete(path, File::IfAbsentBehavior::NoConsoleWarning) ? YES : NO;
}

+ (NSArray<NSString*>*)userProfilesForGCPort:(NSInteger)portOneBased
{
  return UserProfileNames(PadAt(portOneBased));
}

+ (NSArray<NSString*>*)userProfilesForWiimote:(NSInteger)indexOneBased
{
  return UserProfileNames(WiimoteAt(indexOneBased));
}

+ (BOOL)deleteProfile:(NSString*)name forGCPort:(NSInteger)portOneBased
{
  return DeleteUserProfile(PadAt(portOneBased), name);
}

+ (BOOL)deleteProfile:(NSString*)name forWiimote:(NSInteger)indexOneBased
{
  return DeleteUserProfile(WiimoteAt(indexOneBased), name);
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

// Shared by the three wiimoteExtensionControl* methods below: resolves `kind`
// + the raw group id to the right Dolphin accessor. Mirrors
// `Wiimote::GetWiimoteGroup`'s signature shape but dispatches to
// `Wiimote::GetNunchukGroup` / `Wiimote::GetClassicGroup` (Core/HW/Wiimote.h),
// which reach the attached extension's own groups — `GetWiimoteGroup` cannot.
static ControllerEmu::ControlGroup* GetWiimoteExtensionGroup(int idx, DOLWiimoteExtensionKind kind, NSInteger groupId)
{
  switch (kind)
  {
    case DOLWiimoteExtensionKindNunchuk:
      return Wiimote::GetNunchukGroup(idx, (WiimoteEmu::NunchukGroup)groupId);
    case DOLWiimoteExtensionKindClassic:
      return Wiimote::GetClassicGroup(idx, (WiimoteEmu::ClassicGroup)groupId);
  }
  return nullptr;
}

+ (NSArray<NSString*>*)wiimoteExtensionControlNamesForIndex:(NSInteger)indexOneBased kind:(DOLWiimoteExtensionKind)kind group:(NSInteger)groupId
{
  NSMutableArray<NSString*>* result = [NSMutableArray array];
  auto* cfg = Wiimote::GetConfig(); if (!cfg) return result;
  const int idx = (int)indexOneBased - 1;
  auto* controller = cfg->GetController(idx); if (!controller) return result;
  auto* group = GetWiimoteExtensionGroup(idx, kind, groupId);
  if (!group) return result;
  const auto lock = ControllerEmu::EmulatedController::GetStateLock();
  for (const auto& control : group->controls) {
    NSString* name = CppToFoundationString(control->ui_name);
    if (control->translate == ControllerEmu::Translatability::Translate) name = DOLCoreLocalizedString(name);
    [result addObject:name];
  }
  return result;
}

+ (NSArray<NSString*>*)wiimoteExtensionControlExpressionsForIndex:(NSInteger)indexOneBased kind:(DOLWiimoteExtensionKind)kind group:(NSInteger)groupId
{
  NSMutableArray<NSString*>* result = [NSMutableArray array];
  auto* cfg = Wiimote::GetConfig(); if (!cfg) return result;
  const int idx = (int)indexOneBased - 1;
  auto* controller = cfg->GetController(idx); if (!controller) return result;
  auto* group = GetWiimoteExtensionGroup(idx, kind, groupId);
  if (!group) return result;
  for (const auto& control : group->controls) {
    const std::string expr = control->control_ref->GetExpression();
    [result addObject:expr.empty() ? @"—" : [NSString stringWithUTF8String:expr.c_str()]];
  }
  return result;
}

+ (void)setWiimoteExtensionControlExpressionForIndex:(NSInteger)indexOneBased kind:(DOLWiimoteExtensionKind)kind group:(NSInteger)groupId index:(NSInteger)controlIndex expression:(NSString*)expression
{
  auto* cfg = Wiimote::GetConfig(); if (!cfg) return;
  const int idx = (int)indexOneBased - 1;
  auto* controller = cfg->GetController(idx); if (!controller) return;
  auto* group = GetWiimoteExtensionGroup(idx, kind, groupId);
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
