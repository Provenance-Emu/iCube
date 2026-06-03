// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "DolphinCoreService.h"

#import "Core/Config/UISettings.h"
#import "Core/Config/MainSettings.h"
#import "Core/Config/GraphicsSettings.h"
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

namespace {
template <typename T>
static inline void SetBaseIfUnspecified(const Config::Info<T>& info, const T& value)
{
  if (Config::GetActiveLayerForConfig(info) == Config::LayerType::Base)
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

  SetBaseIfUnspecified(Config::MAIN_USE_GAME_COVERS, true);

  const bool fastmemAvailable = [FastmemManager shared].fastmemAvailable;
  SetBaseIfUnspecified(Config::MAIN_FASTMEM, fastmemAvailable);
  SetBaseIfUnspecified(Config::MAIN_FASTMEM_ARENA, fastmemAvailable);
  SetBaseIfUnspecified(Config::MAIN_FAST_DISC_SPEED, true);
  SetBaseIfUnspecified(Config::MAIN_DSP_THREAD, true);
  // Dual-core (separate CPU/GPU threads): default OFF (single-core) on iOS.
  // REVERTED from default-on (commit 35714c8c4b): on device, defaulting dual-core ON made MOST
  // games hard-HANG a few seconds into boot — all perf-HUD counters freeze, Stop/close won't
  // complete, and pause+continue unsticks emulation only briefly. That's the signature of a
  // CPU<->GPU FIFO-fence/EFB-readback DEADLOCK on this lean CachedInterpreter under dual-core,
  // not the single-core boot-stall the static analysis predicted. Single-core has no cross-thread
  // sync to deadlock on. User-toggleable; single-vs-dual perf A/B stays open per-title.
  SetBaseIfUnspecified(Config::MAIN_CPU_THREAD, false);
  // Speed-first video/CPU defaults
  SetBaseIfUnspecified(Config::GFX_HACK_SKIP_EFB_COPY_TO_RAM, true);
  SetBaseIfUnspecified(Config::GFX_HACK_SKIP_XFB_COPY_TO_RAM, true);
  SetBaseIfUnspecified(Config::GFX_HACK_IMMEDIATE_XFB, true);
  SetBaseIfUnspecified(Config::GFX_HACK_VI_SKIP, true);
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

- (void)applicationWillTerminate:(UIApplication*)application {
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
