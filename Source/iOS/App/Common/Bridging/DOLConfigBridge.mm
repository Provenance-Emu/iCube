// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "DOLConfigBridge.h"

#import <Foundation/Foundation.h>

// C++ includes
#include "Common/Config/Config.h"
#include "Core/Config/MainSettings.h"
#include "Core/Config/GraphicsSettings.h"
#include "Core/Config/iOSSettings.h"
#include "AudioCommon/AudioCommon.h"
#include "Core/Config/SYSCONFSettings.h"
#include "Core/Config/UISettings.h"
#include "Core/Config/MainSettings.h"
#include "Core/Config/WiimoteSettings.h"
#include "Core/HW/SI/SI_Device.h"
#include "Core/HW/Wiimote.h"
#include "Core/Config/AchievementSettings.h"
#include "Core/AchievementManager.h"
#include "Common/Logging/Log.h"

@implementation DOLConfigBridge

+ (NSString *)gfxBackend {
  const std::string v = Config::Get(Config::MAIN_GFX_BACKEND);
  return [NSString stringWithUTF8String:v.c_str()];
}
+ (void)setGfxBackend:(NSString *)value {
  Config::SetBaseOrCurrent(Config::MAIN_GFX_BACKEND, std::string(value.UTF8String));
}

+ (BOOL)gfxVSync { return Config::Get(Config::GFX_VSYNC); }
+ (void)setGfxVSync:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_VSYNC, (bool)enabled); }

+ (NSInteger)gfxAspectRatio { return (NSInteger)Config::Get(Config::GFX_ASPECT_RATIO); }
+ (void)setGfxAspectRatio:(NSInteger)value { Config::SetBaseOrCurrent(Config::GFX_ASPECT_RATIO, (AspectMode)value); }

// Graphics > Settings
// Internal Resolution (EFB Scale)
+ (NSInteger)gfxEfbScale { return (NSInteger)Config::Get(Config::GFX_EFB_SCALE); }
+ (void)setGfxEfbScale:(NSInteger)scale { Config::SetBaseOrCurrent(Config::GFX_EFB_SCALE, (int)scale); }
// Maximum Internal Resolution supported by backend/device
+ (NSInteger)gfxEfbMaxScale { return (NSInteger)Config::Get(Config::GFX_MAX_EFB_SCALE); }
// Widescreen Hack
+ (BOOL)gfxWidescreenHack { return Config::Get(Config::GFX_WIDESCREEN_HACK); }
+ (void)setGfxWidescreenHack:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_WIDESCREEN_HACK, (bool)enabled); }
// Disable Fog
+ (BOOL)gfxDisableFog { return Config::Get(Config::GFX_DISABLE_FOG); }
+ (void)setGfxDisableFog:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_DISABLE_FOG, (bool)enabled); }

+ (BOOL)gfxAsyncPresent { return Config::Get(Config::GFX_ASYNC_PRESENT); }
+ (void)setGfxAsyncPresent:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_ASYNC_PRESENT, (bool)enabled); }

+ (BOOL)gfxAutoIREnable { return Config::Get(Config::GFX_AUTO_IR_ENABLE); }
+ (void)setGfxAutoIREnable:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_AUTO_IR_ENABLE, (bool)enabled); }
+ (NSInteger)gfxAutoIRTargetFPS { return (NSInteger)Config::Get(Config::GFX_AUTO_IR_TARGET_FPS); }
+ (void)setGfxAutoIRTargetFPS:(NSInteger)fps { Config::SetBaseOrCurrent(Config::GFX_AUTO_IR_TARGET_FPS, (int)fps); }
+ (NSInteger)gfxAutoIRMinScale { return (NSInteger)Config::Get(Config::GFX_AUTO_IR_MIN_SCALE); }
+ (void)setGfxAutoIRMinScale:(NSInteger)scale { Config::SetBaseOrCurrent(Config::GFX_AUTO_IR_MIN_SCALE, (int)scale); }
+ (NSInteger)gfxAutoIRMaxScale { return (NSInteger)Config::Get(Config::GFX_AUTO_IR_MAX_SCALE); }
+ (void)setGfxAutoIRMaxScale:(NSInteger)scale { Config::SetBaseOrCurrent(Config::GFX_AUTO_IR_MAX_SCALE, (int)scale); }
+ (BOOL)gfxAutoIRShowOSD { return Config::Get(Config::GFX_AUTO_IR_SHOW_OSD); }
+ (void)setGfxAutoIRShowOSD:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_AUTO_IR_SHOW_OSD, (bool)enabled); }

+ (NSInteger)gfxShaderCompilationMode { return (NSInteger)Config::Get(Config::GFX_SHADER_COMPILATION_MODE); }
+ (void)setGfxShaderCompilationMode:(NSInteger)mode { Config::SetBaseOrCurrent(Config::GFX_SHADER_COMPILATION_MODE, (ShaderCompilationMode)mode); }
+ (BOOL)gfxWaitForShadersBeforeStarting { return Config::Get(Config::GFX_WAIT_FOR_SHADERS_BEFORE_STARTING); }
+ (void)setGfxWaitForShadersBeforeStarting:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_WAIT_FOR_SHADERS_BEFORE_STARTING, (bool)enabled); }

// Controllers
+ (BOOL)mainBackgroundInput { return Config::Get(Config::MAIN_INPUT_BACKGROUND_INPUT); }
+ (void)setMainBackgroundInput:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_INPUT_BACKGROUND_INPUT, (bool)enabled); }
+ (BOOL)wiimoteContinuousScanning { return Config::Get(Config::MAIN_WIIMOTE_CONTINUOUS_SCANNING); }
+ (void)setWiimoteContinuousScanning:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_WIIMOTE_CONTINUOUS_SCANNING, (bool)enabled); }
+ (BOOL)wiimoteEnableSpeaker { return Config::Get(Config::MAIN_WIIMOTE_ENABLE_SPEAKER); }
+ (void)setWiimoteEnableSpeaker:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_WIIMOTE_ENABLE_SPEAKER, (bool)enabled); }
+ (BOOL)connectWiimotesForControllerInterface { return Config::Get(Config::MAIN_CONNECT_WIIMOTES_FOR_CONTROLLER_INTERFACE); }
+ (void)setConnectWiimotesForControllerInterface:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_CONNECT_WIIMOTES_FOR_CONTROLLER_INTERFACE, (bool)enabled); }

// Controllers > Types
+ (NSInteger)gcPortDeviceForPort:(NSInteger)portOneBased {
  int port = (int)portOneBased;
  return (NSInteger)Config::Get(Config::GetInfoForSIDevice(port));
}
+ (void)setGCPortDeviceForPort:(NSInteger)portOneBased device:(NSInteger)device {
  int port = (int)portOneBased;
  Config::SetBaseOrCurrent(Config::GetInfoForSIDevice(port), (SerialInterface::SIDevices)device);
}
+ (NSInteger)wiimoteSourceForIndex:(NSInteger)indexOneBased {
  int idx = (int)indexOneBased;
  return (NSInteger)Config::Get(Config::GetInfoForWiimoteSource(idx));
}
+ (void)setWiimoteSourceForIndex:(NSInteger)indexOneBased source:(NSInteger)source {
  int idx = (int)indexOneBased;
  Config::SetBaseOrCurrent(Config::GetInfoForWiimoteSource(idx), (WiimoteSource)source);
}

// Debug
+ (BOOL)mainFastmem { return Config::Get(Config::MAIN_FASTMEM); }
+ (void)setMainFastmem:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_FASTMEM, (bool)enabled); }
+ (BOOL)mainSyncOnSkipIdle { return Config::Get(Config::MAIN_SYNC_ON_SKIP_IDLE); }
+ (void)setMainSyncOnSkipIdle:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_SYNC_ON_SKIP_IDLE, (bool)enabled); }

// Config > General
+ (BOOL)mainCpuThread { return Config::Get(Config::MAIN_CPU_THREAD); }
+ (void)setMainCpuThread:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_CPU_THREAD, (bool)enabled); }
+ (BOOL)mainEnableCheats { return Config::Get(Config::MAIN_ENABLE_CHEATS); }
+ (void)setMainEnableCheats:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_ENABLE_CHEATS, (bool)enabled); }
+ (BOOL)mainOverrideRegionSettings { return Config::Get(Config::MAIN_OVERRIDE_REGION_SETTINGS); }
+ (void)setMainOverrideRegionSettings:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_OVERRIDE_REGION_SETTINGS, (bool)enabled); }
+ (BOOL)mainAutoDiscChange { return Config::Get(Config::MAIN_AUTO_DISC_CHANGE); }
+ (void)setMainAutoDiscChange:(BOOL)enabled { Config::SetBase(Config::MAIN_AUTO_DISC_CHANGE, (bool)enabled); }
+ (BOOL)mainFastDiscSpeed { return Config::Get(Config::MAIN_FAST_DISC_SPEED); }
+ (void)setMainFastDiscSpeed:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_FAST_DISC_SPEED, (bool)enabled); }
+ (BOOL)mainDSPThread { return Config::Get(Config::MAIN_DSP_THREAD); }
+ (void)setMainDSPThread:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_DSP_THREAD, (bool)enabled); }
+ (NSInteger)mainFallbackRegion { return (NSInteger)Config::Get(Config::MAIN_FALLBACK_REGION); }
+ (void)setMainFallbackRegion:(NSInteger)regionRaw { Config::SetBaseOrCurrent(Config::MAIN_FALLBACK_REGION, (DiscIO::Region)regionRaw); }
+ (NSInteger)mainEmulationSpeedPercent { float v = Config::Get(Config::MAIN_EMULATION_SPEED); return (NSInteger)lroundf(v * 100.0f); }
+ (void)setMainEmulationSpeedPercent:(NSInteger)percent { float v = (percent <= 0 ? 0.0f : ((float)percent) / 100.0f); Config::SetBaseOrCurrent(Config::MAIN_EMULATION_SPEED, v); }

// Controllers > Touchscreen (iOS)
+ (float)mainTouchPadOpacity { return Config::Get(Config::MAIN_TOUCH_PAD_OPACITY); }
+ (void)setMainTouchPadOpacity:(float)opacity { Config::SetBaseOrCurrent(Config::MAIN_TOUCH_PAD_OPACITY, (float)opacity); }
+ (NSInteger)mainTouchPadIRMode { return (NSInteger)Config::Get(Config::MAIN_TOUCH_PAD_IR_MODE); }
+ (void)setMainTouchPadIRMode:(NSInteger)mode { Config::SetBaseOrCurrent(Config::MAIN_TOUCH_PAD_IR_MODE, (int)mode); }

// Config > Advanced
+ (NSInteger)mainCpuCore {
  int v = (int)Config::Get(Config::MAIN_CPU_CORE);
  INFO_LOG_FMT(POWERPC, "DOLConfigBridge.mainCpuCore -> {}", v);
  return (NSInteger)v;
}
+ (void)setMainCpuCore:(NSInteger)core {
  INFO_LOG_FMT(POWERPC, "DOLConfigBridge.setMainCpuCore({})", (int)core);
  Config::SetBaseOrCurrent(Config::MAIN_CPU_CORE, (PowerPC::CPUCore)core);
}
+ (BOOL)mainMMU { return Config::Get(Config::MAIN_MMU); }
+ (void)setMainMMU:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_MMU, (bool)enabled); }
+ (BOOL)mainPauseOnPanic { return Config::Get(Config::MAIN_PAUSE_ON_PANIC); }
+ (void)setMainPauseOnPanic:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_PAUSE_ON_PANIC, (bool)enabled); }
+ (BOOL)mainAccurateCpuCache { return Config::Get(Config::MAIN_ACCURATE_CPU_CACHE); }
+ (void)setMainAccurateCpuCache:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_ACCURATE_CPU_CACHE, (bool)enabled); }
+ (BOOL)mainDisableICache { return Config::Get(Config::MAIN_DISABLE_ICACHE); }
+ (void)setMainDisableICache:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_DISABLE_ICACHE, (bool)enabled); }
+ (BOOL)mainLowDCBZHack { return Config::Get(Config::MAIN_LOW_DCBZ_HACK); }
+ (void)setMainLowDCBZHack:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_LOW_DCBZ_HACK, (bool)enabled); }
+ (BOOL)mainOverclockEnable { return Config::Get(Config::MAIN_OVERCLOCK_ENABLE); }
+ (void)setMainOverclockEnable:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_OVERCLOCK_ENABLE, (bool)enabled); }
+ (NSInteger)mainOverclockPercent { float v = Config::Get(Config::MAIN_OVERCLOCK); return (NSInteger)lroundf(v * 100.0f); }
+ (void)setMainOverclockPercent:(NSInteger)percent { float v = ((float)percent) / 100.0f; Config::SetBaseOrCurrent(Config::MAIN_OVERCLOCK, v); }
+ (BOOL)mainViOverclockEnable { return Config::Get(Config::MAIN_VI_OVERCLOCK_ENABLE); }
+ (void)setMainViOverclockEnable:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_VI_OVERCLOCK_ENABLE, (bool)enabled); }
+ (NSInteger)mainViOverclockPercent { float v = Config::Get(Config::MAIN_VI_OVERCLOCK); return (NSInteger)lroundf(v * 100.0f); }
+ (void)setMainViOverclockPercent:(NSInteger)percent { float v = ((float)percent) / 100.0f; Config::SetBaseOrCurrent(Config::MAIN_VI_OVERCLOCK, v); }
+ (BOOL)mainRamOverrideEnable { return Config::Get(Config::MAIN_RAM_OVERRIDE_ENABLE); }
+ (void)setMainRamOverrideEnable:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_RAM_OVERRIDE_ENABLE, (bool)enabled); }
+ (NSInteger)mainMem1SizeMB { int bytes = Config::Get(Config::MAIN_MEM1_SIZE); return (NSInteger)(bytes / 0x100000); }
+ (void)setMainMem1SizeMB:(NSInteger)mb { Config::SetBaseOrCurrent(Config::MAIN_MEM1_SIZE, (int)mb * 0x100000); }
+ (NSInteger)mainMem2SizeMB { int bytes = Config::Get(Config::MAIN_MEM2_SIZE); return (NSInteger)(bytes / 0x100000); }
+ (void)setMainMem2SizeMB:(NSInteger)mb { Config::SetBaseOrCurrent(Config::MAIN_MEM2_SIZE, (int)mb * 0x100000); }
+ (BOOL)mainCustomRtcEnable { return Config::Get(Config::MAIN_CUSTOM_RTC_ENABLE); }
+ (void)setMainCustomRtcEnable:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_CUSTOM_RTC_ENABLE, (bool)enabled); }
+ (NSInteger)mainCustomRtcValue { double secs = Config::Get(Config::MAIN_CUSTOM_RTC_VALUE); return (NSInteger)llround(secs); }
+ (void)setMainCustomRtcValue:(NSInteger)unixSeconds { Config::SetBaseOrCurrent(Config::MAIN_CUSTOM_RTC_VALUE, (double)unixSeconds); }

// Config > Interface
+ (BOOL)mainUseBuiltInTitleDatabase { return Config::Get(Config::MAIN_USE_BUILT_IN_TITLE_DATABASE); }
+ (void)setMainUseBuiltInTitleDatabase:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_USE_BUILT_IN_TITLE_DATABASE, (bool)enabled); }
+ (BOOL)mainUseGameCovers { return Config::Get(Config::MAIN_USE_GAME_COVERS); }
+ (void)setMainUseGameCovers:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_USE_GAME_COVERS, (bool)enabled); }
+ (BOOL)mainConfirmOnStop { return Config::Get(Config::MAIN_CONFIRM_ON_STOP); }
+ (void)setMainConfirmOnStop:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_CONFIRM_ON_STOP, (bool)enabled); }
+ (BOOL)mainUsePanicHandlers { return Config::Get(Config::MAIN_USE_PANIC_HANDLERS); }
+ (void)setMainUsePanicHandlers:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_USE_PANIC_HANDLERS, (bool)enabled); }
+ (BOOL)mainOSDMessages { return Config::Get(Config::MAIN_OSD_MESSAGES); }
+ (void)setMainOSDMessages:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_OSD_MESSAGES, (bool)enabled); }

// Config > Audio
+ (NSArray<NSString*> *)audioBackends {
  std::vector<std::string> v = AudioCommon::GetSoundBackends();
  NSMutableArray<NSString*>* arr = [NSMutableArray arrayWithCapacity:v.size()];
  for (const auto& s : v) { [arr addObject:[NSString stringWithUTF8String:s.c_str()]]; }
  return arr;
}
+ (NSString *)audioBackend {
  const std::string v = Config::Get(Config::MAIN_AUDIO_BACKEND);
  return [NSString stringWithUTF8String:v.c_str()];
}
+ (void)setAudioBackend:(NSString *)backend {
  Config::SetBaseOrCurrent(Config::MAIN_AUDIO_BACKEND, std::string(backend.UTF8String));
}
+ (NSInteger)audioVolume { return (NSInteger)Config::Get(Config::MAIN_AUDIO_VOLUME); }
+ (void)setAudioVolume:(NSInteger)percent { Config::SetBaseOrCurrent(Config::MAIN_AUDIO_VOLUME, (int)percent); }
+ (BOOL)audioStretch { return Config::Get(Config::MAIN_AUDIO_STRETCH); }
+ (void)setAudioStretch:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_AUDIO_STRETCH, (bool)enabled); }
+ (NSInteger)audioStretchLatencyMs { return (NSInteger)Config::Get(Config::MAIN_AUDIO_STRETCH_LATENCY); }
+ (void)setAudioStretchLatencyMs:(NSInteger)ms { Config::SetBaseOrCurrent(Config::MAIN_AUDIO_STRETCH_LATENCY, (int)ms); }
+ (BOOL)audioMuteOnDisabledSpeedLimit { return Config::Get(Config::MAIN_AUDIO_MUTE_ON_DISABLED_SPEED_LIMIT); }
+ (void)setAudioMuteOnDisabledSpeedLimit:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_AUDIO_MUTE_ON_DISABLED_SPEED_LIMIT, (bool)enabled); }
+ (BOOL)audioMuteSwitchObey { return ((int)Config::Get(Config::MAIN_MUTE_SWITCH_MODE)) != 0; }
+ (void)setAudioMuteSwitchObey:(BOOL)obey { Config::SetBaseOrCurrent(Config::MAIN_MUTE_SWITCH_MODE, (int)(obey ? 1 : 0)); }

// Config > GameCube
+ (BOOL)mainSkipIPL { return Config::Get(Config::MAIN_SKIP_IPL); }
+ (void)setMainSkipIPL:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_SKIP_IPL, (bool)enabled); }
+ (NSInteger)mainGCLanguage { return (NSInteger)Config::Get(Config::MAIN_GC_LANGUAGE); }
+ (void)setMainGCLanguage:(NSInteger)lang { Config::SetBaseOrCurrent(Config::MAIN_GC_LANGUAGE, (int)lang); }

// Config > Wii
+ (BOOL)sysconfPAL60 { return Config::Get(Config::SYSCONF_PAL60); }
+ (void)setSysconfPAL60:(BOOL)enabled { Config::SetBase(Config::SYSCONF_PAL60, (bool)enabled); }
+ (BOOL)sysconfScreensaver { return Config::Get(Config::SYSCONF_SCREENSAVER); }
+ (void)setSysconfScreensaver:(BOOL)enabled { Config::SetBase(Config::SYSCONF_SCREENSAVER, (bool)enabled); }
+ (BOOL)mainWiiKeyboard { return Config::Get(Config::MAIN_WII_KEYBOARD); }
+ (void)setMainWiiKeyboard:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_WII_KEYBOARD, (bool)enabled); }
+ (BOOL)mainWiiWiiLinkEnable { return Config::Get(Config::MAIN_WII_WIILINK_ENABLE); }
+ (void)setMainWiiWiiLinkEnable:(BOOL)enabled { Config::SetBase(Config::MAIN_WII_WIILINK_ENABLE, (bool)enabled); }
+ (BOOL)mainWiiSDCard { return Config::Get(Config::MAIN_WII_SD_CARD); }
+ (void)setMainWiiSDCard:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_WII_SD_CARD, (bool)enabled); }
+ (BOOL)mainAllowSDWrites { return Config::Get(Config::MAIN_ALLOW_SD_WRITES); }
+ (void)setMainAllowSDWrites:(BOOL)enabled { Config::SetBase(Config::MAIN_ALLOW_SD_WRITES, (bool)enabled); }
+ (BOOL)mainWiiSDCardEnableFolderSync { return Config::Get(Config::MAIN_WII_SD_CARD_ENABLE_FOLDER_SYNC); }
+ (void)setMainWiiSDCardEnableFolderSync:(BOOL)enabled { Config::SetBase(Config::MAIN_WII_SD_CARD_ENABLE_FOLDER_SYNC, (bool)enabled); }
+ (BOOL)sysconfWidescreen { return Config::Get(Config::SYSCONF_WIDESCREEN); }
+ (void)setSysconfWidescreen:(BOOL)enabled { Config::SetBase(Config::SYSCONF_WIDESCREEN, (bool)enabled); }
+ (NSInteger)sysconfLanguage { return (NSInteger)Config::Get(Config::SYSCONF_LANGUAGE); }
+ (void)setSysconfLanguage:(NSInteger)lang { Config::SetBase(Config::SYSCONF_LANGUAGE, (int)lang); }
+ (NSInteger)sysconfSoundMode { return (NSInteger)Config::Get(Config::SYSCONF_SOUND_MODE); }
+ (void)setSysconfSoundMode:(NSInteger)mode { Config::SetBase(Config::SYSCONF_SOUND_MODE, (int)mode); }
+ (NSInteger)sysconfSensorBarPosition { return (NSInteger)Config::Get(Config::SYSCONF_SENSOR_BAR_POSITION); }
+ (void)setSysconfSensorBarPosition:(NSInteger)pos { Config::SetBase(Config::SYSCONF_SENSOR_BAR_POSITION, (int)pos); }
+ (NSInteger)sysconfSensorBarSensitivity { return (NSInteger)Config::Get(Config::SYSCONF_SENSOR_BAR_SENSITIVITY); }
+ (void)setSysconfSensorBarSensitivity:(NSInteger)sens { Config::SetBase(Config::SYSCONF_SENSOR_BAR_SENSITIVITY, (int)sens); }
+ (NSInteger)sysconfSpeakerVolume { return (NSInteger)Config::Get(Config::SYSCONF_SPEAKER_VOLUME); }
+ (void)setSysconfSpeakerVolume:(NSInteger)vol { Config::SetBase(Config::SYSCONF_SPEAKER_VOLUME, (int)vol); }
+ (BOOL)sysconfWiimoteMotor { return Config::Get(Config::SYSCONF_WIIMOTE_MOTOR); }
+ (void)setSysconfWiimoteMotor:(BOOL)enabled { Config::SetBase(Config::SYSCONF_WIIMOTE_MOTOR, (bool)enabled); }

// RetroAchievements (Config + control)
+ (BOOL)raEnabled { return Config::Get(Config::RA_ENABLED); }
+ (void)setRaEnabled:(BOOL)enabled {
  Config::SetBaseOrCurrent(Config::RA_ENABLED, (bool)enabled);
  if (enabled) AchievementManager::GetInstance().Init(); else AchievementManager::GetInstance().Shutdown();
}
+ (NSString*)raUsername {
  std::string u = Config::Get(Config::RA_USERNAME);
  return [NSString stringWithUTF8String:u.c_str()];
}
+ (void)setRaUsername:(NSString*)username { Config::SetBaseOrCurrent(Config::RA_USERNAME, username.UTF8String ? username.UTF8String : ""); }
+ (BOOL)raHardcoreEnabled { return Config::Get(Config::RA_HARDCORE_ENABLED); }
+ (void)setRaHardcoreEnabled:(BOOL)enabled { Config::SetBaseOrCurrent(Config::RA_HARDCORE_ENABLED, (bool)enabled); }
+ (BOOL)raUnofficialEnabled { return Config::Get(Config::RA_UNOFFICIAL_ENABLED); }
+ (void)setRaUnofficialEnabled:(BOOL)enabled { Config::SetBaseOrCurrent(Config::RA_UNOFFICIAL_ENABLED, (bool)enabled); }
+ (BOOL)raEncoreEnabled { return Config::Get(Config::RA_ENCORE_ENABLED); }
+ (void)setRaEncoreEnabled:(BOOL)enabled { Config::SetBaseOrCurrent(Config::RA_ENCORE_ENABLED, (bool)enabled); }
+ (BOOL)raSpectatorEnabled { return Config::Get(Config::RA_SPECTATOR_ENABLED); }
+ (void)setRaSpectatorEnabled:(BOOL)enabled { Config::SetBaseOrCurrent(Config::RA_SPECTATOR_ENABLED, (bool)enabled); AchievementManager::GetInstance().SetSpectatorMode(); }
+ (BOOL)raDiscordPresenceEnabled { return Config::Get(Config::RA_DISCORD_PRESENCE_ENABLED); }
+ (void)setRaDiscordPresenceEnabled:(BOOL)enabled { Config::SetBaseOrCurrent(Config::RA_DISCORD_PRESENCE_ENABLED, (bool)enabled); }
+ (BOOL)raProgressEnabled { return Config::Get(Config::RA_PROGRESS_ENABLED); }
+ (void)setRaProgressEnabled:(BOOL)enabled { Config::SetBaseOrCurrent(Config::RA_PROGRESS_ENABLED, (bool)enabled); }
+ (NSString*)raHostURL {
  std::string h = Config::Get(Config::RA_HOST_URL);
  return [NSString stringWithUTF8String:h.c_str()];
}
+ (void)setRaHostURL:(NSString*)url { Config::SetBaseOrCurrent(Config::RA_HOST_URL, url.UTF8String ? url.UTF8String : ""); }
+ (BOOL)raHasAPIToken { return AchievementManager::GetInstance().HasAPIToken(); }
+ (void)raInit { AchievementManager::GetInstance().Init(); }
+ (void)raShutdown { AchievementManager::GetInstance().Shutdown(); }
+ (void)raLogin:(NSString*)password { AchievementManager::GetInstance().Login(password.UTF8String ? password.UTF8String : ""); }
+ (void)raLogout { AchievementManager::GetInstance().Logout(); }

// Graphics > Enhancements
+ (BOOL)gfxEnhanceForceTrueColor { return Config::Get(Config::GFX_ENHANCE_FORCE_TRUE_COLOR); }
+ (void)setGfxEnhanceForceTrueColor:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_ENHANCE_FORCE_TRUE_COLOR, (bool)enabled); }
+ (BOOL)gfxEnhanceDisableCopyFilter { return Config::Get(Config::GFX_ENHANCE_DISABLE_COPY_FILTER); }
+ (void)setGfxEnhanceDisableCopyFilter:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_ENHANCE_DISABLE_COPY_FILTER, (bool)enabled); }
+ (NSInteger)gfxEnhanceAnisotropySamples {
  // stored as exponent x for 1<<x; translate to samples for UI
  int x = Config::Get(Config::GFX_ENHANCE_MAX_ANISOTROPY);
  int samples = 1 << std::clamp(x, 0, 4);
  return samples;
}
+ (void)setGfxEnhanceAnisotropySamples:(NSInteger)samples {
  int s = (int)samples;
  int x = 0;
  if (s >= 16) x = 4; else if (s >= 8) x = 3; else if (s >= 4) x = 2; else if (s >= 2) x = 1; else x = 0;
  Config::SetBaseOrCurrent(Config::GFX_ENHANCE_MAX_ANISOTROPY, x);
}

// Additional Enhancements
+ (BOOL)gfxEnhanceArbitraryMipmapDetection { return Config::Get(Config::GFX_ENHANCE_ARBITRARY_MIPMAP_DETECTION); }
+ (void)setGfxEnhanceArbitraryMipmapDetection:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_ENHANCE_ARBITRARY_MIPMAP_DETECTION, (bool)enabled); }
+ (float)gfxEnhanceArbitraryMipmapDetectionThreshold { return Config::Get(Config::GFX_ENHANCE_ARBITRARY_MIPMAP_DETECTION_THRESHOLD); }
+ (void)setGfxEnhanceArbitraryMipmapDetectionThreshold:(float)threshold { Config::SetBaseOrCurrent(Config::GFX_ENHANCE_ARBITRARY_MIPMAP_DETECTION_THRESHOLD, (float)threshold); }
+ (BOOL)gfxEnhanceHDROutput { return Config::Get(Config::GFX_ENHANCE_HDR_OUTPUT); }
+ (void)setGfxEnhanceHDROutput:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_ENHANCE_HDR_OUTPUT, (bool)enabled); }

// Graphics > Hacks
+ (BOOL)gfxHackEfbAccessEnable { return Config::Get(Config::GFX_HACK_EFB_ACCESS_ENABLE); }
+ (void)setGfxHackEfbAccessEnable:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_HACK_EFB_ACCESS_ENABLE, (bool)enabled); }
+ (BOOL)gfxHackSkipEfbCopyToRam { return Config::Get(Config::GFX_HACK_SKIP_EFB_COPY_TO_RAM); }
+ (void)setGfxHackSkipEfbCopyToRam:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_HACK_SKIP_EFB_COPY_TO_RAM, (bool)enabled); }
+ (BOOL)gfxHackSkipXfbCopyToRam { return Config::Get(Config::GFX_HACK_SKIP_XFB_COPY_TO_RAM); }
+ (void)setGfxHackSkipXfbCopyToRam:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_HACK_SKIP_XFB_COPY_TO_RAM, (bool)enabled); }
+ (BOOL)gfxHackImmediateXfb { return Config::Get(Config::GFX_HACK_IMMEDIATE_XFB); }
+ (void)setGfxHackImmediateXfb:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_HACK_IMMEDIATE_XFB, (bool)enabled); }
+ (BOOL)gfxHackCopyEfbScaled { return Config::Get(Config::GFX_HACK_COPY_EFB_SCALED); }
+ (void)setGfxHackCopyEfbScaled:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_HACK_COPY_EFB_SCALED, (bool)enabled); }
+ (BOOL)gfxHackEfbEmulateFormatChanges { return Config::Get(Config::GFX_HACK_EFB_EMULATE_FORMAT_CHANGES); }
+ (void)setGfxHackEfbEmulateFormatChanges:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_HACK_EFB_EMULATE_FORMAT_CHANGES, (bool)enabled); }
+ (BOOL)gfxHackVertexRounding { return Config::Get(Config::GFX_HACK_VERTEX_ROUNDING); }
+ (void)setGfxHackVertexRounding:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_HACK_VERTEX_ROUNDING, (bool)enabled); }
+ (BOOL)gfxHackForceProgressive { return Config::Get(Config::GFX_HACK_FORCE_PROGRESSIVE); }
+ (void)setGfxHackForceProgressive:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_HACK_FORCE_PROGRESSIVE, (bool)enabled); }
+ (BOOL)gfxHackDeferEfbCopies { return Config::Get(Config::GFX_HACK_DEFER_EFB_COPIES); }
+ (void)setGfxHackDeferEfbCopies:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_HACK_DEFER_EFB_COPIES, (bool)enabled); }
+ (NSInteger)gfxHackViSkipMode { return (NSInteger)Config::Get(Config::GFX_HACK_VI_SKIP_MODE); }
+ (void)setGfxHackViSkipMode:(NSInteger)mode { Config::SetBaseOrCurrent(Config::GFX_HACK_VI_SKIP_MODE, (TriState)mode); }
+ (BOOL)gfxHackFastTextureSampling { return Config::Get(Config::GFX_HACK_FAST_TEXTURE_SAMPLING); }
+ (void)setGfxHackFastTextureSampling:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_HACK_FAST_TEXTURE_SAMPLING, (bool)enabled); }

// Graphics > Advanced
+ (BOOL)gfxFastDepthCalc { return Config::Get(Config::GFX_FAST_DEPTH_CALC); }
+ (void)setGfxFastDepthCalc:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_FAST_DEPTH_CALC, (bool)enabled); }
+ (BOOL)gfxEnablePixelLighting { return Config::Get(Config::GFX_ENABLE_PIXEL_LIGHTING); }
+ (void)setGfxEnablePixelLighting:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_ENABLE_PIXEL_LIGHTING, (bool)enabled); }
+ (BOOL)gfxBackendMultithreading { return Config::Get(Config::GFX_BACKEND_MULTITHREADING); }
+ (void)setGfxBackendMultithreading:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_BACKEND_MULTITHREADING, (bool)enabled); }
+ (BOOL)gfxShaderCache { return Config::Get(Config::GFX_SHADER_CACHE); }
+ (void)setGfxShaderCache:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_SHADER_CACHE, (bool)enabled); }
+ (BOOL)gfxSaveTextureCacheToState { return Config::Get(Config::GFX_SAVE_TEXTURE_CACHE_TO_STATE); }
+ (void)setGfxSaveTextureCacheToState:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_SAVE_TEXTURE_CACHE_TO_STATE, (bool)enabled); }
+ (BOOL)gfxPreferVSForLinePointExpansion { return Config::Get(Config::GFX_PREFER_VS_FOR_LINE_POINT_EXPANSION); }
+ (void)setGfxPreferVSForLinePointExpansion:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_PREFER_VS_FOR_LINE_POINT_EXPANSION, (bool)enabled); }
+ (BOOL)gfxCpuCull { return Config::Get(Config::GFX_CPU_CULL); }
+ (void)setGfxCpuCull:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_CPU_CULL, (bool)enabled); }

// Graphics > Advanced - Performance Statistics
+ (BOOL)gfxShowFPS { return Config::Get(Config::GFX_SHOW_FPS); }
+ (void)setGfxShowFPS:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_SHOW_FPS, (bool)enabled); }
+ (BOOL)gfxShowVPS { return Config::Get(Config::GFX_SHOW_VPS); }
+ (void)setGfxShowVPS:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_SHOW_VPS, (bool)enabled); }
+ (BOOL)gfxShowSpeed { return Config::Get(Config::GFX_SHOW_SPEED); }
+ (void)setGfxShowSpeed:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_SHOW_SPEED, (bool)enabled); }
+ (BOOL)gfxShowFTimes { return Config::Get(Config::GFX_SHOW_FTIMES); }
+ (void)setGfxShowFTimes:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_SHOW_FTIMES, (bool)enabled); }
+ (BOOL)gfxShowVTimes { return Config::Get(Config::GFX_SHOW_VTIMES); }
+ (void)setGfxShowVTimes:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_SHOW_VTIMES, (bool)enabled); }
+ (BOOL)gfxShowGraphs { return Config::Get(Config::GFX_SHOW_GRAPHS); }
+ (void)setGfxShowGraphs:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_SHOW_GRAPHS, (bool)enabled); }
+ (BOOL)gfxLogRenderTimeToFile { return Config::Get(Config::GFX_LOG_RENDER_TIME_TO_FILE); }
+ (void)setGfxLogRenderTimeToFile:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_LOG_RENDER_TIME_TO_FILE, (bool)enabled); }
+ (BOOL)gfxShowSpeedColors { return Config::Get(Config::GFX_SHOW_SPEED_COLORS); }
+ (void)setGfxShowSpeedColors:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_SHOW_SPEED_COLORS, (bool)enabled); }

// Debugging
+ (BOOL)gfxOverlayStats { return Config::Get(Config::GFX_OVERLAY_STATS); }
+ (void)setGfxOverlayStats:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_OVERLAY_STATS, (bool)enabled); }
+ (BOOL)gfxEnableValidationLayer { return Config::Get(Config::GFX_ENABLE_VALIDATION_LAYER); }
+ (void)setGfxEnableValidationLayer:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_ENABLE_VALIDATION_LAYER, (bool)enabled); }

// Utility
+ (BOOL)gfxHiresTextures { return Config::Get(Config::GFX_HIRES_TEXTURES); }
+ (void)setGfxHiresTextures:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_HIRES_TEXTURES, (bool)enabled); }
+ (BOOL)gfxCacheHiresTextures { return Config::Get(Config::GFX_CACHE_HIRES_TEXTURES); }
+ (void)setGfxCacheHiresTextures:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_CACHE_HIRES_TEXTURES, (bool)enabled); }
+ (BOOL)gfxHackDisableCopyToVRAM { return Config::Get(Config::GFX_HACK_DISABLE_COPY_TO_VRAM); }
+ (void)setGfxHackDisableCopyToVRAM:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_HACK_DISABLE_COPY_TO_VRAM, (bool)enabled); }
+ (BOOL)gfxModsEnable { return Config::Get(Config::GFX_MODS_ENABLE); }
+ (void)setGfxModsEnable:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_MODS_ENABLE, (bool)enabled); }

// Misc
+ (BOOL)gfxCrop { return Config::Get(Config::GFX_CROP); }
+ (void)setGfxCrop:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_CROP, (bool)enabled); }
+ (BOOL)sysconfProgressiveScan { return Config::Get(Config::SYSCONF_PROGRESSIVE_SCAN); }
+ (void)setSysconfProgressiveScan:(BOOL)enabled { Config::SetBaseOrCurrent(Config::SYSCONF_PROGRESSIVE_SCAN, (bool)enabled); }

// Shader Threads
+ (NSInteger)gfxShaderCompilerThreads { return (NSInteger)Config::Get(Config::GFX_SHADER_COMPILER_THREADS); }
+ (void)setGfxShaderCompilerThreads:(NSInteger)value { Config::SetBaseOrCurrent(Config::GFX_SHADER_COMPILER_THREADS, (int)value); }
+ (NSInteger)gfxShaderPrecompilerThreads { return (NSInteger)Config::Get(Config::GFX_SHADER_PRECOMPILER_THREADS); }
+ (void)setGfxShaderPrecompilerThreads:(NSInteger)value { Config::SetBaseOrCurrent(Config::GFX_SHADER_PRECOMPILER_THREADS, (int)value); }

// Experimental
+ (BOOL)gfxHackEfbDeferInvalidation { return Config::Get(Config::GFX_HACK_EFB_DEFER_INVALIDATION); }
+ (void)setGfxHackEfbDeferInvalidation:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_HACK_EFB_DEFER_INVALIDATION, (bool)enabled); }

@end
