// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "DolphinCoreService.h"

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
#import "Common/MsgHandler.h"

#import "InputCommon/ControllerInterface/ControllerInterface.h"
#import "InputCommon/InputConfig.h"

#import "UICommon/UICommon.h"

#import "iCube-Swift.h"
#import "EmulationCoordinator.h"
#import "FastmemManager.h"
#import "FoundationStringUtil.h"
#import "HostQueue.h"
#import "LocalizationUtil.h"
#import "MsgAlertManager.h"
#include "Common/Config/Config.h"

#import "PGOFlush.h"

namespace {
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

  // Configure libcurl to use bundled CA bundle for SSL
  NSString* caPath = [[NSBundle mainBundle] pathForResource:@"cacert" ofType:@"pem"];
  if (caPath.length > 0) {
    setenv("CURL_CA_BUNDLE", [caPath UTF8String], 1);
  }

  // Apply UI overrides for console logging and verbosity before logging init
  BOOL logsEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"logger_console_enabled"];
  NSInteger verbosity = [[NSUserDefaults standardUserDefaults] integerForKey:@"logger_console_verbosity"];
  if (verbosity <= 0) verbosity = 4;
  {
    std::string iniPath = File::GetUserPath(F_LOGGERCONFIG_IDX);
    std::string content;
    if (File::Exists(iniPath)) {
      FILE* fp = fopen(iniPath.c_str(), "rb");
      if (fp) {
        fseek(fp, 0, SEEK_END);
        long sz = ftell(fp);
        fseek(fp, 0, SEEK_SET);
        if (sz > 0) {
          content.resize((size_t)sz);
          fread(content.data(), 1, (size_t)sz, fp);
        }
        fclose(fp);
      }
    }
    if (!content.empty()) {
      auto replaceLine = [&](const std::string& key, const std::string& value) {
        const std::string prefix = key + " = ";
        size_t pos = content.find(prefix);
        if (pos != std::string::npos) {
          size_t end = content.find('\n', pos);
          if (end == std::string::npos) end = content.size();
          content.replace(pos + prefix.size(), end - (pos + prefix.size()), value);
        }
      };
      replaceLine("WriteToConsole", logsEnabled ? "True" : "False");
      replaceLine("Verbosity", std::to_string((int)verbosity));
      FILE* out = fopen(iniPath.c_str(), "wb");
      if (out) {
        fwrite(content.data(), 1, content.size(), out);
        fclose(out);
      }
    }
  }

  UICommon::Init();

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

  SetBaseIfUnspecified(Config::MAIN_USE_GAME_COVERS, true);

  const bool fastmemAvailable = [FastmemManager shared].fastmemAvailable;
  SetBaseIfUnspecified(Config::MAIN_FASTMEM, fastmemAvailable);
  SetBaseIfUnspecified(Config::MAIN_FASTMEM_ARENA, fastmemAvailable);
  SetBaseIfUnspecified(Config::MAIN_FAST_DISC_SPEED, true);
  SetBaseIfUnspecified(Config::MAIN_DSP_THREAD, true);
  // Dual-core: intentionally NOT set here. iOS already defaults to single-core via upstream
  // DEFAULT_CPU_THREAD=false (MainSettings.cpp), so no explicit default is needed. An earlier
  // SetBaseIfUnspecified(false) was redundant AND made the dual-core toggle appear to force-reset
  // back to off — removing it lets the user's toggle persist normally. (Dual-core ON deadlocks
  // most games on the lean CachedInterpreter, so single-core is the right default — but that IS
  // the upstream default; let the user opt in if they want it.)
  // Speed-first video/CPU defaults
  SetBaseIfUnspecified(Config::GFX_HACK_SKIP_EFB_COPY_TO_RAM, true);
  SetBaseIfUnspecified(Config::GFX_HACK_SKIP_XFB_COPY_TO_RAM, true);
  SetBaseIfUnspecified(Config::GFX_HACK_IMMEDIATE_XFB, true);
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
  // The legacy GFX_HACK_VI_SKIP bool above is NOT what the runtime reads. CoreTimingManager::GetVISkip
  // (CoreTiming.cpp:502-522) consults the tri-state GFX_HACK_VI_SKIP_MODE, which "supersedes the legacy
  // bool" (CoreTiming.cpp:507). Default it to Auto: Auto is the FALLBACK catch-up for when the adaptive
  // clock is OFF (it really helps on some games). When the adaptive clock is ON (the default), the
  // resolver forces VISkip Off at runtime anyway (CoreTiming GetVISkip), so this default only takes
  // effect in the adaptive-off case. The bounded-Auto (4-skip cap) prevents hard-pinning, so it no
  // longer permanently starves vblank IRQs even on the lean CachedInterpreter.
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

  WindowSystemInfo wsi;
  wsi.type = WindowSystemType::iOS;

  UICommon::InitControllers(wsi);

  // This technically doesn't send any reports since we disabled analytics...
  // However, it initializes DolphinAnalytics, which we need to do before starting any Wii games.
  DolphinAnalytics::Instance().ReportDolphinStart("ios");

#ifdef USE_RETRO_ACHIEVEMENTS
  AchievementManager::GetInstance().Init(nullptr);
  AchievementManager::GetInstance().SetUpdateCallback([](const AchievementManager::UpdatedItems& items) {
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

  return YES;
}

- (void)applicationDidBecomeActive:(UIApplication*)application {
  DOLHostQueueRunSync(^{
    auto& system = Core::System::GetInstance();

    if (Core::IsRunning(system) && ![EmulationCoordinator shared].userRequestedPause) {
      Core::SetState(system, Core::State::Running);
    }
  });
}

- (void)applicationWillResignActive:(UIApplication*)application {
  DOLHostQueueRunSync(^{
    auto& system = Core::System::GetInstance();

    if (Core::IsRunning(system) && ![EmulationCoordinator shared].userRequestedPause) {
      Core::SetState(system, Core::State::Paused);
    }

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
  // Flush PGO counters before tearing down the core (no-op on a shipping build).
  ICubePGOFlush();

  DOLHostQueueRunSync(^{
    auto& system = Core::System::GetInstance();

    if (Core::IsRunning(system)) {
      Core::Stop(Core::System::GetInstance());

      // Spin while Core stops
      while (Core::GetState(Core::System::GetInstance()) != Core::State::Uninitialized) {}
    }

    Config::Save();

#ifdef USE_RETRO_ACHIEVEMENTS
    AchievementManager::GetInstance().Shutdown();
#endif

    Core::Shutdown(system);

    UICommon::ShutdownControllers();
    UICommon::Shutdown();
  });
}

@end
