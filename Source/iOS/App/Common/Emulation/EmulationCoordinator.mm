// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "EmulationCoordinator.h"

#import <Metal/Metal.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#import "Common/MemoryUtil.h"
#import "Common/WindowSystemInfo.h"

#import "Core/Boot/Boot.h"
#import "Core/BootManager.h"
#import "Core/Config/GraphicsSettings.h"
#import "Core/Core.h"
#import "Core/System.h"
#include "Core/ConfigManager.h"
#import "Core/Config/MainSettings.h"

#import "VideoCommon/VideoConfig.h"
#import "VideoCommon/PerformanceMetrics.h"

#import "VideoCommon/Present.h"
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
#import "iCube-Swift.h"
#include "Core/Config/WiimoteSettings.h"

static inline bool _EndsWith(const std::string& s, const char* suf)
{
  const size_t slen = s.size();
  const size_t tlen = strlen(suf);
  return slen >= tlen && 0 == s.compare(slen - tlen, tlen, suf);
}

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

// iCube: the jitless vertex loader is user-selectable from Settings via the NSUserDefaults
// key "icube_vertex_loader_mode": 0/unset = Software (safe default), 1 = NEON (SIMD),
// 2 = Compare (bit-validate NEON vs Software through Dolphin's VertexLoaderTester).
// Native is JIT codegen, so it stays on the acquiredJit non-fallback path only and is
// never returned here.
static VertexLoaderType ICubeJitlessVertexLoaderType()
{
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  // TEMP (testing "best possible"): default to NEON when the user hasn't picked yet.
  // Revert to `return VertexLoaderType::Software;` for the default once measured.
  if ([d objectForKey:@"icube_vertex_loader_mode"] == nil)
    return VertexLoaderType::NEON;
  switch ([d integerForKey:@"icube_vertex_loader_mode"])
  {
    case 0:  return VertexLoaderType::Software;
    case 2:  return VertexLoaderType::Compare;
    default: return VertexLoaderType::NEON;  // 1
  }
}

@implementation EmulationCoordinator {
  UIView* _renderHost;
  SafeMainThreadMetalLayer* _metalLayer;
  id<MTLDevice> _device;
  UIView* _mainDisplayView;
  dispatch_source_t _adaptiveClockTimer;
  dispatch_source_t _inputPumpTimer;
  float _adaptiveVI;
  float _adaptiveCPU;          // learned CPU-clock baseline (persisted). Applied value is min(this, thermal cap).
  float _acSpeedBefore;        // achieved speed % captured just before the last clock change, for grading it
  float _acLastStep;           // magnitude of the last CPU-clock change, so an ineffective one can be reverted
  float _acLastPersisted;      // last value written to NSUserDefaults, to avoid redundant writes
  float _acLastApplied;        // last MAIN_OVERCLOCK we wrote; if it changes underneath us the user did it
  int   _acLastAction;         // -1 = lowered, 0 = none, +1 = probed upward, on the previous tick
  int   _acProbeCooldown;      // ticks to wait before probing upward again (after a probe lost speed)
  BOOL  _acLowerBlocked;       // underclocking observed not to help (GPU/host-bound) -> stop underclocking
  int   _acLowerMisses;        // consecutive ineffective underclock grades; latch only after 2 (a single
                               // noisy reading must not disable auto-downclock for the whole session)
  int   _acBlockedTicks;       // ticks spent latched while still underspeeding; re-arm after a while so a
                               // scene change (menu GPU-bound -> gameplay CPU-bound) gets re-tested
  BOOL  _acYielded;            // user took manual clock control this session -> stop adjusting entirely
  NSString* _adaptiveGameID;  // current game id, for persisting learned clocks per game
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

- (UIView*)mainDisplayView {
  return _mainDisplayView;
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
  if (_adaptiveClockTimer) return;
  NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;

  // One-time cleanup of damage from the old open-loop ratchet. Runs regardless of whether
  // adaptive clock is currently enabled — the old loop may already have poisoned saved config,
  // and merely disabling adaptive clock must not leave that poison in place.
  if ([defaults integerForKey:@"adaptive_clock_schema_v"] < 2) {
    // (a) Discard per-game clocks it "learned": it drove every underspeeding title to the 0.40
    // floor and persisted that, so the data is worthless and the new loop must relearn.
    for (NSString* key in [[defaults dictionaryRepresentation] allKeys]) {
      if ([key hasPrefix:@"adaptive_clock_cpu_"] || [key hasPrefix:@"adaptive_clock_vi_"])
        [defaults removeObjectForKey:key];
    }
    // (b) The old loop wrote overclock via SetBaseOrCurrent, which lands in the Base layer that
    // serializes to Dolphin.ini — so a stale underclock can be baked into the saved config,
    // invisible to the NSUserDefaults purge and to disabling adaptive clock. The ratchet only
    // ever lowered, so reset artifact underclocks (< 1.0) to default and persist that. A
    // deliberate overclock (> 1.0) is left untouched.
    bool repaired = false;
    if (Config::Get(Config::MAIN_OVERCLOCK) < 1.0f) {
      Config::SetBase(Config::MAIN_OVERCLOCK, 1.0f);
      Config::SetBase(Config::MAIN_OVERCLOCK_ENABLE, false);
      repaired = true;
    }
    if (Config::Get(Config::MAIN_VI_OVERCLOCK) < 1.0f) {
      Config::SetBase(Config::MAIN_VI_OVERCLOCK, 1.0f);
      Config::SetBase(Config::MAIN_VI_OVERCLOCK_ENABLE, false);
      repaired = true;
    }
    if (repaired) Config::Save();
    [defaults setInteger:2 forKey:@"adaptive_clock_schema_v"];
  }

  // The adaptive loop itself only runs when the user has enabled it.
  if (![defaults boolForKey:@"adaptive_clock_enable"]) return;

  _adaptiveVI = Config::Get(Config::MAIN_VI_OVERCLOCK);
  _adaptiveCPU = Config::Get(Config::MAIN_OVERCLOCK);
  _acSpeedBefore = 0.f;
  _acLastStep = 0.f;
  _acLastPersisted = -1.f;
  _acLastApplied = -1.f;
  _acLastAction = 0;
  _acProbeCooldown = 0;
  _acLowerBlocked = NO;
  _acLowerMisses = 0;
  _acBlockedTicks = 0;
  _acYielded = NO;

  // Per-game learned clock: seed from the value the loop converged on (and verified) last time
  // this title ran, so it starts near the right clock instead of re-converging from scratch.
  const std::string gid = SConfig::GetInstance().GetGameID();
  _adaptiveGameID = gid.empty() ? nil : [NSString stringWithUTF8String:gid.c_str()];
  if (_adaptiveGameID) {
    NSString* cpuKey = [@"adaptive_clock_cpu_" stringByAppendingString:_adaptiveGameID];
    if ([defaults objectForKey:cpuKey]) {
      _adaptiveCPU = [defaults floatForKey:cpuKey];
      _acLastPersisted = _adaptiveCPU;
      // CurrentRun layer only: the adaptive clock is a runtime override persisted separately in
      // NSUserDefaults — it must never write the Base layer (Dolphin.ini), or it would poison the
      // user's saved config the way the old loop did.
      Config::SetCurrent(Config::MAIN_OVERCLOCK_ENABLE, _adaptiveCPU < 1.0f);
      Config::SetCurrent(Config::MAIN_OVERCLOCK, _adaptiveCPU);
    }
  }

  // The adaptive clock manages clock within [floor, 1.0]; clamp the seed so a manual overclock
  // can't put it out of range (turn adaptive clock off to overclock above 100% manually).
  _adaptiveCPU = MIN(1.0f, MAX(0.40f, _adaptiveCPU));

  _adaptiveClockTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
  dispatch_source_set_timer(_adaptiveClockTimer, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC * 2, NSEC_PER_MSEC * 100);
  dispatch_source_set_event_handler(_adaptiveClockTimer, ^{
    auto& sys = Core::System::GetInstance();
    if (Core::GetState(sys) != Core::State::Running) return;
    // Read device thermal pressure here on the timer queue (NSProcessInfo is thread-safe);
    // apply clock changes on the host/CPU thread, where mutating timing config is safe.
    const NSProcessInfoThermalState thermal = NSProcessInfo.processInfo.thermalState;
    // Capture by value (self, thermal), never [&]: the host job can run after this handler
    // returns, so a reference capture of locals would dangle.
    Core::QueueHostJob([self, thermal](Core::System& s) {
      if (Core::GetState(s) != Core::State::Running) return;
      if (self->_acYielded) return;  // user took manual clock control this session

      // Manual control wins: if the CPU clock changed underneath us since our last write — i.e.
      // the user moved a slider in either settings UI — yield for the rest of the session so the
      // autoclock never fights or silently overwrites a hand-tuned value.
      const float curOC = (float)Config::Get(Config::MAIN_OVERCLOCK);
      if (self->_acLastApplied >= 0.f && fabsf(curOC - self->_acLastApplied) > 0.005f) {
        self->_acYielded = YES;
        return;
      }

      // Achieved emulation speed (100 == realtime). The emulator throttles to ~100, so this
      // tops out near 100 even with spare headroom — which is why we PROBE upward to find
      // headroom rather than wait for >100 readings that throttling never produces.
      const float pct = (float)(g_perf_metrics.GetSpeed() * 100.0);
      if (pct <= 0.f) return;  // metrics not warmed up yet

      const float CPU_FLOOR = 0.40f;
      const float TARGET_LO = 96.0f;  // below this we are dropping frames
      const float TARGET_HI = 99.0f;  // at/above this we (apparently) hold full speed
      const float HELP_EPS  = 2.5f;   // a lower must lift speed by at least this % to count as helping
                                      // (wide enough that ~1-2% frame-rate noise can't false-latch)

      // Thermal pressure caps the APPLIED clock transiently. We only LEARN (adjust/persist the
      // baseline) while cool, so transient throttling can never corrupt the per-game baseline.
      const bool cool = (thermal <= NSProcessInfoThermalStateFair);
      float ceiling = 1.0f;
      if (thermal == NSProcessInfoThermalStateCritical) ceiling = 0.65f;
      else if (thermal == NSProcessInfoThermalStateSerious) ceiling = 0.80f;

      // 1) Grade the previous tick's change by the speed it produced (only while cool — don't
      //    grade a change across a thermal episode, whose throttling would distort the reading).
      if (cool && self->_acLastAction == -1) {  // we underclocked last tick
        if (pct - self->_acSpeedBefore < HELP_EPS) {
          // Lowering didn't lift speed this tick. Undo the useless step. But do NOT latch on a
          // single ambiguous grade: the perf-sample window (GFX_PERF_SAMP_WINDOW, ~1s) lags the
          // 2s tick, so the first reading after a change is partly contaminated by pre-change
          // (slower) samples and can read below HELP_EPS even on a genuinely CPU-bound title.
          // Only conclude GPU/host-bound (and stop underclocking) after TWO consecutive misses.
          self->_adaptiveCPU = MIN(1.0f, self->_adaptiveCPU + self->_acLastStep);
          if (++self->_acLowerMisses >= 2) {
            self->_acLowerBlocked = YES;
            self->_acBlockedTicks = 0;
          }
        } else {
          // Lowering helped -> genuinely CPU-bound; clear the miss streak.
          self->_acLowerMisses = 0;
        }
      } else if (cool && self->_acLastAction == +1) {  // we probed upward last tick
        if (pct < TARGET_LO) {
          // Raising it cost us full speed -> step back down and hold off probing for a while.
          self->_adaptiveCPU = MAX(CPU_FLOOR, self->_adaptiveCPU - self->_acLastStep);
          self->_acProbeCooldown = 30;  // ~60s at the 2s tick
        }
      }
      self->_acLastAction = 0;

      // Re-arm a blocked title after a while. A latch means "underclocking didn't help" for the
      // scene we tested — but the bottleneck shifts (a GPU-bound menu becomes a CPU-bound level),
      // so periodically clear the latch and re-test instead of giving up for the whole session.
      // (Without this, one early ambiguous grade used to disable auto-downclock permanently.)
      if (cool && self->_acLowerBlocked && pct < TARGET_LO) {
        if (++self->_acBlockedTicks >= 15) {  // ~30s at the 2s tick
          self->_acLowerBlocked = NO;
          self->_acLowerMisses = 0;
          self->_acBlockedTicks = 0;
        }
      }

      // 2) Choose this tick's change.
      const float applied_now = MIN(self->_adaptiveCPU, ceiling);
      if (cool && pct < TARGET_LO && !self->_acLowerBlocked && applied_now > CPU_FLOOR) {
        // Underspeed and lowering still plausibly helps -> step down proportional to the deficit.
        const float deficit = (TARGET_LO - pct) / 100.0f;   // 0 .. ~1
        const float step = MIN(0.20f, MAX(0.04f, deficit));
        const float next = MAX(CPU_FLOOR, applied_now - step);
        if (next < self->_adaptiveCPU) {
          self->_acLastStep = self->_adaptiveCPU - next;
          self->_adaptiveCPU = next;
          self->_acSpeedBefore = pct;
          self->_acLastAction = -1;
        }
      } else if (cool && pct >= TARGET_HI &&
                 self->_acProbeCooldown == 0 && self->_adaptiveCPU < ceiling) {
        // Holding full speed with thermal headroom -> probe upward to recover game-logic fidelity
        // (and to climb back out of any earlier over-underclock). If it costs speed, step (1) reverts.
        const float next = MIN(ceiling, self->_adaptiveCPU + 0.04f);
        if (next > self->_adaptiveCPU) {
          self->_acLastStep = next - self->_adaptiveCPU;
          self->_adaptiveCPU = next;
          self->_acSpeedBefore = pct;
          self->_acLastAction = +1;
          self->_acLowerBlocked = NO;  // re-evaluate the bottleneck after changing the clock
        }
      } else if (self->_acProbeCooldown > 0) {
        self->_acProbeCooldown--;
      }

      // 3) Apply the thermal-clamped clock, and persist ONLY a verified-good resting baseline:
      // one that actually delivers full speed while the device is cool. A value that fails to
      // hit target (e.g. a GPU-bound title) is never saved at a needless underclock, and a
      // throttled reading never becomes the per-game default.
      const float applied = MIN(self->_adaptiveCPU, ceiling);
      Config::SetCurrent(Config::MAIN_OVERCLOCK_ENABLE, applied < 1.0f);
      Config::SetCurrent(Config::MAIN_OVERCLOCK, applied);
      self->_acLastApplied = applied;  // remember our own write so we can detect a manual change
      if (pct >= TARGET_LO && thermal <= NSProcessInfoThermalStateFair &&
          self->_adaptiveGameID && self->_adaptiveCPU != self->_acLastPersisted) {
        [NSUserDefaults.standardUserDefaults
            setFloat:self->_adaptiveCPU
              forKey:[@"adaptive_clock_cpu_" stringByAppendingString:self->_adaptiveGameID]];
        self->_acLastPersisted = self->_adaptiveCPU;
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
    NSLog(@"[iCube][Input] Ensured Pad1 mapped to iOS Touchscreen: %s", dq_touch.ToString().c_str());
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
      // Explicitly disable Wiimote 2-4 to avoid phantom P2 on Wii IR
      for (int i = 1; i < std::min(4, Wiimote::GetConfig()->GetControllerCount()); ++i)
        Config::SetBaseOrCurrent(Config::GetInfoForWiimoteSource(i), WiimoteSource::None);

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

        // If any user Wiimote profile exists, skip auto-loading stock profile to respect user mappings
        bool user_has_any_profile = false;
        {
          auto entries = File::ScanDirectoryTree(userDirWM, false);
          for (const auto& child : entries.children)
          {
            if (!child.isDirectory && _EndsWith(child.physicalName, ".ini")) { user_has_any_profile = true; break; }
          }
        }

        Common::IniFile iniWM;
        if (!user_has_any_profile && File::Exists(userProfileWM) && iniWM.Load(userProfileWM))
        {
          wm0->LoadConfig(iniWM.GetOrCreateSection("Profile"));
          loaded_profile_wm = true;
        }
        else if (!user_has_any_profile && File::Exists(sysProfileWM) && iniWM.Load(sysProfileWM))
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
      NSLog(@"[iCube][Input] Ensured Wiimote1 mapped to iOS Touchscreen: %s", dq_touch.ToString().c_str());
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
    NSLog(@"[iCube][Input] Auto-assigned external controller '%s' to Pad %d", dq_new.ToString().c_str(), target_index + 1);
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
    const auto join = [](const std::string& dir, const char* file) {
      return dir + (dir.empty() || dir.back() == '/' ? "" : "/") + std::string(file);
    };
    // Prefer MotionPlus profile to ensure gyro is enabled by default
    const std::string sysMP = join(sysDirWM, "Wii Remote with MotionPlus Pointing.ini");
    const std::string userMP = join(userDirWM, "Wii Remote with MotionPlus Pointing.ini");
    const std::string sysTS = join(sysDirWM, "Touchscreen.ini");
    const std::string userTS = join(userDirWM, "Touchscreen.ini");
    Common::IniFile iniWM;
    if (File::Exists(userMP) && iniWM.Load(userMP))
      wm->LoadConfig(iniWM.GetOrCreateSection("Profile"));
    else if (File::Exists(sysMP) && iniWM.Load(sysMP))
      wm->LoadConfig(iniWM.GetOrCreateSection("Profile"));
    else if (File::Exists(userTS) && iniWM.Load(userTS))
      wm->LoadConfig(iniWM.GetOrCreateSection("Profile"));
    else if (File::Exists(sysTS) && iniWM.Load(sysTS))
      wm->LoadConfig(iniWM.GetOrCreateSection("Profile"));
    else
      wm->LoadDefaults(g_controller_interface);
  }
  wm->UpdateReferences(g_controller_interface);
  Wiimote::GetConfig()->SaveConfig();
after_set:
  NSLog(@"[iCube][Input] Ensured Wiimote%ld mapped to iOS Touchscreen: %s", (long)portOneBased, dq_touch.ToString().c_str());
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

    // Set up JIT type and allocate executable memory region.
    //
    // txmInterpreterFallback: true when we're on an iOS 26 TXM device but cannot use
    // JIT (running under Xcode, not StikDebug). In this case we use LuckNoTXM for
    // memory typing (no brk required, writes go through RW alias) but force
    // CachedInterpreter + Software VertexLoader so nothing ever executes from JIT pages.
    bool txmInterpreterFallback = false;

    if ([JitManager shared].acquiredJit)
    {
      if (@available(iOS 26, tvOS 26, *))
      {
        if ([JitManager shared].deviceHasTxm)
        {
          // TXM device + CS_DEBUGGED.
          //
          // Default: safe path — LuckNoTXM + CachedInterpreter + Software VertexLoader.
          // LuckNoTXM writes through an RW alias (no pthread_jit_write_protect_np needed),
          // and since no JIT code is generated TXM never blocks execution.
          // This works under both Xcode and StikDebug without any brk #0x69.
          //
          // Opt-in: StikDebug users who want full LuckTXM JIT set DOL_JIT_TXM=1
          // in their Xcode scheme environment variables. StikDebug intercepts brk #0x69,
          // authorizes TXM, and vm_remap succeeds for the full JIT path.
          NSDictionary* env = [[NSProcessInfo processInfo] environment];
          BOOL forceTXM = [env[@"DOL_JIT_TXM"] isEqualToString:@"1"];

          if (forceTXM)
          {
            // StikDebug opt-in: use LuckTXM + full JIT.
            Common::SetJitType(Common::JitType::LuckTXM);
            Common::AllocateExecutableMemoryRegion();

            // If AllocateExecutableMemoryRegion bailed out (e.g. LLDB skipped the brk
            // and cleared dolphin_txm_auth_status), fall back to interpreter anyway.
            if (!Common::IsTXMAvailable())
            {
              txmInterpreterFallback = true;
            }
          }
          else
          {
            // Default safe path: interpreter fallback, no brk needed.
            Common::SetJitType(Common::JitType::LuckNoTXM);
            txmInterpreterFallback = true;
          }
        }
        else
        {
          // Non-TXM iOS 26 device: dual-mapping works fine.
          Common::SetJitType(Common::JitType::LuckNoTXM);
          Common::AllocateExecutableMemoryRegion(); // no-op for LuckNoTXM
        }
      }
      else
      {
        Common::SetJitType(Common::JitType::Legacy);
        Common::AllocateExecutableMemoryRegion(); // no-op for Legacy
      }

      Config::SetBase(Config::GFX_VERTEX_LOADER_TYPE,
                      txmInterpreterFallback ? ICubeJitlessVertexLoaderType()
                                             : VertexLoaderType::Native);
    }
    else
    {
      Config::SetBase(Config::GFX_VERTEX_LOADER_TYPE, ICubeJitlessVertexLoaderType());
    }

    // Clear any lingering per-run CPU core override so we honor current availability/config
    if (Config::GetLayer(Config::LayerType::CurrentRun)) {
      Config::DeleteKey(Config::LayerType::CurrentRun, Config::MAIN_CPU_CORE);
    }

    // Enforce CPU-core fallback when JIT is not available for this run.
    // Covers: (a) no debugger attached, (b) iOS 26 TXM device under Xcode.
    {
      const PowerPC::CPUCore current_core = Config::Get(Config::MAIN_CPU_CORE);
      const bool is_interpreter_core = current_core == PowerPC::CPUCore::Interpreter || current_core == PowerPC::CPUCore::CachedInterpreter;
      if ((![JitManager shared].acquiredJit || txmInterpreterFallback) && !is_interpreter_core)
      {
        Config::SetCurrent(Config::MAIN_CPU_CORE, PowerPC::CPUCore::CachedInterpreter);
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
