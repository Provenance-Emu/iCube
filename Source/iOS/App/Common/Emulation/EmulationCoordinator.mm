// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "EmulationCoordinator.h"

#include <cmath>

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
#include "Core/HW/VideoInterface.h"
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
  // Default to the SOFTWARE (reference) vertex loader when the user hasn't picked.
  // The NEON loader has a decode bug (texcoord tail over-read / scalar-passthrough color
  // paths) that corrupts vertices on some titles — blown-up/mispositioned polygons,
  // identical across Metal/Vulkan/GLES because it's a CPU-side decode bug, not a renderer
  // issue. Software is correct and the safe default; NEON stays opt-in (mode 1) and
  // Compare (mode 2) bit-validates it. Was TEMP-defaulted to NEON for perf testing.
  if ([d objectForKey:@"icube_vertex_loader_mode"] == nil)
    return VertexLoaderType::Software;
  switch ([d integerForKey:@"icube_vertex_loader_mode"])
  {
    case 0:  return VertexLoaderType::Software;
    case 2:  return VertexLoaderType::Compare;
    default: return VertexLoaderType::NEON;  // 1
  }
}

// Adaptive clock v2 phases.
enum {
  ACPhase_Verify = 0,  // seeded from a per-game converged clock; confirm it's still stable (short)
  ACPhase_Search,      // descending sweep: step down until the variance/VPS cliff
  ACPhase_Settle,      // stepped one above the cliff; observe a longer window before committing
  ACPhase_Hold         // converged; light monitoring, re-enter Search on degradation
};

// Tunables. ALL of these need on-device tuning against real CPU-bound titles — the constants below
// are reasoned starting points, not measured optima. (See research synthesis §#1: validate with a
// manual underclock sweep + PerfSnapshot log first.)
static const int   ACTickMs        = 500;    // timer cadence (ms)
static const int   ACSearchStepTicks = 3;    // ~1.5s between sweep steps (3 * 500ms)
static const int   ACSettleTicks   = 14;     // ~7s settle/observation window
static const int   ACVerifyTicks   = 5;      // ~2.5s verify of a seeded per-game clock
static const int   ACHoldTicks     = 6;      // ~3s between hold-phase health checks
static const float ACSweepStep     = 0.10f;  // CPU-clock decrement per search step
static const float ACVIStep        = 0.10f;  // VI-clock decrement when CPU-bound at the ceiling
static const float ACCpuFloor      = 0.30f;  // never sweep below this (game logic goes slow-mo)
static const float ACViFloor       = 0.50f;  // VI underclock floor
// k: frame time is "stable" while dtStd < k * dtAvg. A low optimum has tight, regular frame times;
// underclocking past the cliff makes the core miss field deadlines -> dtStd spikes. k=0.35 is a
// guess; on-device tuning required (too low = never converges, too high = converges into judder).
static const float ACVarK          = 0.35f;
// VPS must stay within this fraction of the title's native refresh to count as "at target".
static const float ACVpsTolerance  = 0.04f;  // 4%
// dup-present ratio above this means the core is repeatedly missing fields (slow-motion) -> back off.
static const float ACDupRatioMax   = 0.10f;  // 10% of presents are duplicates

@implementation EmulationCoordinator {
  UIView* _renderHost;
  SafeMainThreadMetalLayer* _metalLayer;
  id<MTLDevice> _device;
  UIView* _mainDisplayView;
  dispatch_source_t _adaptiveClockTimer;
  dispatch_source_t _inputPumpTimer;

  // --- Adaptive clock v2 (descending-sweep, frame-time-stability objective) ---
  // OBJECTIVE (matches what Joe does by hand): find the LOWEST emulated CPU clock that still holds
  // a stable frame time + VPS-at-target + no audio underruns. The old loop sought the HIGHEST clock
  // holding speed% >= 92 (setpoint inversion): speed% reads ~100 across the whole feasible region
  // (the throttle target is the FIXED cpu clock, SystemTimers.cpp), so it was blind to the low
  // optimum and its probe-up logic kept walking back toward the can't-keep-up cliff. v2 watches
  // frame-time variance (dtStd/dtAvg), VPS vs the title's native refresh, the duplicate-present
  // ratio, and audio underruns — the only signals that actually move at the low optimum.
  float _acCPU;            // current applied CPU overclock (the lever we sweep). [floor .. 1.0]
  float _acVI;             // current applied VI overclock (the second lever, used when CPU-bound
                           // and still short at clock ceiling). Adapted in v2 (v1 never touched it).
  float _acLastApplied;    // last MAIN_OVERCLOCK we wrote; if it changes underneath us, user did it
  float _acStableCPU;      // lowest CPU clock confirmed stable this session (the converged value)
  float _acLastPersisted;  // last value written to NSUserDefaults, to avoid redundant writes
  BOOL  _acYielded;        // user took manual clock control this session -> stop adjusting

  int   _acPhase;          // ACPhase_* below
  int   _acPhaseTicks;     // ticks elapsed in the current phase (timer fires every ACTickMs)
  // Underrun baseline captured at the start of an observation window, to detect NEW underruns.
  unsigned long long _acUnderrunBase;
  unsigned long long _acDupBase;     // duplicate-present count at window start
  unsigned long long _acTotalBase;   // total-present count at window start

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

  // One-time cleanup of damage from older loops. Runs regardless of whether adaptive clock is
  // currently enabled — an older loop may already have poisoned saved config, and merely disabling
  // adaptive clock must not leave that poison in place.
  //
  // schema_v < 2: the original open-loop ratchet.
  // schema_v < 3: the hill-climb loop (sought the HIGHEST clock holding speed>=92 — setpoint
  //   inversion). Its persisted per-game clocks are the WRONG setpoint and would seed v2's
  //   descending sweep from the wrong place, so purge them and relearn.
  if ([defaults integerForKey:@"adaptive_clock_schema_v"] < 3) {
    for (NSString* key in [[defaults dictionaryRepresentation] allKeys]) {
      if ([key hasPrefix:@"adaptive_clock_cpu_"] || [key hasPrefix:@"adaptive_clock_vi_"])
        [defaults removeObjectForKey:key];
    }
    // Older loops wrote overclock via the Base layer (serializes to Dolphin.ini), so a stale
    // underclock can be baked into saved config, invisible to the NSUserDefaults purge. Reset
    // artifact underclocks (< 1.0) to default; a deliberate overclock (> 1.0) is left untouched.
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
    [defaults setInteger:3 forKey:@"adaptive_clock_schema_v"];
  }

  // The adaptive loop itself only runs when the user has enabled it (existing toggle — no new one).
  if (![defaults boolForKey:@"adaptive_clock_enable"]) return;

  // Optional NSUserDefaults override tunables (no Config/bridge entries; read here only). Any of
  // these absent -> the compiled defaults above are used.
  const float varK = [defaults objectForKey:@"adaptive_clock_var_k"]
                         ? [defaults floatForKey:@"adaptive_clock_var_k"] : ACVarK;
  const float sweepStep = [defaults objectForKey:@"adaptive_clock_sweep_step"]
                         ? [defaults floatForKey:@"adaptive_clock_sweep_step"] : ACSweepStep;

  _acVI = Config::Get(Config::MAIN_VI_OVERCLOCK);
  _acCPU = MIN(1.0f, MAX(ACCpuFloor, (float)Config::Get(Config::MAIN_OVERCLOCK)));
  _acStableCPU = 1.0f;
  _acLastApplied = -1.f;
  _acLastPersisted = -1.f;
  _acYielded = NO;
  _acPhase = ACPhase_Search;  // default: full descending sweep from the current clock
  _acPhaseTicks = 0;
  _acUnderrunBase = PerformanceMetrics::GetAudioUnderrunCount();
  _acDupBase = PerformanceMetrics::GetDuplicatePresentCount();
  _acTotalBase = PerformanceMetrics::GetTotalPresentCount();
  PerformanceMetrics::SetBound(PerformanceMetrics::Bound::Unknown);

  // Per-game seed: if we converged + verified a lowest-stable clock for this title before, start
  // there and run a SHORT verify instead of a full sweep.
  const std::string gid = SConfig::GetInstance().GetGameID();
  _adaptiveGameID = gid.empty() ? nil : [NSString stringWithUTF8String:gid.c_str()];
  if (_adaptiveGameID) {
    NSString* cpuKey = [@"adaptive_clock_cpu_" stringByAppendingString:_adaptiveGameID];
    if ([defaults objectForKey:cpuKey]) {
      _acCPU = MIN(1.0f, MAX(ACCpuFloor, [defaults floatForKey:cpuKey]));
      _acStableCPU = _acCPU;
      _acLastPersisted = _acCPU;
      _acPhase = ACPhase_Verify;
    }
    NSString* viKey = [@"adaptive_clock_vi_" stringByAppendingString:_adaptiveGameID];
    if ([defaults objectForKey:viKey])
      _acVI = MAX(ACViFloor, [defaults floatForKey:viKey]);
  }

  // Apply the starting clocks on the CurrentRun layer only (never Base/Dolphin.ini).
  Config::SetCurrent(Config::MAIN_OVERCLOCK_ENABLE, _acCPU < 1.0f);
  Config::SetCurrent(Config::MAIN_OVERCLOCK, _acCPU);
  _acLastApplied = _acCPU;
  // Restore the seeded VI overclock too (otherwise the per-game VI seed is read but never applied).
  Config::SetCurrent(Config::MAIN_VI_OVERCLOCK_ENABLE, _acVI < 1.0f);
  Config::SetCurrent(Config::MAIN_VI_OVERCLOCK, _acVI);

  _adaptiveClockTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
  dispatch_source_set_timer(_adaptiveClockTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                            (uint64_t)NSEC_PER_MSEC * ACTickMs, NSEC_PER_MSEC * 50);
  dispatch_source_set_event_handler(_adaptiveClockTimer, ^{
    auto& sys = Core::System::GetInstance();
    if (Core::GetState(sys) != Core::State::Running) return;
    const NSProcessInfoThermalState thermal = NSProcessInfo.processInfo.thermalState;
    // Capture by value (self, thermal, tunables): the host job can run after this handler returns.
    Core::QueueHostJob([self, thermal, varK, sweepStep](Core::System& s) {
      if (Core::GetState(s) != Core::State::Running) return;
      if (self->_acYielded) return;

      // Manual control wins: if the CPU clock moved underneath us (user slider), yield this session.
      const float curOC = (float)Config::Get(Config::MAIN_OVERCLOCK);
      if (self->_acLastApplied >= 0.f && fabsf(curOC - self->_acLastApplied) > 0.005f) {
        self->_acYielded = YES;
        return;
      }

      // --- Sample the sensors. ---
      const double vps = g_perf_metrics.GetVPS();
      if (vps <= 0.0) return;  // metrics not warmed up
      const double dtAvg = g_perf_metrics.GetFrameDtAvgSeconds();
      const double dtStd = g_perf_metrics.GetFrameDtStdSeconds();
      const unsigned long long underruns = PerformanceMetrics::GetAudioUnderrunCount();
      const unsigned long long dups = PerformanceMetrics::GetDuplicatePresentCount();
      const unsigned long long total = PerformanceMetrics::GetTotalPresentCount();

      // Target = the title's native field rate (NOT a fixed 60: a 30/50Hz title is fine below 60).
      double targetVPS = s.GetVideoInterface().GetTargetRefreshRate();
      if (!(targetVPS > 1.0) || !std::isfinite(targetVPS)) targetVPS = 60.0;

      // Thermal caps the APPLIED clock; we only PERSIST a baseline while cool.
      const bool cool = (thermal <= NSProcessInfoThermalStateFair);
      float ceiling = 1.0f;
      if (thermal == NSProcessInfoThermalStateCritical) ceiling = 0.65f;
      else if (thermal == NSProcessInfoThermalStateSerious) ceiling = 0.80f;

      // Health of the window since it began (deltas off the captured baselines).
      const bool newUnderrun = (underruns > self->_acUnderrunBase);
      const unsigned long long dDup = dups - self->_acDupBase;
      const unsigned long long dTot = total - self->_acTotalBase;
      const double dupRatio = (dTot > 0) ? (double)dDup / (double)dTot : 0.0;
      const bool varStable = (dtAvg > 0.0) && (dtStd < varK * dtAvg);
      const bool vpsAtTarget = (vps >= targetVPS * (1.0 - ACVpsTolerance));
      const bool dupOk = (dupRatio <= ACDupRatioMax);
      // "Stable at this clock" == the manual objective: smooth frame time + VPS held + no underrun.
      const bool stableHere = varStable && vpsAtTarget && dupOk && !newUnderrun;

      // LOWER-CLIFF signal: the emulated field cadence can't be met (slow-motion game logic) —
      // duplicate presents pile up and/or audio starves. Unlike VPS (which the throttle pins to
      // ~target whenever the host keeps up), these signals fire at the BOTTOM of the feasible
      // region and persist regardless of how low the CPU clock already is. This is the condition
      // where the VI overclock — the second lever — is worth shedding: fewer emulated VI events
      // per frame reclaims host headroom for the actual per-field work.
      const bool lowerCliff = !dupOk || newUnderrun;

      const PerformanceMetrics::Bound bound = PerformanceMetrics::GetBound();

      const auto resetWindow = ^{
        self->_acUnderrunBase = underruns;
        self->_acDupBase = dups;
        self->_acTotalBase = total;
        self->_acPhaseTicks = 0;
      };
      const auto applyCPU = ^(float v) {
        self->_acCPU = MIN(1.0f, MAX(ACCpuFloor, v));
        const float applied = MIN(self->_acCPU, ceiling);
        Config::SetCurrent(Config::MAIN_OVERCLOCK_ENABLE, applied < 1.0f);
        Config::SetCurrent(Config::MAIN_OVERCLOCK, applied);
        self->_acLastApplied = applied;
      };
      const auto applyVI = ^(float v) {
        self->_acVI = MAX(ACViFloor, MIN(1.0f, v));
        Config::SetCurrent(Config::MAIN_VI_OVERCLOCK_ENABLE, self->_acVI < 1.0f);
        Config::SetCurrent(Config::MAIN_VI_OVERCLOCK, self->_acVI);
      };
      const auto persistConverged = ^{
        if (!cool || !self->_adaptiveGameID) return;
        if (self->_acCPU != self->_acLastPersisted) {
          [NSUserDefaults.standardUserDefaults
              setFloat:self->_acCPU
                forKey:[@"adaptive_clock_cpu_" stringByAppendingString:self->_adaptiveGameID]];
          self->_acLastPersisted = self->_acCPU;
        }
        [NSUserDefaults.standardUserDefaults
            setFloat:self->_acVI
              forKey:[@"adaptive_clock_vi_" stringByAppendingString:self->_adaptiveGameID]];
      };

      self->_acPhaseTicks++;

      switch (self->_acPhase) {
        case ACPhase_Verify: {
          // Seeded from a per-game clock; confirm it still holds for a short window.
          if (self->_acPhaseTicks < ACVerifyTicks) break;
          if (stableHere) {
            self->_acStableCPU = self->_acCPU;
            self->_acPhase = ACPhase_Hold;
            persistConverged();
          } else {
            // Seed no longer good (different scene / thermal). Fall into a sweep from here.
            self->_acPhase = ACPhase_Search;
          }
          resetWindow();
          break;
        }

        case ACPhase_Search: {
          // Descending sweep: step down every ~1.5s until the stability cliff, then settle one up.
          if (self->_acPhaseTicks < ACSearchStepTicks) break;

          const float applied_now = MIN(self->_acCPU, ceiling);
          if (!stableHere) {
            // Unstable. Use ABSOLUTE speed (vs realtime) as the DIRECTION signal — this is NOT the
            // old objective (the old loop maximized speed>=92, blind across the flat feasible
            // plateau). Here we only use it to decide which way the instability lies:
            //   speed < ~0.95  -> host can't emulate this clock in realtime; we're ABOVE the
            //                     feasible region (e.g. underspeed at OC=1.0, the canonical
            //                     iCube title) -> keep descending INTO the region.
            //   speed ~= 1.0   -> throttled but VPS short / variance high -> we fell off the
            //                     BOTTOM (game logic running slow-motion) -> step back up & settle.
            const double speed = g_perf_metrics.GetSpeed();
            const bool hostBound = (speed < 0.95);
            if (hostBound && applied_now - sweepStep >= ACCpuFloor &&
                bound != PerformanceMetrics::Bound::GpuBound) {
              applyCPU(self->_acCPU - sweepStep);
              resetWindow();
              break;
            }
            // Fell off the bottom (or GPU-bound / at floor): step back up one and observe (settle).
            applyCPU(self->_acCPU + sweepStep);
            self->_acStableCPU = self->_acCPU;
            self->_acPhase = ACPhase_Settle;
            resetWindow();
            break;
          }

          // Stable here. If there's still room to go lower AND lowering would plausibly help
          // (we're CPU-bound, or unclassified), take another step down.
          if (applied_now - sweepStep >= ACCpuFloor &&
              bound != PerformanceMetrics::Bound::GpuBound) {
            applyCPU(self->_acCPU - sweepStep);
            resetWindow();
          } else {
            // At the floor, or the resolution controller says GPU-bound (clock isn't the limit).
            self->_acStableCPU = self->_acCPU;
            self->_acPhase = ACPhase_Settle;
            resetWindow();
          }
          break;
        }

        case ACPhase_Settle: {
          // Observe the settle clock over a longer window before committing to HOLD.
          if (self->_acPhaseTicks < ACSettleTicks) break;
          if (stableHere) {
            self->_acPhase = ACPhase_Hold;
            persistConverged();
          } else if (lowerCliff && bound != PerformanceMetrics::Bound::GpuBound &&
                     self->_acCPU - sweepStep < ACCpuFloor + 0.001f &&
                     self->_acVI - ACVIStep >= ACViFloor) {
            // Hit the LOWER cliff with the CPU clock already near its floor: dropping CPU more
            // won't help (game logic is the limit). Shed VI overclock — the second lever — to
            // reclaim host headroom, then re-observe. (v1 never adapted VI at all.)
            applyVI(self->_acVI - ACVIStep);
          } else if (self->_acCPU < ceiling) {
            // Variance/VPS unstable but not the lower cliff -> we're a touch too low; nudge CPU up.
            applyCPU(self->_acCPU + sweepStep);
            self->_acStableCPU = self->_acCPU;
          }
          resetWindow();
          break;
        }

        case ACPhase_Hold:
        default: {
          // Converged. Light monitoring: if stability degrades (scene change, thermal, a GPU-bound
          // section ending) re-enter the sweep. If we're comfortably stable with headroom below the
          // converged clock, a fresh sweep can find an even lower optimum for the new scene.
          if (self->_acPhaseTicks < ACHoldTicks) break;
          if (!stableHere) {
            // Degraded. Recover toward stability then re-sweep. If we hit the LOWER cliff with the
            // CPU clock already near its floor, shed VI (the second lever) instead of raising CPU
            // (which wouldn't help — game logic is the limit). Otherwise nudge CPU up.
            if (lowerCliff && bound != PerformanceMetrics::Bound::GpuBound &&
                self->_acCPU - sweepStep < ACCpuFloor + 0.001f &&
                self->_acVI - ACVIStep >= ACViFloor) {
              applyVI(self->_acVI - ACVIStep);
            } else {
              applyCPU(self->_acCPU + sweepStep);
            }
            self->_acPhase = ACPhase_Search;
          } else {
            // Still healthy. Persist the converged baseline (idempotent) and keep holding.
            persistConverged();
          }
          resetWindow();
          break;
        }
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

#if DEBUG
  // DEBUG-only perf test-bench: start the loopback HTTP/JSON server once
  // emulation is live (g_perf_metrics meaningful). DebugServerManager is
  // @MainActor and idempotent (guards !isRunning); start() is a no-op in
  // release builds, so this whole block is also compiled out by #if DEBUG.
  // We are on the emulation background queue here, so hop to main.
  dispatch_async(dispatch_get_main_queue(), ^{
    [[DebugServerManager sharedManager] start];
  });
#endif

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
