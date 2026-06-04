// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "EmulationCoordinator.h"

#include <cmath>
#include <variant>
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
#import "Core/HW/EXI/EXI_DeviceIPL.h"
#import "DiscIO/Enums.h"
#import "DiscIO/Volume.h"
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

// iCube: CIR hot-block profiler report (defined in CachedInterpreter.cpp). Declared locally instead
// of including CachedInterpreter.h, which pulls rangeset/* not on this target's include path.
namespace CIRProfiler
{
std::string BuildHotBlocksReport(u32 top_n);
void Reset();
}  // namespace CIRProfiler

#import "EmulationBootParameter.h"
#import "FastmemManager.h"
#import "HostNotifications.h"
#import "HostQueue.h"
#import "MainSceneCoordinator.h"
#import "DOLConfigBridge.h"
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
  ACPhase_Search,      // find the cliff: predictive jump (max_speed estimate) or coarse descent
  ACPhase_FineTune,    // refine onto the cliff via the max_speed predictor (post predictive-jump)
  ACPhase_Settle,      // observe the settle clock over a longer window before committing
  ACPhase_Hold         // converged at f*; light monitoring, re-enter Search on degradation
};

// Which lever an in-flight Hold-phase headroom up-probe raised (for revert/attribution).
enum { AC_LEVER_NONE = 0, AC_LEVER_CPU, AC_LEVER_VI };

// Tunables. The CONTROL LAW (cliff-find: stop descending at the first/highest clock that meets the
// f* criterion) is the thing under test; these constants are reasoned starting points and still
// need on-device tuning against real CPU-bound titles. (See research synthesis §#1: validate with a
// manual underclock sweep + PerfSnapshot log first.)
static const int   ACTickMs        = 500;    // timer cadence (ms)
static const int   ACSearchStepTicks = 3;    // ~1.5s between sweep steps (3 * 500ms)
static const int   ACSettleTicks   = 14;     // ~7s settle/observation window
static const int   ACVerifyTicks   = 5;      // ~2.5s verify of a seeded per-game clock
static const int   ACHoldTicks     = 6;      // ~3s between hold-phase health checks
static const float ACSweepStep     = 0.10f;  // CPU-clock decrement per coarse search step
static const float ACVIStep        = 0.10f;  // VI-clock decrement (secondary lever, CPU floored)
// Predictive-seed convergence: max_speed (=emulated/work) estimates the cliff directly — at clock c
// with measured max_speed m, the CPU-bound cliff f* ≈ c·m. So instead of stepping down 0.10 at a time
// from 1.0 (~7.5s of degraded play, landing on a coarse grid that can't hit e.g. 0.47), JUMP to the
// estimate (gated on bound==CpuBound; meaningless when GPU-bound/Unknown -> coarse fallback) and then
// REFINE by re-estimating from the new clock (Newton-style; converges in ~2-3 windows and lands on
// the fine grid). Idle loops make c·m UNDER-estimate (host work is sublinear in clock) — the safe
// direction: land below, refine up. ACFineStep is the landing grid; ACFineTicks the per-refine window.
static const float ACFineStep      = 0.025f; // fine grid the predictor rounds onto
static const int   ACFineTicks     = 8;      // ~4s window per fine-refine evaluation
// GPU-bound guard. On single-core iOS (CPUThread forced off — dual-core deadlocks the lean CIR),
// GPU work runs INLINE on the CPU timeline, so a GPU-bound title depresses max_speed and ClassifyBound
// mislabels it CpuBound. The predictive jump would then ratchet the CPU clock to the floor for ZERO
// fps gain (slow-motion). Guard like AutoIRController's probe but on the CPU lever: if lowering the
// clock from the pre-jump baseline does NOT raise achieved speed by at least this much, the CPU lever
// isn't the bottleneck (it's a GPU/video wall) — restore the baseline clock and PARK the lever.
static const float ACProbeMinGain  = 0.05f;  // min speed gain from underclocking to call it CPU-bound
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
// --- Headroom recovery (fix for the one-way-ratchet convergence bug). ---
// The controller used to only ever DESCEND, so a transient-heavy moment (boot, scene transition,
// thermal) walked the clock down and it could NEVER climb back when the scene lightened — leaving
// the game underclocked (slow-motion / half field-rate) with huge idle headroom (observed: Max 198%
// on a static Colosseum scene). max_speed (= emulated/work_time, throttle-sleep removed) is the
// direct cliff sensor: ~1.0 at f*, >1 below it. In Hold we probe UP one step when max_speed shows
// real headroom, reverting if the step overshoots f*. The threshold MUST exceed 1 + sweepStep so a
// clock sitting one step below f* (max_speed ≈ 1.10 with a 0.10 step) does NOT re-probe — that
// dead-band is what keeps steady-state at the cliff from oscillating (the reason up-probing was
// originally removed). Bias high: under-recovery is invisible, oscillation is visible stutter.
// Up-probe gate is STEP-RELATIVE, not a fixed headroom number. One step below the cliff, max_speed =
// f*/(f*-step), which ranges ~1.11 (f*->1.0) to >1.25 (low f*) — so a fixed 1.15 oscillates on
// low-f* titles (e.g. F-Zero f*~0.47: settles 0.40, up-probes 0.50, fails, reverts, repeats) and
// under-recovers on high-f* ones. Instead estimate the cliff f_hat = clock * max_speed (CPU-bound,
// ~linear work-vs-clock) and only probe a lever UP if f_hat sits this margin ABOVE where the probe
// would LAND. If the only upward neighbor is the clock Search already rejected, f_hat won't clear it
// and we stay put (converged) instead of oscillating.
static const float ACUpMargin           = 0.04f;  // estimated cliff must exceed the post-probe clock by this
static const int   ACUpFailCooldownEvals = 4;     // Hold evals to wait after an up-probe overshoot

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
  // meeting the criterion — that first match is, by construction, the highest match. SPEED alone
  // can't tell f* from a lower clock (both read ≈100% because the throttle caps speed), which is
  // exactly why the prior loop (which kept descending while "stable") sailed past f* to the floor.
  // v3 stops at first match. v3.1 adds the missing recovery direction: max_speed (throttle-sleep
  // removed) DOES distinguish them — ≈1.0 at f*, >1 below it — so Hold uses it to climb back up when
  // the scene lightens (the prior strict one-way descent could never recover; see ACUpMargin).
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
  // Headroom up-recovery (Hold phase) — see ACUpMargin. Fixes the one-way ratchet.
  int   _acUpProbeLever;       // lever raised by the in-flight up-probe (AC_LEVER_*), for revert
  int   _acUpCooldown;         // Hold evals remaining before another up-probe is allowed
  BOOL  _acViRecoveryStalled;  // a VI up-probe overshot -> stop retrying VI, let CPU climb instead
  float _acPreProbeCPU;        // CPU clock before the in-flight up-probe (revert target)
  float _acPreProbeVI;         // VI clock before the in-flight up-probe (revert target)
  // Predictive-seed (FineTune) state + GPU-bound guard.
  BOOL  _acFineConfirmed;      // FineTune has confirmed at least one keeps-up clock this cycle
  float _acProbeBaseCPU;       // clock just before the predictive jump (restore target if not CPU-bound)
  double _acProbeBaseSpeed;    // achieved speed just before the jump (CPU-bound = lowering raised it)
  BOOL  _acCpuLeverParked;     // GPU/video wall: CPU lever gives no gain -> stop fighting it with clock

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
  // iCube: pre-detect the "boot to GameCube menu but no BIOS/IPL installed" dead launch.
  // A GameCube disc boot is silently re-routed through the GC IPL by BootManager::BootCore exactly
  // when (!Wii && !MAIN_SKIP_IPL && Disc); if no IPL dump is present that boot fails with a generic
  // "Cannot find the GC IPL" panic and the game just never starts. Catch it here at the single launch
  // chokepoint (covers iOS EmulationViewController AND the tvOS TVLibrary/TVEmulation bridges) and
  // offer a one-tap "Boot Game Directly" (enable skip-IPL) + a Learn More link instead.
  //
  // Cheap guards first so a normal launch pays nothing: only when skip-IPL is OFF and there is no IPL
  // dump do we generate the (disc-reading) boot parameters to confirm this is actually a GC disc boot.
  if (!Config::Get(Config::MAIN_SKIP_IPL) && !ExpansionInterface::CEXIIPL::HasIPLDump()) {
    std::unique_ptr<BootParameters> boot = [bootParameter generateDolphinBootParameter];
    bool wouldBootGCIPL = false;
    if (boot) {
      if (std::holds_alternative<BootParameters::Disc>(boot->parameters)) {
        // Only GameCube discs route through the GC IPL; Wii discs ignore it. Mirror the IsWii() guard
        // in BootManager::BootCore using the volume platform (the system isn't booted yet).
        const auto& disc = std::get<BootParameters::Disc>(boot->parameters);
        if (disc.volume && disc.volume->GetVolumeType() == DiscIO::Platform::GameCubeDisc) {
          wouldBootGCIPL = true;
        }
      } else if (std::holds_alternative<BootParameters::IPL>(boot->parameters)) {
        // Direct "Load GameCube Menu" action (EmulationBootTypeGCIPL) — always an IPL boot.
        wouldBootGCIPL = true;
      }
    }
    if (wouldBootGCIPL) {
      [self presentMissingGCIPLAlertForBootParameter:bootParameter];
      return;
    }
  }

  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    [self emulationLoopWithBootParameter:bootParameter];
  });
}

// iCube: alert shown when a launch would boot through the GameCube menu/IPL but no IPL/BIOS dump is
// installed. "Boot Game Directly" flips skip-IPL on and retries the launch (so the game boots without
// the menu); "Learn More" opens the GameCube BIOS help page; "Cancel" abandons the launch. Presented
// via the MainSceneCoordinator scene so it works on both iOS and tvOS (same pattern as MsgAlertManager).
- (void)presentMissingGCIPLAlertForBootParameter:(EmulationBootParameter*)bootParameter {
  dispatch_async(dispatch_get_main_queue(), ^{
    UIWindowScene* mainScene = [MainSceneCoordinator shared].mainScene;
    if (mainScene == nil) {
      // No scene to present on: fall back to booting directly so the user isn't left with a dead
      // launch (skip-IPL on, retry). This mirrors the "Boot Game Directly" action.
      [DOLConfigBridge setMainSkipIPL:YES];
      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self emulationLoopWithBootParameter:bootParameter];
      });
      return;
    }

    UIWindow* window = [[UIWindow alloc] initWithWindowScene:mainScene];
    window.frame = UIScreen.mainScreen.bounds;
    window.rootViewController = [[UIViewController alloc] init];
    UIWindow* topWindow = mainScene.windows.lastObject;
    window.windowLevel = topWindow.windowLevel + 1;

    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:DOLCoreLocalizedString(@"GameCube BIOS not found")
                         message:DOLCoreLocalizedString(@"This game is set to boot to the GameCube menu, but the GameCube BIOS (IPL) isn't installed, so it can't start. You can boot the game directly without the menu, or install a GameCube BIOS dump. Learn More explains how.")
                  preferredStyle:UIAlertControllerStyleAlert];

    void (^finish)(void) = ^{ [window setHidden:YES]; };

    [alert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"Boot Game Directly")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction* action) {
      // Enable skip-IPL (boot straight into the game, no menu) and retry the launch.
      [DOLConfigBridge setMainSkipIPL:YES];
      finish();
      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self emulationLoopWithBootParameter:bootParameter];
      });
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"Learn More")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction* action) {
      finish();
      NSURL* url = [NSURL URLWithString:@"https://icube-emu.com/help/gamecube-bios"];
      [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction* action) {
      finish();
    }]];

    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
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

  // Start BOTH levers at native (1.0), NOT the current Config value. Two reasons: (1) a fresh sweep
  // finds f* by descending from the top, so it must begin at 1.0; (2) when Auto engages it must take
  // OWNERSHIP of CPU *and* VI, not inherit wherever the manual sliders were left — otherwise a stale
  // manual VI overclock bleeds through (Auto looked like it only moved the CPU). VI used to init from
  // Config::Get here while CPU started at 1.0; that asymmetry was the bug. The per-game seed below
  // overrides these if we've already converged for this title.
  _acCPU = 1.0f;
  _acVI = 1.0f;
  _acStableCPU = 1.0f;
  _acLastApplied = -1.f;
  _acLastAppliedVI = -1.f;
  _acLastPersisted = -1.f;
  _acCpuYielded = NO;
  _acViYielded = NO;
  _acVerifyProbedUp = NO;
  _acUpProbeLever = AC_LEVER_NONE;
  _acUpCooldown = 0;
  _acViRecoveryStalled = NO;
  _acFineConfirmed = NO;
  _acCpuLeverParked = NO;
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
          // CLIFF-FIND. If 1.0 already keeps up, settle there (easy/GPU-bound case). Otherwise, when
          // we have a valid CPU-bound classification, PREDICTIVELY JUMP to the max_speed cliff estimate
          // (f* ≈ clock·max_speed) and hand off to FineTune — far faster and finer than the coarse
          // descent. Fall back to one-coarse-step descent when the estimate isn't usable (GPU-bound /
          // Unknown / no headroom signal). The coarse descent still STOPS at the first match (that
          // first match is the highest = f*); we never keep descending while meeting (the MINIMIZE bug).
          if (self->_acPhaseTicks < ACSearchStepTicks) break;

          const float applied_now = MIN(self->_acCPU, ceiling);
          if (meetsFStar) {
            // First (=highest) clock that keeps up with honest delivery. This is f*. Settle here.
            self->_acStableCPU = self->_acCPU;
            self->_acPhase = ACPhase_Settle;
            resetWindow();
            break;
          }

          // Doesn't keep up here. Prefer a predictive jump (one window vs many coarse steps, lands on
          // the fine grid). Only when positively CpuBound: c·max_speed is meaningful only then.
          if (bound == PerformanceMetrics::Bound::CpuBound && !self->_acCpuYielded &&
              maxSpeed > 0.05 && maxSpeed < 0.999) {
            const float fhat = applied_now * (float)maxSpeed;            // estimated cliff
            float target = floorf(fhat / ACFineStep) * ACFineStep;       // fine grid, biased down
            target = MAX(ACCpuFloor, MIN(1.0f, target));
            if (target < applied_now - 0.001f) {
              // Record the pre-jump baseline so FineTune can tell CPU-bound (lowering raised speed)
              // from a GPU wall misclassified as CpuBound on single-core (lowering changed nothing).
              self->_acProbeBaseCPU = applied_now;
              self->_acProbeBaseSpeed = speed;
              self->_acFineConfirmed = NO;
              applyCPU(target);
              self->_acStableCPU = self->_acCPU;  // best estimate so far (refined in FineTune)
              self->_acPhase = ACPhase_FineTune;
              resetWindow();
              break;
            }
          }

          // Coarse fallback: descend one step toward the feasible region (or floor + best-effort).
          if (applied_now - sweepStep >= ACCpuFloor - 0.001f) {
            applyCPU(self->_acCPU - sweepStep);
            resetWindow();
          } else {
            applyCPU(ACCpuFloor);
            self->_acStableCPU = self->_acCPU;
            self->_acPhase = ACPhase_Settle;
            resetWindow();
          }
          break;
        }

        case ACPhase_FineTune: {
          // We jumped to the max_speed cliff estimate. Refine onto the cliff by RE-estimating from the
          // new clock (Newton-style): keep up here -> confirmed-good, re-predict and jump UP if there's
          // room, else settle. Climbing-up-stop-at-first-failure finds the ceiling correctly (unlike
          // descending, where every lower clock also "meets" — the MINIMIZE trap). Converges in ~2-3
          // windows. Two guards: a GPU wall (lowering didn't help -> not CPU-bound) and overshoot
          // recovery by RE-PREDICTING from the overshot clock (there max_speed≈speed, so c·m≈cliff).
          const float applied_ft = MIN(self->_acCPU, ceiling);  // capped, consistent with Search
          if (self->_acPhaseTicks < ACFineTicks) break;
          if (meetsFStar) {
            self->_acFineConfirmed = YES;
            self->_acStableCPU = self->_acCPU;  // confirmed good
            const float fhat = applied_ft * (float)maxSpeed;
            float target = floorf(fhat / ACFineStep) * ACFineStep;
            target = MAX(ACCpuFloor, MIN(1.0f, target));
            if (target > self->_acCPU + 0.001f && !self->_acCpuYielded) {
              applyCPU(target);                 // estimate says room above: jump up and re-verify
              resetWindow();
              break;
            }
            // Estimate puts the cliff at (or below) the current clock: we're on it. Settle.
            self->_acStableCPU = self->_acCPU;
            self->_acPhase = ACPhase_Hold;
            persistConverged();
            resetWindow();
            break;
          }
          // Not keeping up at this clock.
          if (self->_acFineConfirmed && self->_acStableCPU < self->_acCPU - 0.001f) {
            // We had climbed up and just overshot the cliff: settle at the last confirmed-good.
            applyCPU(self->_acStableCPU);
            self->_acPhase = ACPhase_Hold;
            persistConverged();
            resetWindow();
            break;
          }
          // Never confirmed a keeps-up clock. GPU GUARD: if dropping from the baseline didn't raise
          // achieved speed, the CPU lever isn't the bottleneck (GPU/video wall misread as CpuBound on
          // single-core) — restore the baseline clock and PARK the lever so we don't ratchet to slow-mo.
          if ((speed - self->_acProbeBaseSpeed) < ACProbeMinGain) {
            applyCPU(self->_acProbeBaseCPU);
            self->_acCpuLeverParked = YES;
            self->_acPhase = ACPhase_Hold;
            persistConverged();
            resetWindow();
            break;
          }
          // CPU-bound but the seed was still a touch high: RE-PREDICT downward from here (fast — one
          // window — vs slow fine-stepping). At an overshoot max_speed≈speed, so c·max_speed≈cliff.
          float target = floorf(applied_ft * (float)maxSpeed / ACFineStep) * ACFineStep;
          target = MAX(ACCpuFloor, MIN(1.0f, target));
          if (target < applied_ft - 0.001f) {
            applyCPU(target);
            resetWindow();
            break;
          }
          // Can't predict lower (estimate not below current): floor it and settle, best-effort.
          applyCPU(ACCpuFloor);
          self->_acStableCPU = self->_acCPU;
          self->_acPhase = ACPhase_Hold;
          persistConverged();
          resetWindow();
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
          // Converged at f*. Light monitoring in BOTH directions.
          //  - Lost f* (scene heavier / thermal): the cliff moved DOWN -> descend to re-find it.
          //  - Still at f* but max_speed shows real headroom: the cliff moved UP (scene lightened /
          //    cooled) -> climb back. This recovery direction is the fix for the one-way ratchet;
          //    without it a transient walked the clock down for good (see ACUpMargin).
          if (self->_acPhaseTicks < ACHoldTicks) break;
          if (!meetsFStar) {
            if (self->_acUpProbeLever != AC_LEVER_NONE) {
              // Our headroom up-probe overshot f* (host can't keep up at the raised clock). Revert
              // the probed lever and back off with a cooldown before retrying — a transient could
              // also cause this. Stay in HOLD: this was our own probe, not a real scene change.
              if (self->_acUpProbeLever == AC_LEVER_VI) {
                applyVI(self->_acPreProbeVI);
                self->_acViRecoveryStalled = YES;  // stop retrying VI; let CPU climb instead.
              } else {
                applyCPU(self->_acPreProbeCPU);
              }
              self->_acUpProbeLever = AC_LEVER_NONE;
              self->_acUpCooldown = ACUpFailCooldownEvals;
            } else if (self->_acCpuLeverParked) {
              // GPU/video wall (FineTune's guard parked the CPU lever): underclocking won't help, so
              // do NOT re-descend / re-Search — that would just ratchet to slow-mo. Hold at the
              // baseline clock and keep monitoring; the meetsFStar branch re-arms if the scene lifts.
              persistConverged();
            } else if (self->_acCPU - sweepStep < ACCpuFloor + 0.001f &&
                       self->_acVI - ACVIStep >= ACViFloor &&
                       bound == PerformanceMetrics::Bound::CpuBound) {
              // CPU already floored AND positively CPU-bound: shed VI for its distinct refresh-rate
              // effect (step #5). Require CpuBound, not "!= GpuBound", so Unknown never triggers it.
              applyVI(self->_acVI - ACVIStep);
              self->_acVerifyProbedUp = NO;
              self->_acPhase = ACPhase_Search;
            } else if (self->_acCPU - sweepStep >= ACCpuFloor - 0.001f) {
              // f* dropped: descend one step and re-find by sweeping down from here.
              applyCPU(self->_acCPU - sweepStep);
              self->_acViRecoveryStalled = NO;   // fresh conditions: re-arm VI recovery.
              self->_acVerifyProbedUp = NO;
              self->_acPhase = ACPhase_Search;
            }
          } else {
            // At full speed. First: if a prior up-probe is in flight, it HELD -> keep the climb.
            if (self->_acUpProbeLever != AC_LEVER_NONE) {
              self->_acStableCPU = self->_acCPU;
              self->_acUpProbeLever = AC_LEVER_NONE;
            }
            // Scene is keeping up again: re-arm the CPU lever if a GPU wall had parked it.
            self->_acCpuLeverParked = NO;
            if (self->_acUpCooldown > 0) {
              self->_acUpCooldown--;
              // NOTE: do NOT clear _acViRecoveryStalled here. Clearing it the instant the cooldown
              // expired (one eval before the probe branch below could ever observe it) made the
              // "VI overshot -> stop retrying VI, let CPU climb instead" hand-off dead code — VI would
              // jitter forever instead of yielding to CPU. The stall is re-armed only on a genuine
              // re-search (the descend path), which is the correct LIFO behavior.
              persistConverged();
            } else if (cool && !newUnderrun) {
              // Headroom recovery toward f*, gated by the step-relative cliff estimate (see ACUpMargin)
              // so we never probe into the clock Search already rejected. Restore LIFO: the VI lever is
              // shed last (only at CPU floor) and its underclock is the visible slow-motion, so raise
              // it first; once VI is back at native (or stalled) climb CPU. One lever per step.
              const double fhatCPU = (double)self->_acCPU * maxSpeed;  // estimated CPU cliff (VI fixed)
              const double fhatVI  = (double)self->_acVI * maxSpeed;   // proportional headroom for VI work
              self->_acPreProbeCPU = self->_acCPU;
              self->_acPreProbeVI = self->_acVI;
              if (self->_acVI < 1.0f - 0.001f && !self->_acViYielded && !self->_acViRecoveryStalled &&
                  fhatVI >= (double)(self->_acVI + ACVIStep) * (1.0 + ACUpMargin)) {
                applyVI(self->_acVI + ACVIStep);
                self->_acUpProbeLever = AC_LEVER_VI;
                self->_acUpCooldown = 1;  // observe one eval before the next climb
              } else if (self->_acCPU < 1.0f - 0.001f && !self->_acCpuYielded &&
                         fhatCPU >= (double)(self->_acCPU + sweepStep) * (1.0 + ACUpMargin)) {
                applyCPU(self->_acCPU + sweepStep);
                self->_acUpProbeLever = AC_LEVER_CPU;
                self->_acUpCooldown = 1;
              } else {
                persistConverged();  // at the cliff (no estimated room beyond a step) or yielded.
              }
            } else {
              // At/just below f* with no spare headroom (dead-band): the converged steady state.
              persistConverged();
            }
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

  // --- CIR HOT BLOCKS --- (iCube hot-block profiler; only populated when MAIN_CIR_PROFILE is on)
  {
    const std::string cir = CIRProfiler::BuildHotBlocksReport(40);
    b += "=== CIR HOT BLOCKS ===\n";
    b += cir;
    // Also emit the hot-block report to the log on BOTH platforms (Copy State on iOS only puts the
    // full dump on the clipboard; this guarantees the profiler output is grep-able in the device log).
    NSLog(@"[iCube CIR hotblocks]\n%s", cir.c_str());
  }

  NSString* text = [NSString stringWithUTF8String:b.c_str()];
#if TARGET_OS_TV
  // tvOS has no UIPasteboard; the perf-state dump still goes to the log/OSD.
  NSLog(@"[iCube perf-state]\n%@", text);
#else
  dispatch_async(dispatch_get_main_queue(), ^{
    [UIPasteboard generalPasteboard].string = text;
  });
#endif
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
          // Default ON: attempt LuckTXM + full JIT. MemoryUtil_iOS_LuckTXM issues the
          // StikDebug broker handshake (brk #0x69 -> #0xf00d) to authorize TXM, then
          // vm_remap. Reaching here already implies a broker is attached and we are
          // NOT under Xcode (JitManager leaves acquiredJit false in the Xcode case),
          // i.e. StikDebug is attached — so the handshake is expected to be answered.
          // If the attached broker has no compatible script, the brk falls through the
          // SIGTRAP net / auth flag, IsTXMAvailable() is false, and we drop to
          // CachedInterpreter. DOL_JIT_TXM=0 forces that interpreter fallback (e.g. for
          // debugging the no-JIT path without detaching StikDebug).
          NSDictionary* env = [[NSProcessInfo processInfo] environment];
          BOOL enableTXM = ![env[@"DOL_JIT_TXM"] isEqualToString:@"0"];

          if (enableTXM)
          {
            Common::SetJitType(Common::JitType::LuckTXM);
            Common::AllocateExecutableMemoryRegion();

            if (!Common::IsTXMAvailable())
            {
              Common::SetJitType(Common::JitType::LuckNoTXM);
              txmInterpreterFallback = true;
            }
          }
          else
          {
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
      // iCube: bridge the hot-block profiler toggle from an NSUserDefault into the Dolphin config
      // BEFORE boot, so CachedInterpreter::Init() reads MAIN_CIR_PROFILE for this run. Default OFF
      // (absent key => false). Set `defaults write <bundleid> icube.cirProfile -bool YES` (or via the
      // debug API) and reboot the game to profile; grab the report from Copy State.
      {
        const bool cirProfile =
            [[NSUserDefaults standardUserDefaults] boolForKey:@"icube.cirProfile"];
        Config::SetCurrent(Config::MAIN_CIR_PROFILE, cirProfile);
      }
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
