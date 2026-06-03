// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "EmulationCoordinator.h"

#include <cmath>
#include <mach/mach.h>
#include <sys/sysctl.h>

#import <Metal/Metal.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#import "Common/Logging/Log.h"
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
#import "FastmemManager.h"
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

// Dump the perf-relevant settings as one readable key=value block, once at game START and once at
// game EXIT. Goes to both NSLog (device console) and INFO_LOG_FMT(CORE, ...) (Dolphin log file) so
// Joe can copy-paste it straight into a bug report. Values are formatted human-readably (true/false,
// enum names) rather than raw ints.
// Build the perf-relevant settings as one readable key=value block. Shared by the START/EXIT logger
// (_ICubeDumpPerfSettings) and the "Copy State" clipboard button (+copyStateToClipboard) so both
// emit the exact same SETTINGS content.
static std::string _ICubeBuildPerfSettingsString(const char* phase)
{
  auto boolStr = [](bool v) { return v ? "true" : "false"; };
  auto triStr = [](TriState v) {
    switch (v) { case TriState::Off: return "Off"; case TriState::On: return "On"; default: return "Auto"; }
  };

  const std::string gid = SConfig::GetInstance().GetGameID();
  const std::string title = SConfig::GetInstance().GetTitleName();
  const bool adaptiveClock = [[NSUserDefaults standardUserDefaults] boolForKey:@"adaptive_clock_enable"];
  const bool fastmemCfg = Config::Get(Config::MAIN_FASTMEM);
  const bool fastmemAvail = [FastmemManager shared].fastmemAvailable;

  std::string b;
  b.reserve(1400);
  auto line = [&](const char* k, const std::string& v) { b += "  "; b += k; b += "="; b += v; b += "\n"; };
  auto lineB = [&](const char* k, bool v) { line(k, boolStr(v)); };
  auto lineI = [&](const char* k, long v) { line(k, std::to_string(v)); };
  auto lineF = [&](const char* k, float v) { char buf[32]; snprintf(buf, sizeof(buf), "%.3f", v); line(k, buf); };

  b += "=== iCube settings @ ";
  b += phase;
  b += " ";
  b += gid.empty() ? "(no-gameid)" : gid;
  b += " ===\n";
  line("title", title.empty() ? "(unknown)" : title);
  line("MAIN_CPU_CORE", std::to_string((int)Config::Get(Config::MAIN_CPU_CORE)));
  lineB("MAIN_CPU_THREAD(dual-core)", Config::Get(Config::MAIN_CPU_THREAD));
  lineB("MAIN_OVERCLOCK_ENABLE", Config::Get(Config::MAIN_OVERCLOCK_ENABLE));
  lineF("MAIN_OVERCLOCK", (float)Config::Get(Config::MAIN_OVERCLOCK));
  lineB("MAIN_VI_OVERCLOCK_ENABLE", Config::Get(Config::MAIN_VI_OVERCLOCK_ENABLE));
  lineF("MAIN_VI_OVERCLOCK", (float)Config::Get(Config::MAIN_VI_OVERCLOCK));
  lineB("adaptive_clock_enable(NSUserDefault)", adaptiveClock);
  lineI("GFX_EFB_SCALE", Config::Get(Config::GFX_EFB_SCALE));
  lineB("GFX_AUTO_IR_ENABLE", Config::Get(Config::GFX_AUTO_IR_ENABLE));
  line("GFX_HACK_VI_SKIP_MODE", triStr(Config::Get(Config::GFX_HACK_VI_SKIP_MODE)));
  lineB("MAIN_CIR_PIC_LOADSTORE", Config::Get(Config::MAIN_CIR_PIC_LOADSTORE));
  lineB("MAIN_CIR_MICROOP_FUSION", Config::Get(Config::MAIN_CIR_MICROOP_FUSION));
  lineB("MAIN_CIR_BLOCK_LINKING", Config::Get(Config::MAIN_CIR_BLOCK_LINKING));
  lineB("MAIN_CIR_SPECIALIZED_OPS", Config::Get(Config::MAIN_CIR_SPECIALIZED_OPS));
  lineB("GFX_USE_COMPUTE_EFBXFB", Config::Get(Config::GFX_USE_COMPUTE_EFBXFB));
  lineB("GFX_USE_COMPUTE_VERTEX_DECODE", Config::Get(Config::GFX_USE_COMPUTE_VERTEX_DECODE));
  lineB("MAIN_DSP_HLE", Config::Get(Config::MAIN_DSP_HLE));
  lineB("MAIN_FAST_DISC_SPEED", Config::Get(Config::MAIN_FAST_DISC_SPEED));
  lineB("MAIN_SYNC_ON_SKIP_IDLE", Config::Get(Config::MAIN_SYNC_ON_SKIP_IDLE));
  line("MAIN_GFX_BACKEND", Config::Get(Config::MAIN_GFX_BACKEND));
  lineB("MAIN_FASTMEM(cfg)", fastmemCfg);
  lineB("fastmem_available(host)", fastmemAvail);
  b += "=== end ===";
  return b;
}

// Dump the perf-relevant settings once at game START and once at game EXIT, to both NSLog (device
// console) and INFO_LOG_FMT(CORE, ...) (Dolphin log file) so Joe can copy-paste it into a bug report.
static void _ICubeDumpPerfSettings(const char* phase)
{
  const std::string b = _ICubeBuildPerfSettingsString(phase);
  NSLog(@"%s", b.c_str());
  INFO_LOG_FMT(CORE, "{}", b);
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

// Adaptive clock v3 phases.
enum {
  ACPhase_Verify = 0,  // seeded from a per-game f* clock; confirm it still holds, then ±1 re-find
  ACPhase_Search,      // descending sweep from 1.0: STOP at the first (=highest) clock meeting f*
  ACPhase_Settle,      // observe the settle clock over a longer window before committing
  ACPhase_Hold         // converged at f*; light monitoring, re-enter Search on degradation
};

// Tunables. The CONTROL LAW (cliff-find: stop descending at the first/highest clock that meets the
// f* criterion) is the thing under test; these constants are reasoned starting points and still
// need on-device tuning against real CPU-bound titles. (See research synthesis §#1: validate with a
// manual underclock sweep + PerfSnapshot log first.)
static const int   ACTickMs        = 500;    // timer cadence (ms)
static const int   ACSearchStepTicks = 3;    // ~1.5s between sweep steps (3 * 500ms)
static const int   ACSettleTicks   = 14;     // ~7s settle/observation window
static const int   ACVerifyTicks   = 5;      // ~2.5s verify of a seeded per-game clock
static const int   ACHoldTicks     = 6;      // ~3s between hold-phase health checks
static const float ACSweepStep     = 0.10f;  // CPU-clock decrement per search step
static const float ACVIStep        = 0.10f;  // VI-clock decrement (secondary lever, CPU floored)
static const float ACCpuFloor      = 0.30f;  // never sweep below this (game logic goes slow-mo)
static const float ACViFloor       = 0.50f;  // VI underclock floor
// f* GO/NO-GO: the emulated speed (vs realtime) must hold at/above this to count as "keeps up".
// At and above f* on a CPU-bound title the interpreter can't keep up -> speed drops below this ->
// keep descending. This is the PRIMARY discriminator (it is the only sensor that moves AT f*).
static const float ACSpeedThreshold = 0.99f;
// Hysteresis below ACSpeedThreshold for the settle decision: keeps a marginal windowed-speed dip
// right at the cliff (e.g. 98.5%) from descending one step PAST f*. Speed is the ONLY GO/NO-GO
// sensor. The former VPS≈FPS and dup-ratio guards were REMOVED: a 30fps-by-design title (common on
// GC/Wii) presents ~50% duplicate fields at FULL speed, so those guards vetoed legit 30fps games and
// walked the sweep to the floor (slow-motion). Audio underrun is the one remaining honesty guard.
static const float ACSpeedHysteresis = 0.02f;

@implementation EmulationCoordinator {
  UIView* _renderHost;
  SafeMainThreadMetalLayer* _metalLayer;
  id<MTLDevice> _device;
  UIView* _mainDisplayView;
  dispatch_source_t _adaptiveClockTimer;
  dispatch_source_t _inputPumpTimer;

  // --- Adaptive clock v3 (descending CLIFF-FIND, highest-clock-at-full-speed objective) ---
  // OBJECTIVE (matches what Joe does by hand): find f* = the HIGHEST emulated CPU clock at which
  // achieved emulation speed is still ~100% AND VPS tracks FPS (honest frame delivery, not inflated
  // by duplicate presents). f* is the edge of the speed cliff:
  //   - at/above f*  on a CPU-bound title the interpreter can't keep up -> speed < ~99% -> laggy.
  //   - below f*     speed is still ~100% but the game gets LESS virtual CPU than the host can
  //                  afford -> internal logic runs slow-motion. Wasteful.
  // The cliff is found ONLY by direction of approach: descend from 1.0 and STOP at the FIRST clock
  // meeting the criterion — that first match is, by construction, the highest match. No point test
  // can tell f* from a lower clock (both read speed≈100%), which is exactly why the prior loop
  // (which kept descending while "stable") sailed past f* to the floor. v3 stops at first match.
  float _acCPU;            // current applied CPU overclock (the lever we sweep). [floor .. 1.0]
  float _acVI;             // current applied VI overclock (the second lever, used only when CPU is
                           // already floored and still short). Adapted since v2 (v1 never touched it).
  float _acLastApplied;    // last MAIN_OVERCLOCK we wrote; if it changes underneath us, user did it
  float _acLastAppliedVI;  // last MAIN_VI_OVERCLOCK we wrote; for per-knob manual-move detection
  float _acStableCPU;      // f* — highest CPU clock confirmed at-full-speed this session (converged)
  float _acLastPersisted;  // last value written to NSUserDefaults, to avoid redundant writes
  // Per-knob, re-armable arbitration (step #2), replacing the global session-sticky _acYielded:
  // a manual move of ONE clock yields only THAT lever for the session; the auto controller keeps
  // regulating the other. Re-arm = toggle the adaptive clock off then on (startAdaptiveClockIfEnabled
  // re-inits both flags). A manual CPU touch must NOT freeze the VI lever and vice versa.
  BOOL  _acCpuYielded;     // user took manual CPU-clock control -> stop auto-adjusting CPU-oc
  BOOL  _acViYielded;      // user took manual VI-clock control  -> stop auto-adjusting VI-oc
  BOOL  _acVerifyProbedUp; // in the seeded re-find: have we already tried the +1 step above f*?

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
  //   inversion).
  // schema_v < 4: the v2 descending-MINIMIZE loop persisted the LOWEST-stable clock. v3's stored
  //   value is f* = the HIGHEST clock at full speed — a DIFFERENT meaning. A v2 "lowest-stable"
  //   value is below f* and, if reused as a seed, would settle the controller below f* (slow-motion).
  //   Purge per-game clocks and relearn so no stale lowest-stable value is ever reused as f*.
  if ([defaults integerForKey:@"adaptive_clock_schema_v"] < 4) {
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
    [defaults setInteger:4 forKey:@"adaptive_clock_schema_v"];
  }

  // The adaptive loop itself only runs when the user has enabled it (existing toggle — no new one).
  if (![defaults boolForKey:@"adaptive_clock_enable"]) return;

  // Optional NSUserDefaults override tunables (no Config/bridge entries; read here only). Any of
  // these absent -> the compiled defaults above are used.
  const float speedThreshold = [defaults objectForKey:@"adaptive_clock_speed_threshold"]
                         ? [defaults floatForKey:@"adaptive_clock_speed_threshold"] : ACSpeedThreshold;
  const float sweepStep = [defaults objectForKey:@"adaptive_clock_sweep_step"]
                         ? [defaults floatForKey:@"adaptive_clock_sweep_step"] : ACSweepStep;

  _acVI = Config::Get(Config::MAIN_VI_OVERCLOCK);
  // A fresh sweep finds f* by descending FROM 1.0 and stopping at the first match. Start at 1.0
  // (not the current Config value): f* is the highest clock holding full speed, so the sweep has
  // to begin at the top, not wherever a prior run left the clock.
  _acCPU = 1.0f;
  _acStableCPU = 1.0f;
  _acLastApplied = -1.f;
  _acLastAppliedVI = -1.f;
  _acLastPersisted = -1.f;
  _acCpuYielded = NO;
  _acViYielded = NO;
  _acVerifyProbedUp = NO;
  _acPhase = ACPhase_Search;  // default: full descending sweep from 1.0
  _acPhaseTicks = 0;
  _acUnderrunBase = PerformanceMetrics::GetAudioUnderrunCount();
  _acDupBase = PerformanceMetrics::GetDuplicatePresentCount();
  _acTotalBase = PerformanceMetrics::GetTotalPresentCount();
  PerformanceMetrics::SetBound(PerformanceMetrics::Bound::Unknown);

  // Per-game seed: if we converged + verified f* for this title before, start there and run a
  // SHORT verify + bounded ±1-step re-find (thermal drift), instead of a full sweep.
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
  _acLastAppliedVI = _acVI;

  _adaptiveClockTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
  dispatch_source_set_timer(_adaptiveClockTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                            (uint64_t)NSEC_PER_MSEC * ACTickMs, NSEC_PER_MSEC * 50);
  dispatch_source_set_event_handler(_adaptiveClockTimer, ^{
    auto& sys = Core::System::GetInstance();
    if (Core::GetState(sys) != Core::State::Running) return;
    const NSProcessInfoThermalState thermal = NSProcessInfo.processInfo.thermalState;
    // Capture by value (self, thermal, tunables): the host job can run after this handler returns.
    Core::QueueHostJob([self, thermal, speedThreshold, sweepStep](Core::System& s) {
      if (Core::GetState(s) != Core::State::Running) return;

      // --- Per-knob manual-override detection (step #2). ---
      // Manual control wins, but PER KNOB: a user CPU-clock slider yields only the CPU lever; a
      // user VI-clock slider yields only the VI lever. The other lever keeps auto-regulating, and
      // both re-arm when the adaptive clock is toggled off/on (full re-init in start...IfEnabled).
      const float curOC = (float)Config::Get(Config::MAIN_OVERCLOCK);
      if (!self->_acCpuYielded && self->_acLastApplied >= 0.f &&
          fabsf(curOC - self->_acLastApplied) > 0.005f) {
        self->_acCpuYielded = YES;
      }
      const float curVI = (float)Config::Get(Config::MAIN_VI_OVERCLOCK);
      if (!self->_acViYielded && self->_acLastAppliedVI >= 0.f &&
          fabsf(curVI - self->_acLastAppliedVI) > 0.005f) {
        // EXCLUDE the RA-hardcore VI stomp (VideoInterface.cpp:321 forces VI->1.0 on CurrentRun when
        // hardcore mode is active): a move TO ~1.0 is either that stomp or a user no-op (1.0 is the
        // default), so resync our tracking instead of yielding the lever. A genuine user VI move to
        // any value other than 1.0 still yields VI.
        if (fabsf(curVI - 1.0f) <= 0.005f) {
          self->_acLastAppliedVI = curVI;
        } else {
          self->_acViYielded = YES;
        }
      }
      // Both levers under manual control: nothing left to auto-adjust (matches the old global yield).
      if (self->_acCpuYielded && self->_acViYielded) return;

      // --- Sample the sensors. ---
      const double vps = g_perf_metrics.GetVPS();   // emulated field rate
      if (vps <= 0.0) return;  // metrics not warmed up (warmup guard only)
      const double speed = g_perf_metrics.GetSpeed();  // achieved emulation speed vs realtime
      const double maxSpeed = g_perf_metrics.GetMaxSpeed();  // speed with throttle sleep removed
      const unsigned long long underruns = PerformanceMetrics::GetAudioUnderrunCount();
      const unsigned long long dups = PerformanceMetrics::GetDuplicatePresentCount();
      const unsigned long long total = PerformanceMetrics::GetTotalPresentCount();

      // Target = the title's native field rate (NOT a fixed 60: a 30/50Hz title is fine below 60).

      // Thermal caps the APPLIED clock; we only PERSIST a baseline while cool.
      const bool cool = (thermal <= NSProcessInfoThermalStateFair);
      float ceiling = 1.0f;
      if (thermal == NSProcessInfoThermalStateCritical) ceiling = 0.65f;
      else if (thermal == NSProcessInfoThermalStateSerious) ceiling = 0.80f;

      // Health of the window since it began.
      const bool newUnderrun = (underruns > self->_acUnderrunBase);

      // --- The f* GO/NO-GO criterion: SPEED ONLY (+ underrun honesty guard). ---
      // f* = the HIGHEST clock at which the host keeps up. The throttle caps emulated speed at 100%,
      // so speed >= threshold is true for EVERY clock <= f* and false above it; descending top-down,
      // the FIRST clock that meets it is f* by construction. No second term is needed to FIND the
      // cliff — and any extra gate that can be false AT f* can only push the settle point one step
      // LOW. That is why the VPS≈FPS and dup-ratio guards were REMOVED: a 30fps-by-design title
      // (common on GC/Wii) presents ~50% duplicate fields at FULL speed, so those guards vetoed
      // legit 30fps games and walked the sweep to the floor (slow-motion) — the exact inversion this
      // controller exists to kill. Audio underrun stays as the one honesty guard (a starved buffer
      // is genuinely too-slow regardless of the speed% average). The small hysteresis keeps a
      // marginal windowed-speed dip right at the cliff from descending one step past f*.
      const bool meetsFStar = (speed >= speedThreshold - ACSpeedHysteresis) && !newUnderrun;

      // --- Bottleneck classification, decoupled from Auto-IR (step #1). ---
      // The CPU-vs-GPU `bound` flag used to be written ONLY by AutoIRController, so with Auto-IR
      // off (the default) it stayed Unknown forever and this loop ran blind. When Auto-IR is OFF,
      // publish the classification from our own speed-delta probe every tick so the routing here
      // (and the auto-VI gate, step #5) sees a real bound. When Auto-IR is ON it owns the EFB-scale
      // probe and the classification, so we don't stomp it — exactly one writer at a time.
      if (!Config::Get(Config::GFX_AUTO_IR_ENABLE)) {
        PerformanceMetrics::SetBound(
            PerformanceMetrics::ClassifyBound(speed, maxSpeed, speedThreshold));
      }
      const PerformanceMetrics::Bound bound = PerformanceMetrics::GetBound();

      const auto resetWindow = ^{
        self->_acUnderrunBase = underruns;
        self->_acDupBase = dups;
        self->_acTotalBase = total;
        self->_acPhaseTicks = 0;
      };
      const auto applyCPU = ^(float v) {
        // CPU lever yielded to manual control: don't fight the user's slider (step #2).
        if (self->_acCpuYielded) return;
        self->_acCPU = MIN(1.0f, MAX(ACCpuFloor, v));
        const float applied = MIN(self->_acCPU, ceiling);
        Config::SetCurrent(Config::MAIN_OVERCLOCK_ENABLE, applied < 1.0f);
        Config::SetCurrent(Config::MAIN_OVERCLOCK, applied);
        self->_acLastApplied = applied;
      };
      const auto applyVI = ^(float v) {
        // VI lever yielded to manual control: leave it to the user (step #2).
        if (self->_acViYielded) return;
        self->_acVI = MAX(ACViFloor, MIN(1.0f, v));
        Config::SetCurrent(Config::MAIN_VI_OVERCLOCK_ENABLE, self->_acVI < 1.0f);
        Config::SetCurrent(Config::MAIN_VI_OVERCLOCK, self->_acVI);
        self->_acLastAppliedVI = self->_acVI;
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
          // Seeded from a per-game f*. Confirm it still holds, then do a BOUNDED ±1-step re-find to
          // track thermal drift — NOT a full sweep.
          if (self->_acPhaseTicks < ACVerifyTicks) break;
          const float applied_now = MIN(self->_acCPU, ceiling);
          if (!meetsFStar) {
            if (!self->_acVerifyProbedUp) {
              // The seed no longer meets f* (the host got slower — thermal/scene). f* dropped:
              // descend one step and settle (still bounded, not a full re-sweep).
              if (applied_now - sweepStep >= ACCpuFloor) {
                applyCPU(self->_acCPU - sweepStep);
              }
              self->_acStableCPU = self->_acCPU;
              self->_acPhase = ACPhase_Settle;
            } else {
              // We had probed UP and it failed — the seed itself was f*. Step back to the seed.
              applyCPU(self->_acCPU - sweepStep);
              self->_acStableCPU = self->_acCPU;
              self->_acPhase = ACPhase_Settle;
            }
            resetWindow();
            break;
          }
          // Seed still meets f*. Probe ONE step up to see if f* rose (cooler than when learned).
          if (!self->_acVerifyProbedUp && applied_now + sweepStep <= 1.0f + 0.001f) {
            self->_acVerifyProbedUp = YES;
            applyCPU(self->_acCPU + sweepStep);
            resetWindow();
            break;  // re-enter Verify at the higher clock; if it also meets f*, we keep it.
          }
          // Either we just confirmed a successful +1 probe (f* rose), or there's no room to probe up.
          // This clock is f*. Settle.
          self->_acStableCPU = self->_acCPU;
          self->_acPhase = ACPhase_Settle;
          resetWindow();
          break;
        }

        case ACPhase_Search: {
          // CLIFF-FIND. Descend from 1.0 in steps and STOP at the FIRST clock meeting f*. Because we
          // approach from the top, the first match IS the highest match — that is f*. We never take
          // another step down once the criterion is met (doing so was the v2 MINIMIZE bug: every
          // clock at/below f* meets it, so "keep descending while it meets" walks to the floor).
          if (self->_acPhaseTicks < ACSearchStepTicks) break;

          const float applied_now = MIN(self->_acCPU, ceiling);
          if (meetsFStar) {
            // First (=highest) clock that keeps up with honest delivery. This is f*. Settle here.
            // (Includes the easy/GPU-bound case: if 1.0 already meets f*, we stay at 1.0.)
            self->_acStableCPU = self->_acCPU;
            self->_acPhase = ACPhase_Settle;
            resetWindow();
            break;
          }

          // Does not meet f* yet (host can't keep up at this clock, or delivery isn't honest).
          // Keep descending toward the feasible region — unless we're already at the floor.
          if (applied_now - sweepStep >= ACCpuFloor - 0.001f) {
            applyCPU(self->_acCPU - sweepStep);
            resetWindow();
          } else {
            // Floor reached and still not at full speed: best-effort. Settle at the floor; the
            // Settle phase may shed the VI overclock (the secondary lever) to reclaim headroom.
            applyCPU(ACCpuFloor);
            self->_acStableCPU = self->_acCPU;
            self->_acPhase = ACPhase_Settle;
            resetWindow();
          }
          break;
        }

        case ACPhase_Settle: {
          // Observe f* over a longer window before committing to HOLD.
          if (self->_acPhaseTicks < ACSettleTicks) break;
          if (meetsFStar) {
            self->_acStableCPU = self->_acCPU;
            self->_acPhase = ACPhase_Hold;
            persistConverged();
          } else if (self->_acCPU - sweepStep < ACCpuFloor + 0.001f &&
                     self->_acVI - ACVIStep >= ACViFloor &&
                     bound == PerformanceMetrics::Bound::CpuBound) {
            // CPU clock already at/near the floor AND positively CPU-bound (step #5): dropping CPU
            // more won't help (game logic is the limit). Shed VI overclock for its DISTINCT
            // refresh-rate effect (lowering the emulated field rate cuts CPU work per real second),
            // not to chase the throttle — that double-counts with the CPU lever. Require CpuBound
            // (not merely "not GpuBound"): on Unknown we must not act, or auto-VI fires on
            // unclassified data. Depends on #1's now-live classification.
            applyVI(self->_acVI - ACVIStep);
          } else if (self->_acCPU - sweepStep >= ACCpuFloor - 0.001f) {
            // f* fell (the scene got heavier than when we picked it). Direction is DOWN, not up:
            // descend one step and re-settle. (Nudging UP here would be MINIMIZE-era recovery and
            // would chase the can't-keep-up cliff — the exact inversion we removed.)
            applyCPU(self->_acCPU - sweepStep);
            self->_acStableCPU = self->_acCPU;
          }
          resetWindow();
          break;
        }

        case ACPhase_Hold:
        default: {
          // Converged at f*. Light monitoring. If we stop meeting f* (scene got heavier, thermal
          // throttle) the cliff moved DOWN -> descend to re-find it. We do NOT probe lower while
          // still meeting f* (that was the MINIMIZE bug — every clock below f* also meets it).
          if (self->_acPhaseTicks < ACHoldTicks) break;
          if (!meetsFStar) {
            if (self->_acCPU - sweepStep < ACCpuFloor + 0.001f &&
                self->_acVI - ACVIStep >= ACViFloor &&
                bound == PerformanceMetrics::Bound::CpuBound) {
              // CPU already floored AND positively CPU-bound: shed VI for its distinct refresh-rate
              // effect (step #5). Require CpuBound, not "!= GpuBound", so Unknown never triggers it.
              applyVI(self->_acVI - ACVIStep);
            } else if (self->_acCPU - sweepStep >= ACCpuFloor - 0.001f) {
              // f* dropped: descend one step and re-find by sweeping down from here.
              applyCPU(self->_acCPU - sweepStep);
            }
            self->_acVerifyProbedUp = NO;
            self->_acPhase = ACPhase_Search;
          } else {
            // Still at full speed. Persist f* (idempotent) and keep holding.
            persistConverged();
          }
          resetWindow();
          break;
        }
      }
    }, false);
  });
  // Mark the adaptive clock active so CoreTiming::GetVISkip forces VI-skip Off while it runs
  // (step #4): the two catch-up mechanisms must not overlap or VI-skip's dropped IRQs corrupt the
  // clock's speed sensor.
  PerformanceMetrics::SetAdaptiveClockActive(true);
  dispatch_resume(_adaptiveClockTimer);
}

// Live adaptive-clock toggle. ON: persist the default, then start the controller now (the start
// method early-returns unless the default is true, so order matters). OFF: cancel + nil the timer
// (mirror the inputPump stop pattern; start() guards on a non-nil source, so a cancelled-but-not-nil
// source would block re-enable) and clear the CurrentRun overclock overrides the controller wrote so
// the manual/Base values underneath are revealed again.
- (void)setAdaptiveClockEnabled:(BOOL)on {
  NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
  [defaults setBool:on forKey:@"adaptive_clock_enable"];
  if (on) {
    [self startAdaptiveClockIfEnabled];
  } else {
    if (_adaptiveClockTimer) {
      dispatch_source_cancel(_adaptiveClockTimer);
      _adaptiveClockTimer = nil;
    }
    // Adaptive clock no longer owns speed regulation: let VISkip honor the user's tri-state mode
    // again (step #4).
    PerformanceMetrics::SetAdaptiveClockActive(false);
    // Clear the four CurrentRun keys the controller sets (CPU + VI clock + their enables). The
    // controller writes only the CurrentRun layer (never Base/Dolphin.ini), so deleting these keys
    // restores whatever the user set manually (Base) or the 1.0 default — no override left stuck.
    Core::QueueHostJob([](Core::System&) {
      if (Config::GetLayer(Config::LayerType::CurrentRun)) {
        Config::DeleteKey(Config::LayerType::CurrentRun, Config::MAIN_OVERCLOCK);
        Config::DeleteKey(Config::LayerType::CurrentRun, Config::MAIN_OVERCLOCK_ENABLE);
        Config::DeleteKey(Config::LayerType::CurrentRun, Config::MAIN_VI_OVERCLOCK);
        Config::DeleteKey(Config::LayerType::CurrentRun, Config::MAIN_VI_OVERCLOCK_ENABLE);
      }
    }, false);
  }
}

// Build a chat-ready plaintext state block and place it on the general pasteboard. Sections:
// GAME / HARDWARE / LIVE PERF / SETTINGS (SETTINGS reuses _ICubeBuildPerfSettingsString).
+ (void)copyStateToClipboard {
  std::string b;
  b.reserve(2048);

  // --- GAME ---
  const std::string gid = SConfig::GetInstance().GetGameID();
  const std::string title = SConfig::GetInstance().GetTitleName();
  b += "=== GAME ===\n";
  b += "  title=" + (title.empty() ? std::string("(unknown)") : title) + "\n";
  b += "  game_id=" + (gid.empty() ? std::string("(no-gameid)") : gid) + "\n";

  // --- HARDWARE ---
  b += "=== HARDWARE ===\n";
  {
    char machine[256] = {0};
    size_t len = sizeof(machine);
    if (sysctlbyname("hw.machine", machine, &len, NULL, 0) != 0) {
      len = sizeof(machine);
      sysctlbyname("hw.model", machine, &len, NULL, 0);
    }
    b += "  device=" + std::string(machine[0] ? machine : "(unknown)") + "\n";
  }
  NSProcessInfo* pi = [NSProcessInfo processInfo];
  b += "  cpu_count=" + std::to_string((long)pi.processorCount) + "\n";
  {
    const double ramGB = (double)pi.physicalMemory / (1024.0 * 1024.0 * 1024.0);
    char buf[64];
    snprintf(buf, sizeof(buf), "%.2f GB", ramGB);
    b += "  physical_ram=" + std::string(buf) + "\n";
  }
  b += "  ios_version=" + std::string([[[UIDevice currentDevice] systemVersion] UTF8String]) + "\n";

  // --- LIVE PERF ---
  b += "=== LIVE PERF ===\n";
  {
    char buf[96];
    snprintf(buf, sizeof(buf), "%.2f", g_perf_metrics.GetFPS());        b += "  fps=" + std::string(buf) + "\n";
    snprintf(buf, sizeof(buf), "%.2f", g_perf_metrics.GetVPS());        b += "  vps=" + std::string(buf) + "\n";
    snprintf(buf, sizeof(buf), "%.1f%%", g_perf_metrics.GetSpeed() * 100.0);     b += "  speed=" + std::string(buf) + "\n";
    snprintf(buf, sizeof(buf), "%.1f%%", g_perf_metrics.GetMaxSpeed() * 100.0);  b += "  max_speed=" + std::string(buf) + "\n";
    snprintf(buf, sizeof(buf), "%.3f", g_perf_metrics.GetFrameDtAvgSeconds() * 1000.0); b += "  frame_dt_avg_ms=" + std::string(buf) + "\n";
    snprintf(buf, sizeof(buf), "%.3f", g_perf_metrics.GetFrameDtStdSeconds() * 1000.0); b += "  frame_dt_std_ms=" + std::string(buf) + "\n";

    // App resident memory: phys_footprint from TASK_VM_INFO.
    task_vm_info_data_t vmInfo = {};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &count) == KERN_SUCCESS) {
      const double footMB = (double)vmInfo.phys_footprint / (1024.0 * 1024.0);
      snprintf(buf, sizeof(buf), "%.1f MB", footMB);
      b += "  app_resident_mem=" + std::string(buf) + "\n";
    }
  }

  // --- SETTINGS ---
  b += "=== SETTINGS ===\n";
  b += _ICubeBuildPerfSettingsString("COPY");

  NSString* text = [NSString stringWithUTF8String:b.c_str()];
  dispatch_async(dispatch_get_main_queue(), ^{
    [UIPasteboard generalPasteboard].string = text;
  });
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

  _ICubeDumpPerfSettings("START");

  while (Core::IsRunning(Core::System::GetInstance())) {
    dispatch_semaphore_wait(stateSemaphore, DISPATCH_TIME_FOREVER);
  }

  _ICubeDumpPerfSettings("EXIT");

  Core::RemoveOnStateChangedCallback(&callbackHandle);

  dispatch_sync(dispatch_get_main_queue(), ^{
    Core::DeclareAsHostThread();
  });

  [self stopInputPump];
  // Tear down the adaptive clock timer + flag on game exit so it doesn't leak into the next launch
  // (the timer's state guard would otherwise keep a stale source around, and the VISkip rule must
  // not stay forced Off once emulation stops). Mirrors the OFF branch of setAdaptiveClockEnabled.
  if (_adaptiveClockTimer) {
    dispatch_source_cancel(_adaptiveClockTimer);
    _adaptiveClockTimer = nil;
  }
  PerformanceMetrics::SetAdaptiveClockActive(false);
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
