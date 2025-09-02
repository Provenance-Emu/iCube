// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "EmulationCoordinator.h"

#import <Metal/Metal.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#import "Common/WindowSystemInfo.h"

#import "Core/Boot/Boot.h"
#import "Core/BootManager.h"
#import "Core/Core.h"
#import "Core/System.h"
#import "Core/Config/MainSettings.h"

#import "VideoCommon/RenderBase.h"
#import "VideoCommon/Present.h"
#include "UICommon/UICommon.h"
#include "Core/HW/SI/SI_Device.h"
#include "Core/Config/MainSettings.h"
#include "Core/HW/GCPad.h"
#include "InputCommon/ControllerInterface/ControllerInterface.h"
#include "InputCommon/InputConfig.h"
#include "InputCommon/ControllerEmu/ControllerEmu.h"
#include "InputCommon/ControllerInterface/CoreDevice.h"
#import "Core/PowerPC/PowerPC.h"
#include "Common/IniFile.h"
#include "Common/FileUtil.h"
#include "Core/HW/Wiimote.h"
#include "Core/HW/WiimoteEmu/WiimoteEmu.h"

#import "EmulationBootParameter.h"
#import "HostNotifications.h"
#import "HostQueue.h"
#import "JitManager.h"
#import "TVControllerMappingBridge.h"
#import "LocalizationUtil.h"
#import "VirtualMFiControllerManager.h"
#import "DolphiniOS-Swift.h"
#include "Core/Config/WiimoteSettings.h"

// A lightweight host view that notifies us when its bounds change so we can
// update the CAMetalLayer frame and drawableSize.
@interface RenderHostView : UIView
@property(nonatomic, copy) void (^onLayout)(void);
@end

@implementation RenderHostView
- (void)layoutSubviews {
  [super layoutSubviews];
  if (self.onLayout) self.onLayout();
}
@end

@interface SafeMainThreadMetalLayer : CAMetalLayer
@end

@implementation SafeMainThreadMetalLayer
- (void)setContentsScale:(CGFloat)contentsScale { if ([NSThread isMainThread]) { [super setContentsScale:contentsScale]; } else { dispatch_async(dispatch_get_main_queue(), ^{ [super setContentsScale:contentsScale]; }); } }
- (void)setFramebufferOnly:(BOOL)framebufferOnly { if ([NSThread isMainThread]) { [super setFramebufferOnly:framebufferOnly]; } else { dispatch_async(dispatch_get_main_queue(), ^{ [super setFramebufferOnly:framebufferOnly]; }); } }
- (void)setMaximumDrawableCount:(NSUInteger)maximumDrawableCount { if ([NSThread isMainThread]) { if ([self respondsToSelector:@selector(setMaximumDrawableCount:)]) [super setMaximumDrawableCount:maximumDrawableCount]; } else { dispatch_async(dispatch_get_main_queue(), ^{ if ([self respondsToSelector:@selector(setMaximumDrawableCount:)]) [super setMaximumDrawableCount:maximumDrawableCount]; }); } }
- (void)setAllowsNextDrawableTimeout:(BOOL)allowsNextDrawableTimeout { if ([NSThread isMainThread]) { if ([self respondsToSelector:@selector(setAllowsNextDrawableTimeout:)]) [super setAllowsNextDrawableTimeout:allowsNextDrawableTimeout]; } else { dispatch_async(dispatch_get_main_queue(), ^{ if ([self respondsToSelector:@selector(setAllowsNextDrawableTimeout:)]) [super setAllowsNextDrawableTimeout:allowsNextDrawableTimeout]; }); } }
- (void)setDrawableSize:(CGSize)drawableSize { if ([NSThread isMainThread]) { [super setDrawableSize:drawableSize]; } else { dispatch_async(dispatch_get_main_queue(), ^{ [super setDrawableSize:drawableSize]; }); } }
- (void)setPixelFormat:(MTLPixelFormat)pixelFormat { if ([NSThread isMainThread]) { [super setPixelFormat:pixelFormat]; } else { dispatch_async(dispatch_get_main_queue(), ^{ [super setPixelFormat:pixelFormat]; }); } }
@end

@implementation EmulationCoordinator {
  UIView* _renderHost;
  SafeMainThreadMetalLayer* _metalLayer;
  id<MTLDevice> _device;
  UIView* _mainDisplayView;
  dispatch_source_t _adaptiveClockTimer;
  dispatch_source_t _inputPumpTimer;
  float _adaptiveVI;
  float _adaptiveCPU;
  CGSize _lastDrawableSize;
}

@synthesize userRequestedPause = _userRequestedPause;

+ (EmulationCoordinator*)shared {
  static EmulationCoordinator* sharedInstance = nil;
  static dispatch_once_t onceToken;

  dispatch_once(&onceToken, ^{
    sharedInstance = [[self alloc] init];
  });

  return sharedInstance;
}

- (void)applyMetalLayerPreferences {
  NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
  BOOL tripleBuffering = [defaults boolForKey:@"gfx_triple_buffering"];
  BOOL forceScaleOneOnNonProMotion = [defaults boolForKey:@"gfx_force_scale_one_non_promo"];
  BOOL edrEnabled = [defaults boolForKey:@"gfx_edr_enabled"];

  if (_metalLayer) {
    _metalLayer.framebufferOnly = YES;
    if ([_metalLayer respondsToSelector:@selector(setAllowsNextDrawableTimeout:)]) {
      _metalLayer.allowsNextDrawableTimeout = NO;
    }
    if ([_metalLayer respondsToSelector:@selector(setMaximumDrawableCount:)]) {
      _metalLayer.maximumDrawableCount = tripleBuffering ? 3 : 2;
    }
    CGFloat surfaceScale = UIScreen.mainScreen.scale;
    if (forceScaleOneOnNonProMotion && UIScreen.mainScreen.maximumFramesPerSecond <= 60) {
      surfaceScale = 1.0;
    }
    _metalLayer.contentsScale = surfaceScale;
    _metalLayer.pixelFormat = edrEnabled ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm;
  }
}

- (CGFloat)currentRenderSurfaceScale {
  NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
  BOOL forceScaleOneOnNonProMotion = [defaults boolForKey:@"gfx_force_scale_one_non_promo"];
  CGFloat surfaceScale = UIScreen.mainScreen.scale;
  if (forceScaleOneOnNonProMotion && UIScreen.mainScreen.maximumFramesPerSecond <= 60) {
    surfaceScale = 1.0;
  }
  return surfaceScale;
}

- (id)init {
  if (self = [super init]) {
    _renderHost = [RenderHostView new];
    _renderHost.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _renderHost.backgroundColor = [UIColor blackColor];

    _device = MTLCreateSystemDefaultDevice();
    _metalLayer = [SafeMainThreadMetalLayer layer];
    _metalLayer.device = _device;
    [self applyMetalLayerPreferences];
    ((RenderHostView*)_renderHost).onLayout = ^{ [self updateMetalLayerFrame]; };

    self.isExternalDisplayConnected = false;
    _lastDrawableSize = CGSizeZero;
  }

  return self;
}

- (void)setIsExternalDisplayConnected:(bool)connected {
  self->_isExternalDisplayConnected = connected;

  if (!_isExternalDisplayConnected) {
    [self requestDisplayOnSuperview:_mainDisplayView];
  }
}

- (void)registerMainDisplayView:(UIView*)mainView {
  _mainDisplayView = mainView;

  if (!self.isExternalDisplayConnected) {
    [self requestDisplayOnSuperview:mainView];
  }
}

- (void)registerExternalDisplayView:(UIView*)externalView {
  [self requestDisplayOnSuperview:externalView];
}

- (void)requestDisplayOnSuperview:(UIView*)superview {
  [_renderHost removeFromSuperview];
  [superview addSubview:_renderHost];
  _renderHost.frame = superview.bounds;
  [self applyMetalLayerPreferences];

  if (_metalLayer.superlayer != _renderHost.layer) {
    [_metalLayer removeFromSuperlayer];
    _metalLayer.frame = _renderHost.layer.bounds;
    [_renderHost.layer addSublayer:_metalLayer];
  } else {
    _metalLayer.frame = _renderHost.layer.bounds;
  }

  [self updateMetalLayerFrame];

  if (g_presenter) {
    g_presenter->ResizeSurface();
  }
}

- (void)updateMetalLayerFrame {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self updateMetalLayerFrame]; });
    return;
  }
  const CGSize size = _renderHost.bounds.size;
  if (size.width <= 0.0 || size.height <= 0.0) {
    return;
  }
  _metalLayer.frame = _renderHost.layer.bounds;
  const CGFloat scale = [self currentRenderSurfaceScale];
  _metalLayer.contentsScale = scale;
  const CGSize newDrawable = CGSizeMake(size.width * scale, size.height * scale);
  const bool changed = !CGSizeEqualToSize(_lastDrawableSize, newDrawable);
  _metalLayer.drawableSize = newDrawable;
  // Apply HDR/EDR preference dynamically
  BOOL edrEnabled = [NSUserDefaults.standardUserDefaults boolForKey:@"gfx_edr_enabled"];
  _metalLayer.pixelFormat = edrEnabled ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm;
  if (changed && g_presenter)
  {
    _lastDrawableSize = newDrawable;
    g_presenter->ResizeSurface();
  }
}

- (void)runEmulationWithBootParameter:(EmulationBootParameter*)bootParameter {
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    [self emulationLoopWithBootParameter:bootParameter];
  });
}

- (void)startAdaptiveClockIfEnabled {
  if (![NSUserDefaults.standardUserDefaults boolForKey:@"adaptive_clock_enable"]) return;
  if (_adaptiveClockTimer) return;
  _adaptiveVI = Config::Get(Config::MAIN_VI_OVERCLOCK);
  _adaptiveCPU = Config::Get(Config::MAIN_OVERCLOCK);
  _adaptiveClockTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
  dispatch_source_set_timer(_adaptiveClockTimer, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC * 2, NSEC_PER_MSEC * 100);
  dispatch_source_set_event_handler(_adaptiveClockTimer, ^{
    auto& sys = Core::System::GetInstance();
    if (Core::GetState(sys) != Core::State::Running) return;
    const double speed_ratio = Core::GetActualEmulationSpeed();
    const float pct = (float)(speed_ratio * 100.0);
    Core::QueueHostJob([&](Core::System& s) {
      if (pct > 0.f && pct < 95.0f) {
        if (self->_adaptiveVI > 0.75f) { self->_adaptiveVI = MAX(0.75f, self->_adaptiveVI - 0.05f); Config::SetBaseOrCurrent(Config::MAIN_VI_OVERCLOCK_ENABLE, true); Config::SetBaseOrCurrent(Config::MAIN_VI_OVERCLOCK, self->_adaptiveVI); }
        else if (self->_adaptiveCPU > 0.90f) { self->_adaptiveCPU = MAX(0.90f, self->_adaptiveCPU - 0.02f); Config::SetBaseOrCurrent(Config::MAIN_OVERCLOCK_ENABLE, true); Config::SetBaseOrCurrent(Config::MAIN_OVERCLOCK, self->_adaptiveCPU); }
      } else if (pct > 103.0f) {
        if (self->_adaptiveCPU < 1.0f) { self->_adaptiveCPU = MIN(1.0f, self->_adaptiveCPU + 0.02f); Config::SetBaseOrCurrent(Config::MAIN_OVERCLOCK, self->_adaptiveCPU); }
        else if (self->_adaptiveVI < 1.0f) { self->_adaptiveVI = MIN(1.0f, self->_adaptiveVI + 0.05f); Config::SetBaseOrCurrent(Config::MAIN_VI_OVERCLOCK, self->_adaptiveVI); }
      }
    }, false);
  });
  dispatch_resume(_adaptiveClockTimer);
}

- (void)startInputPump {
  if (_inputPumpTimer) return;
  _inputPumpTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
  // Pump at ~120 Hz
  dispatch_source_set_timer(_inputPumpTimer, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_MSEC * 8, NSEC_PER_MSEC * 1);
  dispatch_source_set_event_handler(_inputPumpTimer, ^{
    Core::QueueHostJob(^ (Core::System& s){
      g_controller_interface.SetCurrentInputChannel(ciface::InputChannel::Host);
      g_controller_interface.UpdateInput();
    }, false);
  });
  dispatch_resume(_inputPumpTimer);
}

- (void)stopInputPump {
  if (_inputPumpTimer) {
    dispatch_source_cancel(_inputPumpTimer);
    _inputPumpTimer = nil;
  }
}

static void EnsurePad1DefaultsToTouchscreen()
{
  // Bind Pad 1 to iOS Touchscreen unless Touchscreen is explicitly mapped to another player
  if (!Pad::GetConfig() || Pad::GetConfig()->GetControllerCount() == 0)
    return;

  // Locate the iOS Touchscreen virtual device
  const auto devices = g_controller_interface.GetAllDevices();
  std::shared_ptr<ciface::Core::Device> touchscreen_dev;
  for (const auto& dev : devices)
  {
    if (dev && dev->GetSource() == "iOS" && dev->GetName() == std::string("Touchscreen"))
    {
      touchscreen_dev = dev;
      break;
    }
  }
  if (!touchscreen_dev)
    return;

  ciface::Core::DeviceQualifier dq_touch;
  dq_touch.FromDevice(touchscreen_dev.get());

  // Otherwise, force Pad 1 (index 0) to Touchscreen and load the Touchscreen stock profile
  auto* pad0 = Pad::GetConfig()->GetController(0);
  if (pad0)
  {
    // If Touchscreen is explicitly assigned to any Pad other than 0, respect that and leave Pad1 alone
    {
      const int numc = Pad::GetConfig()->GetControllerCount();
      for (int i = 1; i < numc; ++i)
      {
        auto* p = Pad::GetConfig()->GetController(i);
        if (p && p->GetDefaultDevice() == dq_touch)
        {
          // Reserved elsewhere; don't remap Pad1
          goto after_pad1;
        }
      }
    }
    pad0->SetDefaultDevice(dq_touch);
    // Load stock Touchscreen profile if present
    bool loaded_profile_pad = false;
    {
      const std::string sysDir = pad0->GetConfig()->GetSysProfileDirectoryPath();
      const std::string userDir = pad0->GetConfig()->GetUserProfileDirectoryPath();
      const std::string sysProfile = sysDir + (sysDir.empty() || sysDir.back() == '/' ? "" : "/") + std::string("Touchscreen.ini");
      const std::string userProfile = userDir + (userDir.empty() || userDir.back() == '/' ? "" : "/") + std::string("Touchscreen.ini");
      Common::IniFile ini;
      if (File::Exists(userProfile) && ini.Load(userProfile))
      {
        pad0->LoadConfig(ini.GetOrCreateSection("Profile"));
        loaded_profile_pad = true;
      }
      else if (File::Exists(sysProfile) && ini.Load(sysProfile))
      {
        pad0->LoadConfig(ini.GetOrCreateSection("Profile"));
        loaded_profile_pad = true;
      }
    }
    if (!loaded_profile_pad)
    {
      pad0->LoadDefaults(g_controller_interface);
    }
    pad0->UpdateReferences(g_controller_interface);
    Pad::GetConfig()->SaveConfig();
    NSLog(@"[DolphiniOS][Input] Ensured Pad1 mapped to iOS Touchscreen: %s", dq_touch.ToString().c_str());
  }
after_pad1:

  // Ensure Wiimote 1 uses Touchscreen and Emulated source unless Touchscreen is explicitly mapped elsewhere
  if (Wiimote::GetConfig() && Wiimote::GetConfig()->GetControllerCount() > 0)
  {
    auto* wm0 = Wiimote::GetConfig()->GetController(0);
    if (wm0)
    {
      // Set Wiimote source to Emulated for port 0
      Config::SetBaseOrCurrent(Config::GetInfoForWiimoteSource(0), WiimoteSource::Emulated);

      // If Touchscreen is assigned to another Wiimote index, respect it
      const int wcount = Wiimote::GetConfig()->GetControllerCount();
      for (int i = 1; i < wcount; ++i)
      {
        auto* w = Wiimote::GetConfig()->GetController(i);
        if (w && w->GetDefaultDevice() == dq_touch)
          goto after_wiimote;
      }

      wm0->SetDefaultDevice(dq_touch);
      // Load stock touchscreen profile if present
      bool loaded_profile_wm = false;
      {
        const std::string sysDirWM = wm0->GetConfig()->GetSysProfileDirectoryPath();
        const std::string userDirWM = wm0->GetConfig()->GetUserProfileDirectoryPath();
        const std::string sysProfileWM = sysDirWM + (sysDirWM.empty() || sysDirWM.back() == '/' ? "" : "/") + std::string("Touchscreen.ini");
        const std::string userProfileWM = userDirWM + (userDirWM.empty() || userDirWM.back() == '/' ? "" : "/") + std::string("Touchscreen.ini");
        Common::IniFile iniWM;
        if (File::Exists(userProfileWM) && iniWM.Load(userProfileWM))
        {
          wm0->LoadConfig(iniWM.GetOrCreateSection("Profile"));
          loaded_profile_wm = true;
        }
        else if (File::Exists(sysProfileWM) && iniWM.Load(sysProfileWM))
        {
          wm0->LoadConfig(iniWM.GetOrCreateSection("Profile"));
          loaded_profile_wm = true;
        }
      }
      if (!loaded_profile_wm)
      {
        wm0->LoadDefaults(g_controller_interface);
      }
      wm0->UpdateReferences(g_controller_interface);
      Wiimote::GetConfig()->SaveConfig();
      NSLog(@"[DolphiniOS][Input] Ensured Wiimote1 mapped to iOS Touchscreen: %s", dq_touch.ToString().c_str());
    }
  }
after_wiimote:
}

static bool IsTouchscreenDevice(const std::shared_ptr<ciface::Core::Device>& dev)
{
  return dev && dev->GetSource() == std::string("iOS") && dev->GetName() == std::string("Touchscreen");
}

+ (void)autoAssignNewestExternalControllerToFirstAvailableSlot
{
  DOLHostQueueRunAsync(^{
    if (!Pad::GetConfig() || Pad::GetConfig()->GetControllerCount() == 0)
      return;

    // Reconcile any stale phantom assignments first
    [[ControllerManager shared] reconcile];

    // Gather connected physical devices (exclude Touchscreen)
    const auto devices = g_controller_interface.GetAllDevices();
    std::vector<std::shared_ptr<ciface::Core::Device>> physical;
    physical.reserve(devices.size());
    for (const auto& d : devices)
    {
      if (!d)
        continue;
      if (IsTouchscreenDevice(d))
        continue;
      physical.push_back(d);
    }
    if (physical.empty())
      return;

    // Prefer the last enumerated (newest) device
    std::shared_ptr<ciface::Core::Device> newest = physical.back();

    // Skip if this device is already assigned to any GC pad
    ciface::Core::DeviceQualifier dq_new;
    dq_new.FromDevice(newest.get());
    const int count = Pad::GetConfig()->GetControllerCount();
    for (int i = 0; i < count; ++i)
    {
      auto* pad = Pad::GetConfig()->GetController(i);
      if (!pad)
        continue;
      if (pad->GetDefaultDevice() == dq_new)
        return; // already assigned somewhere
    }

    // Find first available slot not occupied by a physical controller
    int target_index = -1;
    for (int i = 0; i < count; ++i)
    {
      auto* pad = Pad::GetConfig()->GetController(i);
      if (!pad)
        continue;

      const auto dq = pad->GetDefaultDevice();
      const bool is_touch = (dq.source == "iOS" && dq.name == "Touchscreen");
      const bool is_empty = dq.ToString().empty();
      const bool is_connected_physical = (!is_touch && !is_empty && g_controller_interface.HasConnectedDevice(dq));

      // Slot is available if it's Touchscreen, empty, or bound to a disconnected physical device
      if (is_touch || is_empty || !is_connected_physical)
      {
        target_index = i;
        break;
      }
    }

    if (target_index < 0)
      return;

    auto* target_pad = Pad::GetConfig()->GetController(target_index);
    if (!target_pad)
      return;

    if (target_pad->GetDefaultDevice() == dq_new)
      return; // no change

    target_pad->SetDefaultDevice(dq_new);
    target_pad->LoadDefaults(g_controller_interface);
    target_pad->UpdateReferences(g_controller_interface);
    Pad::GetConfig()->SaveConfig();
    NSLog(@"[DolphiniOS][Input] Auto-assigned external controller '%s' to Pad %d", dq_new.ToString().c_str(), target_index + 1);
  });
}

+ (void)ensurePad1DefaultsToTouchscreen
{
  DOLHostQueueRunSync(^{
    EnsurePad1DefaultsToTouchscreen();
  });
}

+ (void)ensureWiimoteDefaultsToTouchscreenForPort:(NSInteger)portOneBased
{
  const int idx = (int)MAX(1, portOneBased) - 1;
  if (!Wiimote::GetConfig() || Wiimote::GetConfig()->GetControllerCount() <= idx)
    return;
  auto* wm = Wiimote::GetConfig()->GetController(idx);
  if (!wm)
    return;

  Config::SetBaseOrCurrent(Config::GetInfoForWiimoteSource(idx), WiimoteSource::Emulated);

  // Build Touchscreen device qualifier for comparisons and assignment
  ciface::Core::DeviceQualifier dq_touch;
  {
    const auto devices = g_controller_interface.GetAllDevices();
    std::shared_ptr<ciface::Core::Device> touchscreen_dev;
    for (const auto& dev : devices)
    {
      if (dev && dev->GetSource() == std::string("iOS") && dev->GetName() == std::string("Touchscreen"))
      {
        touchscreen_dev = dev;
        break;
      }
    }
    if (!touchscreen_dev)
      return;
    dq_touch.FromDevice(touchscreen_dev.get());
  }

  // Respect touchscreen if already mapped elsewhere
  const int wcount = Wiimote::GetConfig()->GetControllerCount();
  for (int i = 0; i < wcount; ++i)
  {
    if (i == idx) continue;
    auto* w = Wiimote::GetConfig()->GetController(i);
    if (w && w->GetDefaultDevice() == dq_touch)
      goto after_set;
  }

  wm->SetDefaultDevice(dq_touch);
  {
    const std::string sysDirWM = wm->GetConfig()->GetSysProfileDirectoryPath();
    const std::string userDirWM = wm->GetConfig()->GetUserProfileDirectoryPath();
    const std::string sysProfileWM = sysDirWM + (sysDirWM.empty() || sysDirWM.back() == '/' ? "" : "/") + std::string("Touchscreen.ini");
    const std::string userProfileWM = userDirWM + (userDirWM.empty() || userDirWM.back() == '/' ? "" : "/") + std::string("Touchscreen.ini");
    Common::IniFile iniWM;
    if (File::Exists(userProfileWM) && iniWM.Load(userProfileWM))
      wm->LoadConfig(iniWM.GetOrCreateSection("Profile"));
    else if (File::Exists(sysProfileWM) && iniWM.Load(sysProfileWM))
      wm->LoadConfig(iniWM.GetOrCreateSection("Profile"));
    else
      wm->LoadDefaults(g_controller_interface);
  }
  wm->UpdateReferences(g_controller_interface);
  Wiimote::GetConfig()->SaveConfig();
after_set:
  NSLog(@"[DolphiniOS][Input] Ensured Wiimote%ld mapped to iOS Touchscreen: %s", (long)portOneBased, dq_touch.ToString().c_str());
}

- (void)emulationLoopWithBootParameter:(EmulationBootParameter*)bootParameter {
  dispatch_sync(dispatch_get_main_queue(), ^{
    Core::UndeclareAsHostThread();
  });

  DOLHostQueueRunSync(^{
    __block WindowSystemInfo wsi;
    wsi.type = WindowSystemType::iOS;
    wsi.render_surface = (__bridge void*)self->_metalLayer;
    wsi.render_surface_scale = [self currentRenderSurfaceScale];

    auto& system = Core::System::GetInstance();

    system.SetJitAvailable([JitManager shared].acquiredJit);

    // Clear any lingering per-run CPU core override so we honor current availability/config
    if (Config::GetLayer(Config::LayerType::CurrentRun)) {
      Config::DeleteKey(Config::LayerType::CurrentRun, Config::MAIN_CPU_CORE);
    }

    // Enforce CPU-core fallback when JIT is not available for this run
    {
      const PowerPC::CPUCore current_core = Config::Get(Config::MAIN_CPU_CORE);
      const bool is_interpreter_core = current_core == PowerPC::CPUCore::Interpreter || current_core == PowerPC::CPUCore::CachedInterpreter;
      if (![JitManager shared].acquiredJit && !is_interpreter_core)
      {
        Config::Set(Config::LayerType::CurrentRun, Config::MAIN_CPU_CORE, PowerPC::CPUCore::CachedInterpreter);
      }
    }

    __block std::unique_ptr<BootParameters> boot = [bootParameter generateDolphinBootParameter];

    // Important: Renderer initialization may mutate CAMetalLayer properties.
    // UIKit requires layer mutations on the main thread. Run BootCore on main.
    dispatch_sync(dispatch_get_main_queue(), ^{
      // Ensure we have a valid drawable size before booting to avoid CAMetalLayer warnings
      [self updateMetalLayerFrame];
      [self->_renderHost layoutIfNeeded];
      const CFTimeInterval deadline = CACurrentMediaTime() + 2.0; // up to 2s
      while ((self->_metalLayer.drawableSize.width <= 0.0 || self->_metalLayer.drawableSize.height <= 0.0) && CACurrentMediaTime() < deadline) {
        // Pump runloop briefly to let layout complete
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        [self updateMetalLayerFrame];
      }

      auto local_boot = std::move(boot);
      // Initialize controller backends before boot so devices are available
      UICommon::InitControllers(wsi);
      // Ensure GameCube Port 1 is plugged with an emulated controller and default to Touchscreen if needed
      Config::SetBaseOrCurrent(Config::GetInfoForSIDevice(0), SerialInterface::SIDEVICE_GC_CONTROLLER);
      EnsurePad1DefaultsToTouchscreen();
      if (!BootManager::BootCore(system, std::move(local_boot), wsi)) {
        PanicAlertFmt("Failed to init core!");
      }
    });
  });

  // Wait for state changes instead of polling
  dispatch_semaphore_t stateSemaphore = dispatch_semaphore_create(0);
  __block int callbackHandle = -1;
  callbackHandle = Core::AddOnStateChangedCallback([stateSemaphore](Core::State state) {
    if (state == Core::State::Running || state == Core::State::Paused || state == Core::State::Uninitialized)
      dispatch_semaphore_signal(stateSemaphore);
  });

  while (Core::GetState(Core::System::GetInstance()) == Core::State::Starting) {
    dispatch_semaphore_wait(stateSemaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)));
  }

  [[NSNotificationCenter defaultCenter] postNotificationName:DOLEmulationDidStartNotification object:self userInfo:nil];

  [self startAdaptiveClockIfEnabled];
  [self startInputPump];

  while (Core::IsRunning(Core::System::GetInstance())) {
    dispatch_semaphore_wait(stateSemaphore, DISPATCH_TIME_FOREVER);
  }

  Core::RemoveOnStateChangedCallback(&callbackHandle);

  dispatch_sync(dispatch_get_main_queue(), ^{
    Core::DeclareAsHostThread();
  });

  [self stopInputPump];
  [[NSNotificationCenter defaultCenter] postNotificationName:DOLEmulationDidEndNotification object:self userInfo:nil];

  _mainDisplayView = nil;
}

- (bool)userRequestedPause {
  return _userRequestedPause;
}

- (void)setUserRequestedPause:(bool)userRequestedPause {
  if (userRequestedPause == _userRequestedPause) {
    return;
  }

  DOLHostQueueRunSync(^{
    Core::SetState(Core::System::GetInstance(), userRequestedPause ? Core::State::Paused : Core::State::Running);
  });

  _userRequestedPause = userRequestedPause;
}

- (void)clearMetalLayer {
  id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];

  if (drawable == nil) {
    return;
  }

  MTLRenderPassDescriptor* renderPass = [MTLRenderPassDescriptor renderPassDescriptor];
  renderPass.colorAttachments[0].texture = drawable.texture;
  renderPass.colorAttachments[0].loadAction = MTLLoadActionClear;
  renderPass.colorAttachments[0].storeAction = MTLStoreActionStore;
  renderPass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

  id<MTLCommandQueue> commandQueue = [_device newCommandQueue];
  id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];

  id<MTLRenderCommandEncoder> commandEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPass];
  commandEncoder.label = @"Clear";
  [commandEncoder endEncoding];

  [commandBuffer presentDrawable:drawable];
  [commandBuffer commit];
}

@end
