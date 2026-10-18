// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "DolphinCoreService.h"
#import "DOLConfigBridge.h"

#import "Core/Config/UISettings.h"
#import "Core/Config/MainSettings.h"
#import "Core/Config/GraphicsSettings.h"
#import "VideoCommon/VideoConfig.h" // Defines TriState enum (GraphicsSettings.h only forward-declares it)
#import "Core/Core.h"
#import "Core/DolphinAnalytics.h"
#import "Core/HW/GCPad.h"
#import "Core/HW/Wiimote.h"
#import "Core/System.h"
#ifdef USE_RETRO_ACHIEVEMENTS
#import "Core/AchievementManager.h"
#endif

#import "Common/FileUtil.h"
#import "Common/Logging/LogManager.h"
#import "Common/MsgHandler.h"

#import "InputCommon/ControllerInterface/ControllerInterface.h"
#import "InputCommon/InputConfig.h"

#import "UICommon/UICommon.h"

#import "Swift.h"
#import "EmulationCoordinator.h"
#import "FastmemManager.h"
#import "FoundationStringUtil.h"
#import "HostQueue.h"
#import "LocalizationUtil.h"
#import "MsgAlertManager.h"
#include "Common/Config/Config.h"

#import "PGOFlush.h"

#include <chrono>
#include <cstdlib>
#include <thread>
#include <unistd.h>

namespace {
/// How long termination waits for the core to stop before saving and exiting anyway.
constexpr auto kTerminateStopTimeout = std::chrono::seconds(3);
constexpr auto kTerminateStopPoll = std::chrono::milliseconds(5);

/// Runs before the C++ static destructors inside exit(), saves the config, and ends the process.
///
/// exit() is reached two ways, both while other threads still run: after willTerminate (the user
/// swiping the app away), and straight from UIKit's SIGTERM handler, which skips willTerminate and
/// can land mid-game. The static destructors that follow destroy Config's layers and mutexes; a
/// dirty Base layer saving itself from its destructor, or any thread still calling Config::Get,
/// then locks a destroyed mutex and throws "mutex lock failed: Invalid argument" (Sentry ICUBE-G
/// from willTerminate, ICUBE-FJ from SIGTERM). atexit handlers run in reverse registration order,
/// so registering this after UICommon::Init (and again in willTerminate) runs it before them.
void ExitWithoutStaticDestructors()
{
  ICubePGOFlush();
  Config::Save();
  _exit(0);
}

template <typename T>
static inline void SetBaseIfUnspecified(const Config::Info<T>& info, const T& value)
{
  // Seed the default ONLY when the key has never been written to the persisted Base layer.
  // The old check (active layer == Base) re-applied the default on EVERY launch and clobbered
  // the user's own UI changes, which also persist to Base — so any toggle the user flipped
  // (Immediate XFB, EFB-copy hacks, etc.) silently reset to this default on the next boot.
  // Checking Base-layer presence instead means: seed on genuine first-run, then respect whatever
  // the user sets. A higher-priority layer (game ini, current-run) still wins at read time.
  if (!Config::GetLayer(Config::LayerType::Base)->Exists(info.GetLocation()))
    Config::SetBase(info, value);
}
}

@implementation DolphinCoreService

+ (void)seedLaunchDefaultsWithFastmemAvailable:(BOOL)fastmemAvailable
{
  SetBaseIfUnspecified(Config::MAIN_USE_GAME_COVERS, true);

  const bool fastmem = fastmemAvailable;
  SetBaseIfUnspecified(Config::MAIN_FASTMEM, fastmem);
  SetBaseIfUnspecified(Config::MAIN_FASTMEM_ARENA, fastmem);
  SetBaseIfUnspecified(Config::MAIN_FAST_DISC_SPEED, true);
  SetBaseIfUnspecified(Config::MAIN_DSP_THREAD, true);
  // Dual-core: intentionally NOT set here. DEFAULT_CPU_THREAD (MainSettings.cpp) is the default,
  // ON since 2026-10-08, so no explicit seed is needed. An earlier
  // SetBaseIfUnspecified(false) was redundant AND made the dual-core toggle appear to force-reset
  // back to off — removing it lets the user's toggle persist normally. (Dual-core ON deadlocks
  // most games on the lean CachedInterpreter, so single-core is the right default — but that IS
  // the upstream default; let the user opt in if they want it.)
  // Speed-first video/CPU defaults
  SetBaseIfUnspecified(Config::GFX_HACK_SKIP_EFB_COPY_TO_RAM, true);
  SetBaseIfUnspecified(Config::GFX_HACK_SKIP_XFB_COPY_TO_RAM, true);
  SetBaseIfUnspecified(Config::GFX_HACK_IMMEDIATE_XFB, true);
  // Texture Cache Accuracy: Fast (0 samples) instead of the fork's Medium (128).
  SetBaseIfUnspecified(Config::GFX_SAFE_TEXTURE_CACHE_COLOR_SAMPLES, 0);
  // "Ignore Format Changes" off: emulate EFB format changes.
  SetBaseIfUnspecified(Config::GFX_HACK_EFB_EMULATE_FORMAT_CHANGES, true);
  // GFX_HACK_VI_SKIP: do NOT default ON on this rebaseline. VISkip lets the throttle DROP VI
  // interrupts (VideoInterface.cpp:987 early-returns before asserting IR_INT) whenever the core
  // lags >~20ms, as a catch-up. On HEAD's lean CachedInterpreter, CPU-heavy titles run
  // CHRONICALLY >20ms behind realtime, so VISkip pins PERMANENTLY on and starves the game of
  // vblank IRQs -> the main loop stalls. That is the "boot lockup": HUD freezes; pause/continue
  // fires ResetThrottle (CoreTiming.cpp:113) which clears the lag flag and unsticks it for a few
  // seconds until it drifts back past the 20ms threshold and re-wedges. Manual downclocking
  // (or the adaptive clock) fixes it by keeping the core inside the 20ms window. NOTE: the good
  // icube-testflight branch ALSO defaults this ON, but its faster custom CIR stays within the
  // window so it never wedges — so this is a lean-CIR-speed limitation, not a wrong default per se.
  SetBaseIfUnspecified(Config::GFX_HACK_VI_SKIP, false);
  // The legacy GFX_HACK_VI_SKIP bool above is NOT what the runtime reads.
  // CoreTimingManager::GetVISkip (CoreTiming.cpp:502-522) consults the tri-state
  // GFX_HACK_VI_SKIP_MODE, which "supersedes the legacy bool" (CoreTiming.cpp:507). Default it to
  // Auto: Auto is the FALLBACK catch-up for when the adaptive clock is OFF (it really helps on some
  // games). When the adaptive clock is ON (the default), the resolver forces VISkip Off at runtime
  // anyway (CoreTiming GetVISkip), so this default only takes effect in the adaptive-off case. The
  // bounded-Auto (4-skip cap) prevents hard-pinning, so it no longer permanently starves vblank
  // IRQs even on the lean CachedInterpreter.
  SetBaseIfUnspecified(Config::GFX_HACK_VI_SKIP_MODE, TriState::Auto);
  SetBaseIfUnspecified(Config::MAIN_ACCURATE_NANS, false);
  SetBaseIfUnspecified(Config::MAIN_SYNC_GPU, false);

  // Enforce safe shader compiler limits
  const int hw = (int)[[NSProcessInfo processInfo] processorCount];
  const int threads = std::max(1, std::min(2, hw - 1));
  SetBaseIfUnspecified(Config::GFX_SHADER_COMPILER_THREADS, threads);
  SetBaseIfUnspecified(Config::GFX_SHADER_PRECOMPILER_THREADS, threads);

  // Compile shaders up front (a one-time wait at boot) rather than on first
  // encounter during gameplay — far better than mid-game stutter on the jitless
  // CPU-bound path. Pairs with the on-disk Metal binary-archive (persists PSOs
  // across launches, so the boot wait shrinks on subsequent runs).
  SetBaseIfUnspecified(Config::GFX_WAIT_FOR_SHADERS_BEFORE_STARTING, true);

  // Prefer asynchronous present on iOS/tvOS by default (can be toggled in UI)
  SetBaseIfUnspecified(Config::GFX_ASYNC_PRESENT, true);
}

- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey,id>*)launchOptions {
  Core::DeclareAsHostThread();

  UICommon::SetUserDirectory(FoundationToCppString([UserFolderUtil getUserFolder]));
  UICommon::CreateDirectories();

  // Ensure Logger.ini is present in user folder
  NSURL* loggerIniPath = [[NSBundle mainBundle] URLForResource:@"Logger" withExtension:@"ini"];
  if (loggerIniPath) {
    std::string loggerIniCppPath = FoundationToCppString([loggerIniPath path]);
    File::Copy(loggerIniCppPath, File::GetUserPath(F_LOGGERCONFIG_IDX));
  }
  // The copy above never overwrites, so an install made under the old all-types-on default keeps
  // it. Move it to the quiet default before the rewrite below and LogManager's init read it.
  [ICubeLoggerIniMigration
      runAtLaunchWithIniPath:CppToFoundationString(File::GetUserPath(F_LOGGERCONFIG_IDX))];

  // Configure libcurl to use bundled CA bundle for SSL
  NSString* caPath = [[NSBundle mainBundle] pathForResource:@"cacert" ofType:@"pem"];
  if (caPath.length > 0) {
    setenv("CURL_CA_BUNDLE", [caPath UTF8String], 1);
  }

  // Apply UI overrides for console logging and verbosity before logging init
  BOOL logsEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"logger_console_enabled"];
  NSInteger verbosity = [[NSUserDefaults standardUserDefaults] integerForKey:@"logger_console_verbosity"];
  if (verbosity <= 0)
    verbosity = ICubeLoggerIniMigration.defaultVerbosity;
  {
    // [Options] keys only (a comment or another section holding the same text is not touched).
    // No window listener exists when LogManager initializes; the debug bench registers and enables
    // its own at runtime, so WriteToWindow stays off: a True here (an old default, or a saved bench
    // run) would make every enabled log line count as having a listener.
    [ICubeLoggerIniMigration
        applyLaunchOptionsToIniPath:CppToFoundationString(File::GetUserPath(F_LOGGERCONFIG_IDX))
                     consoleEnabled:logsEnabled
                          verbosity:verbosity];
  }

  UICommon::Init();

  // Console logging is the diagnostic mode: every log type, at the verbosity chosen above. The
  // file default keeps only the types worth a warning, so widen at runtime (not in the file, which
  // would stay widened once logging is turned off again).
  if (logsEnabled)
  {
    if (auto* logManager = Common::Log::LogManager::GetInstance())
    {
      for (int type = 0; type < static_cast<int>(Common::Log::LogType::NUMBER_OF_LOGS); ++type)
        logManager->SetEnable(static_cast<Common::Log::LogType>(type), true);
    }
  }

#if TARGET_OS_IOS
  // Sweep `.importing` files left by an import that iOS killed mid-copy (see DOLImportStaging).
  [DOLImportStaging removeStaleStagedImportsInFolder:[UserFolderUtil getSoftwareFolder]];
#endif

  // Sweep what an interrupted disc patch left behind (expanded ISOs, half-written copies).
  [DOLDiscPatchSweep sweep];
  // Single-play mod descriptors (Cache/ModRuns) outlive their game only if the app was killed mid-play.
  [DOLModDescriptorStore sweepRuns];

  [[MsgAlertManager shared] registerHandler];

  Common::RegisterStringTranslator([](const char* text) {
    return FoundationToCppString(DOLCoreLocalizedString(CToFoundationString(text)));
  });

  // Default the adaptive clock ON for never-set installs. The adaptive loop in
  // EmulationCoordinator.mm gates on this NSUserDefault (EmulationCoordinator.mm:360) which
  // otherwise defaults false, so the catch-up clock never engaged out of the box. registerDefaults
  // does NOT override a user's explicit choice — only the never-set case — so this is safe for both
  // fresh and existing installs.
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{@"adaptive_clock_enable": @YES}];

  // One-time repair of settings older builds saved by mistake (SettingsRepair.swift). Before the
  // seeds below, so a key it deletes is seeded again where the launch has a value for it.
  const bool fastmemAvailable = [FastmemManager shared].fastmemAvailable;
  [ICubeSettingsRepair runAtLaunchWithFastmemAvailable:fastmemAvailable];

  // Move the old CoreAudio effect chain from UserDefaults into Config. Needs the Base layer, which
  // UICommon::Init() creates above; run from AppDelegate it crashed every launch (ICUBE-FS).
  [DOLConfigBridge migrateLegacyAudioEffectDefaults];

  [DolphinCoreService seedLaunchDefaultsWithFastmemAvailable:fastmemAvailable];

  WindowSystemInfo wsi;
  wsi.type = WindowSystemType::iOS;

  UICommon::InitControllers(wsi);

  // This technically doesn't send any reports since we disabled analytics...
  // However, it initializes DolphinAnalytics, which we need to do before starting any Wii games.
  DolphinAnalytics::Instance().ReportDolphinStart("ios");

#ifdef USE_RETRO_ACHIEVEMENTS
  AchievementManager::GetInstance().Init(nullptr);
  // 2512: SetUpdateCallback became a HookableEvent; the hook must outlive registration.
  static Common::EventHook s_raUpdateHook =
      AchievementManager::GetInstance().update_event.Register([](const AchievementManager::UpdatedItems& items) {
    if (items.failed_login_code != 0) {
      [[NSNotificationCenter defaultCenter] postNotificationName:@"DOLRAFailedLogin" object:nil userInfo:@{ @"code": @(items.failed_login_code) }];
    }
  });
#endif

  // PGO (Profile-Guided Optimization) profile capture. Only active when the linked core was
  // built with DOL_PGO=generate (the weak __llvm_profile_* symbols resolved); a normal shipping
  // build returns 0 from ICubePGOAvailable() and this whole block is skipped. Point the
  // instrumented runtime at <Software>/pgo/icube-%m.profraw — the Software folder is what the
  // in-app web server already serves for download, and %m gives a cross-run merged profile.
  if (ICubePGOAvailable()) {
    NSString* pgoDir = [[UserFolderUtil getSoftwareFolder] stringByAppendingPathComponent:@"pgo"];
    NSError* dirErr = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:pgoDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&dirErr];
    if (dirErr) {
      NSLog(@"[PGO] failed to create profile dir %@: %@", pgoDir, dirErr);
    } else {
      NSString* pgoPath = [pgoDir stringByAppendingPathComponent:@"icube-%m.profraw"];
      ICubePGOSetPath([pgoPath UTF8String]);
      NSLog(@"[PGO] instrumented core detected; profiles -> %@", pgoPath);
    }
  }

  // After UICommon::Init created Config's layers, so this runs before their destructors when a
  // SIGTERM sends UIKit straight to exit() mid-game (ICUBE-FJ). See ExitWithoutStaticDestructors.
  std::atexit(ExitWithoutStaticDestructors);

  return YES;
}

// Pause and resume on resign/become-active belong to PauseArbiter (MainDisplaySceneDelegate): a second
// resume path here ran the game behind the pause menu or Settings after an app switch.
- (void)applicationWillResignActive:(UIApplication*)application {
  DOLHostQueueRunAsync(^{
    // Write out the configuration in case we don't get a chance later
    Config::Save();
  });
}

- (void)applicationDidEnterBackground:(UIApplication*)application {
  // Kill-safe PGO flush point. A long-running emulator force-killed by iOS while backgrounded
  // never runs willTerminate/atexit, so background is the reliable place to persist counters.
  // No-op on a non-instrumented (shipping) core.
  ICubePGOFlush();
}

- (void)applicationWillTerminate:(UIApplication*)application {
  // Flush PGO counters before anything else (no-op on a shipping build).
  ICubePGOFlush();

  // Save what must survive and stop the core, but tear nothing down. The process is about to die
  // and the system reclaims everything; what it does NOT do is stop our other threads first. The
  // old handler ran Core::Shutdown and UICommon::Shutdown here, which destroy Config's layers and
  // the LogManager while controller, library, web server and Swift timer threads still call
  // Config::Get and log. Those threads then locked destroyed mutexes and threw
  // "mutex lock failed: Invalid argument" (Sentry ICUBE-G: app in the background, main thread in
  // -[UIApplication _terminateWithStatus:]). The same race followed in exit(), whose C++ static
  // destructors run while those threads are alive; see ExitWithoutStaticDestructors.
  DOLHostQueueRunSync(^{
    auto& system = Core::System::GetInstance();

    if (Core::IsRunning(system)) {
      // Stopping flushes memory cards and the save-state worker. iOS allows willTerminate only a
      // few seconds, so never wait past kTerminateStopTimeout: a core that cannot stop in time
      // loses nothing it would not lose to the system's own kill.
      Core::Stop(system);
      const auto deadline = std::chrono::steady_clock::now() + kTerminateStopTimeout;
      while (Core::GetState(system) != Core::State::Uninitialized &&
             std::chrono::steady_clock::now() < deadline)
      {
        std::this_thread::sleep_for(kTerminateStopPoll);
      }
    }

    Config::Save();
  });

  // Every other service's willTerminate and Sentry's termination bookkeeping still run: they come
  // after this method returns. Registered last, this handler is the first to run inside exit(),
  // so the process ends before any C++ static destructor can race a live thread. The next launch
  // is a cold start either way.
  std::atexit(ExitWithoutStaticDestructors);
}

@end
