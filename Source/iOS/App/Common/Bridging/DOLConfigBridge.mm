// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "DOLConfigBridge.h"

#import <Foundation/Foundation.h>

// C++ includes
#include "Common/Config/Config.h"
#include "Core/Config/MainSettings.h"
#include "Core/Config/GraphicsSettings.h"
// Full definition of `enum class TriState` (GraphicsSettings.h only forward-declares it). Needed for
// the (TriState)mode cast in the VISkipMode setter (setVISkipMode:).
#include "VideoCommon/VideoConfig.h"
#include "Core/Config/iOSSettings.h"
#include "AudioCommon/AudioCommon.h"
#include "Core/Config/SYSCONFSettings.h"
#include "Core/Config/UISettings.h"
#include "Core/Config/WiimoteSettings.h"
#include "Core/HW/SI/SI_Device.h"
#include "Core/HW/Wiimote.h"
#include "Core/Config/AchievementSettings.h"
#include "Core/AchievementManager.h"
#include "InputCommon/ControllerInterface/DualShockUDPClient/DualShockUDPClient.h"
#include "Common/Logging/Log.h"
#include "Core/Core.h"
#include "Core/System.h"
#include "Common/IOFile.h"
#include "Core/IOS/USB/Emulated/Skylanders/Skylander.h"
#include "Core/IOS/USB/Emulated/Skylanders/SkylanderFigure.h"
#include <atomic>

// Extern DSU client RX counter for DEBUG HUD (defined in DualShockUDPClient.cpp)
namespace ciface { namespace DualShockUDPClient { extern std::atomic<uint64_t> g_rx_counter; } }

NSNotificationName const DOLConfigChangedNotification = @"DOLConfigChanged";

// iCube settings-sync backbone (see startConfigAutoSyncBridge). Coalescing flags so a burst of
// Config changes (e.g. a Reset writing ~120 keys) collapses to ONE UI notification + ONE debounced
// save instead of 120 of each.
static std::atomic_bool s_cfg_notify_pending{false};
static std::atomic_bool s_cfg_save_pending{false};

// True while the core is actively executing. Config changes then are mostly runtime overrides
// (adaptive clock, per-run layer) that churn rapidly and that Save() (Base-only) shouldn't thrash
// I/O for — the save-on-background path persists those. Settings the user edits in menus happen
// outside this state.
static bool ICubeEmulationActive() {
  const Core::State st = Core::GetState(Core::System::GetInstance());
  return st == Core::State::Running || st == Core::State::Starting;
}

@implementation DOLConfigBridge

+ (void)initializeConfigIfNeeded {
  Config::Init();
}

// iCube settings-sync backbone: one global Config-changed hook that keeps the SwiftUI settings in
// sync with Dolphin's Config (the single source of truth) WITHOUT per-setter plumbing.
//   (a) Debounced auto-save of the Base layer — fixes "settings don't persist between runs"
//       universally: most setters write Base via SetBaseOrCurrent without a per-toggle Save(), so
//       any change is otherwise lost unless something flushes. Skipped during active emulation.
//   (b) Coalesced "DOLConfigChanged" notification — lets open settings screens re-read live Config
//       after a Reset / game-INI load / runtime change so the UI never shows a stale value.
// Idempotent: registers exactly once.
+ (void)startConfigAutoSyncBridge {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    Config::AddConfigChangedCallback([] {
      // (b) one UI-refresh notification per runloop tick (cheap no-op when no settings view observes).
      if (!s_cfg_notify_pending.exchange(true)) {
        dispatch_async(dispatch_get_main_queue(), ^{
          s_cfg_notify_pending = false;
          [[NSNotificationCenter defaultCenter] postNotificationName:DOLConfigChangedNotification object:nil];
        });
      }
      // (a) one debounced Base-layer save (skip during emulation; re-check at fire time).
      if (!ICubeEmulationActive() && !s_cfg_save_pending.exchange(true)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
          s_cfg_save_pending = false;
          if (!ICubeEmulationActive())
            Config::Save();
        });
      }
    });
  });
}

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
// MANUAL setter: writes the Base layer unconditionally. Perf-knob resolver step #3 layer discipline:
// manual UI authors Base; auto controllers (AutoIRController, ThermalManager) author CurrentRun.
// Reads (Config::Get) prefer CurrentRun, so an active auto override is automatically "effective"
// while the user's Base value is preserved underneath and re-exposed when the override clears.
+ (void)setGfxEfbScale:(NSInteger)scale { Config::SetBase(Config::GFX_EFB_SCALE, (int)scale); }
// AUTO setter: writes the CurrentRun layer (like AutoIRController). Used by thermal auto-tuning so
// its throttle shadows — never overwrites — the user's manual Base value. Guard against a missing
// CurrentRun layer: thermal notifications can fire outside emulation, and Config::Set dereferences
// GetLayer(layer) with no null check (Config.h:106). CurrentRun is created at Config::Init and on
// every boot (ClearCurrentRunLayer), so it normally exists; the guard is belt-and-suspenders.
+ (void)setGfxEfbScaleAuto:(NSInteger)scale {
  if (Config::GetLayer(Config::LayerType::CurrentRun))
    Config::Set(Config::LayerType::CurrentRun, Config::GFX_EFB_SCALE, (int)scale);
}
// Clear the auto (CurrentRun) EFB override, re-exposing the user's manual Base value. Used by the
// thermal "restore quality" path: deleting the CurrentRun entry (rather than writing the captured
// baseline back into CurrentRun) avoids pinning the key on CurrentRun, which would otherwise leave
// the "Auto" badge stuck on and the manual control disabled after the device cools.
+ (void)clearGfxEfbScaleAuto {
  if (Config::GetLayer(Config::LayerType::CurrentRun))
    Config::DeleteKey(Config::LayerType::CurrentRun, Config::GFX_EFB_SCALE);
}
// Resolver step #3 "Auto" badge: is a perf key currently overridden by an auto controller? True iff
// the effective (active) layer for the key is CurrentRun — i.e. an auto write is shadowing Base.
+ (BOOL)isEfbScaleAutoOverridden {
  return Config::GetActiveLayerForConfig(Config::GFX_EFB_SCALE) == Config::LayerType::CurrentRun;
}
+ (BOOL)isOverclockAutoOverridden {
  return Config::GetActiveLayerForConfig(Config::MAIN_OVERCLOCK) == Config::LayerType::CurrentRun;
}
+ (BOOL)isViOverclockAutoOverridden {
  return Config::GetActiveLayerForConfig(Config::MAIN_VI_OVERCLOCK) == Config::LayerType::CurrentRun;
}
// Maximum Internal Resolution supported by backend/device
+ (NSInteger)gfxEfbMaxScale { return (NSInteger)Config::Get(Config::GFX_MAX_EFB_SCALE); }
// Widescreen Hack
+ (BOOL)gfxWidescreenHack { return Config::Get(Config::GFX_WIDESCREEN_HACK); }
+ (void)setGfxWidescreenHack:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_WIDESCREEN_HACK, (bool)enabled); }
// Disable Fog
+ (BOOL)gfxDisableFog { return Config::Get(Config::GFX_DISABLE_FOG); }
+ (void)setGfxDisableFog:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_DISABLE_FOG, (bool)enabled); }
+ (BOOL)gfxEnableGPUTextureDecoding { return Config::Get(Config::GFX_ENABLE_GPU_TEXTURE_DECODING); }
+ (void)setGfxEnableGPUTextureDecoding:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_ENABLE_GPU_TEXTURE_DECODING, (bool)enabled); }

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
// NOTE: these accessors take a ONE-based port/index from the UI, but Config::GetInfoForSIDevice /
// GetInfoForWiimoteSource index a ZERO-based static array with NO bounds check. Passing the 1-based
// value straight through read SIDevice[1..4]/Wiimote[1..4] — off by one (e.g. "Wiimote 4" hit the
// Balance Board at index 4) — and for SI (array size 4) port 4 was an OUT-OF-BOUNDS read that
// returned a garbage Info& whose cache mutex was junk → `lock_shared` EINVAL → crash in
// Settings > Controllers. Convert to 0-based + bounds-guard.
+ (NSInteger)gcPortDeviceForPort:(NSInteger)portOneBased {
  const int ch = (int)portOneBased - 1;  // SIDevice channels are 0..3
  if (ch < 0 || ch > 3) return (NSInteger)SerialInterface::SIDEVICE_NONE;
  return (NSInteger)Config::Get(Config::GetInfoForSIDevice(ch));
}
+ (void)setGCPortDeviceForPort:(NSInteger)portOneBased device:(NSInteger)device {
  const int ch = (int)portOneBased - 1;
  if (ch < 0 || ch > 3) return;
  Config::SetBaseOrCurrent(Config::GetInfoForSIDevice(ch), (SerialInterface::SIDevices)device);
}
+ (NSInteger)wiimoteSourceForIndex:(NSInteger)indexOneBased {
  const int idx = (int)indexOneBased - 1;  // wiimote sources are 0..3 (index 4 = Balance Board)
  if (idx < 0 || idx > 3) return 0;  // 0 = WiimoteSource::None
  return (NSInteger)Config::Get(Config::GetInfoForWiimoteSource(idx));
}
+ (void)setWiimoteSourceForIndex:(NSInteger)indexOneBased source:(NSInteger)source {
  const int idx = (int)indexOneBased - 1;
  if (idx < 0 || idx > 3) return;
  Config::SetBaseOrCurrent(Config::GetInfoForWiimoteSource(idx), (WiimoteSource)source);
}

// Debug
+ (BOOL)mainFastmem { return Config::Get(Config::MAIN_FASTMEM); }
+ (void)setMainFastmem:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_FASTMEM, (bool)enabled); }
+ (BOOL)mainSyncOnSkipIdle { return Config::Get(Config::MAIN_SYNC_ON_SKIP_IDLE); }
+ (void)setMainSyncOnSkipIdle:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_SYNC_ON_SKIP_IDLE, (bool)enabled); }

// Idle loop detection / fast-forward toggles
+ (BOOL)mainRelaxedIdleDetection { return Config::Get(Config::MAIN_RELAXED_IDLE_DETECTION); }
+ (void)setMainRelaxedIdleDetection:(BOOL)enabled { Config::SetBase(Config::MAIN_RELAXED_IDLE_DETECTION, (bool)enabled); }
+ (BOOL)mainFastForwardCtrIdle { return Config::Get(Config::MAIN_FAST_FORWARD_CTR_IDLE); }
+ (void)setMainFastForwardCtrIdle:(BOOL)enabled { Config::SetBase(Config::MAIN_FAST_FORWARD_CTR_IDLE, (bool)enabled); }

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
  // CPU core is a structural, low-frequency setting and the user A/Bs it often (e.g. the
  // experimental IR core). Persist immediately so the choice survives a relaunch even
  // without a background flush. (See flushSettingsToDisk for the general save-on-background.)
  Config::Save();
}
+ (BOOL)mainMMU { return Config::Get(Config::MAIN_MMU); }
+ (void)setMainMMU:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_MMU, (bool)enabled); }
+ (BOOL)mainPauseOnPanic { return Config::Get(Config::MAIN_PAUSE_ON_PANIC); }
+ (void)setMainPauseOnPanic:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_PAUSE_ON_PANIC, (bool)enabled); }
+ (BOOL)mainAccurateCpuCache { return Config::Get(Config::MAIN_ACCURATE_CPU_CACHE); }
+ (void)setMainAccurateCpuCache:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_ACCURATE_CPU_CACHE, (bool)enabled); }
+ (BOOL)mainDisableICache { return Config::Get(Config::MAIN_DISABLE_ICACHE); }
+ (void)setMainDisableICache:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_DISABLE_ICACHE, (bool)enabled); }
// Cached Interpreter: block linking toggle

+ (BOOL)mainLowDCBZHack { return Config::Get(Config::MAIN_LOW_DCBZ_HACK); }
+ (void)setMainLowDCBZHack:(BOOL)enabled {
  Config::SetBaseOrCurrent(Config::MAIN_LOW_DCBZ_HACK, (bool)enabled);
  // Bug 2: flush Base layer to disk immediately so the toggle round-trips across a
  // full app relaunch (mirrors the DSU setters). When not emulating, SetBaseOrCurrent
  // writes Base; Config::Save() persists Base to the INI. Harmless while emulating
  // (writes CurrentRun, Save() is a no-op for that key).
  Config::Save();
}

// Cached Interpreter: fast FP paths (experimental)
+ (BOOL)mainFpFast { return Config::Get(Config::MAIN_FP_FAST); }
+ (void)setMainFpFast:(BOOL)enabled {
  Config::SetBaseOrCurrent(Config::MAIN_FP_FAST, (bool)enabled);
  // Bug 2: flush Base layer to disk immediately so the toggle round-trips across a
  // full app relaunch (mirrors the DSU setters). See setMainLowDCBZHack above.
  Config::Save();
}
// Cached Interpreter: Apple-Silicon hot-loop software-prefetch (default on; A/B toggle)
+ (BOOL)mainCachedInterpreterPrefetch { return Config::Get(Config::MAIN_CACHED_INTERPRETER_PREFETCH); }
+ (void)setMainCachedInterpreterPrefetch:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_CACHED_INTERPRETER_PREFETCH, (bool)enabled); }
+ (BOOL)cirPicLoadStore { return Config::Get(Config::MAIN_CIR_PIC_LOADSTORE); }
+ (void)setCirPicLoadStore:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_CIR_PIC_LOADSTORE, (bool)enabled); }
+ (BOOL)cirSpecializedOps { return Config::Get(Config::MAIN_CIR_SPECIALIZED_OPS); }
+ (void)setCirSpecializedOps:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_CIR_SPECIALIZED_OPS, (bool)enabled); }
+ (BOOL)cirSpecializedOpsValidate { return Config::Get(Config::MAIN_CIR_SPECIALIZED_OPS_VALIDATE); }
+ (void)setCirSpecializedOpsValidate:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_CIR_SPECIALIZED_OPS_VALIDATE, (bool)enabled); }
+ (BOOL)cirMicroOpFusion { return Config::Get(Config::MAIN_CIR_MICROOP_FUSION); }
+ (void)setCirMicroOpFusion:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_CIR_MICROOP_FUSION, (bool)enabled); }
+ (BOOL)cirMicroOpFusionValidate { return Config::Get(Config::MAIN_CIR_MICROOP_FUSION_VALIDATE); }
+ (void)setCirMicroOpFusionValidate:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_CIR_MICROOP_FUSION_VALIDATE, (bool)enabled); }
+ (BOOL)cirDeadFlagElim { return Config::Get(Config::MAIN_CIR_DEAD_FLAG_ELIM); }
+ (void)setCirDeadFlagElim:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_CIR_DEAD_FLAG_ELIM, (bool)enabled); }
+ (BOOL)cirDeadFlagElimValidate { return Config::Get(Config::MAIN_CIR_DEAD_FLAG_ELIM_VALIDATE); }
+ (void)setCirDeadFlagElimValidate:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_CIR_DEAD_FLAG_ELIM_VALIDATE, (bool)enabled); }
+ (BOOL)cirDeadFprfElim { return Config::Get(Config::MAIN_CIR_DEAD_FPRF_ELIM); }
+ (void)setCirDeadFprfElim:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_CIR_DEAD_FPRF_ELIM, (bool)enabled); }
+ (BOOL)cirDeadFprfElimValidate { return Config::Get(Config::MAIN_CIR_DEAD_FPRF_ELIM_VALIDATE); }
+ (void)setCirDeadFprfElimValidate:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_CIR_DEAD_FPRF_ELIM_VALIDATE, (bool)enabled); }
+ (BOOL)cirPsqFastPath { return Config::Get(Config::MAIN_CIR_PSQ_FASTPATH); }
+ (void)setCirPsqFastPath:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_CIR_PSQ_FASTPATH, (bool)enabled); }
+ (BOOL)cirPsqFastPathValidate { return Config::Get(Config::MAIN_CIR_PSQ_FASTPATH_VALIDATE); }
+ (void)setCirPsqFastPathValidate:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_CIR_PSQ_FASTPATH_VALIDATE, (bool)enabled); }
+ (BOOL)cirBlockLinking { return Config::Get(Config::MAIN_CIR_BLOCK_LINKING); }
+ (void)setCirBlockLinking:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_CIR_BLOCK_LINKING, (bool)enabled); }
+ (BOOL)cirBlockLinkingValidate { return Config::Get(Config::MAIN_CIR_BLOCK_LINKING_VALIDATE); }
+ (void)setCirBlockLinkingValidate:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_CIR_BLOCK_LINKING_VALIDATE, (bool)enabled); }
// MANUAL CPU/VI clock setters: write the Base layer (resolver step #3 layer discipline). The
// adaptive clock controller writes these same keys on the CurrentRun layer directly via
// Config::SetCurrent (EmulationCoordinator.mm:484-489,584-593), NOT through these bridges, so
// flipping these to SetBase cannot disturb the auto path. With no auto controller active there is
// no CurrentRun entry, so reads return Base = identical to the prior SetBaseOrCurrent behavior.
+ (BOOL)mainOverclockEnable { return Config::Get(Config::MAIN_OVERCLOCK_ENABLE); }
+ (void)setMainOverclockEnable:(BOOL)enabled { Config::SetBase(Config::MAIN_OVERCLOCK_ENABLE, (bool)enabled); }
+ (NSInteger)mainOverclockPercent { float v = Config::Get(Config::MAIN_OVERCLOCK); return (NSInteger)lroundf(v * 100.0f); }
+ (void)setMainOverclockPercent:(NSInteger)percent { float v = ((float)percent) / 100.0f; Config::SetBase(Config::MAIN_OVERCLOCK, v); }
+ (BOOL)mainViOverclockEnable { return Config::Get(Config::MAIN_VI_OVERCLOCK_ENABLE); }
+ (void)setMainViOverclockEnable:(BOOL)enabled { Config::SetBase(Config::MAIN_VI_OVERCLOCK_ENABLE, (bool)enabled); }
+ (NSInteger)mainViOverclockPercent { float v = Config::Get(Config::MAIN_VI_OVERCLOCK); return (NSInteger)lroundf(v * 100.0f); }
+ (void)setMainViOverclockPercent:(NSInteger)percent { float v = ((float)percent) / 100.0f; Config::SetBase(Config::MAIN_VI_OVERCLOCK, v); }
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
+ (BOOL)audioStretch { return Config::Get(Config::MAIN_AUDIO_LATENCY) > 0; }
+ (void)setAudioStretch:(BOOL)enabled {
  // Map stretch toggle to a non-zero latency when enabled, else zero.
  int cur = Config::Get(Config::MAIN_AUDIO_LATENCY);
  if (enabled && cur <= 0) cur = 80;
  if (!enabled) cur = 0;
  Config::SetBaseOrCurrent(Config::MAIN_AUDIO_LATENCY, cur);
}
+ (NSInteger)audioStretchLatencyMs { return (NSInteger)Config::Get(Config::MAIN_AUDIO_LATENCY); }
+ (void)setAudioStretchLatencyMs:(NSInteger)ms { Config::SetBaseOrCurrent(Config::MAIN_AUDIO_LATENCY, (int)ms); }
+ (BOOL)audioMuteOnDisabledSpeedLimit { return Config::Get(Config::MAIN_AUDIO_MUTE_ON_DISABLED_SPEED_LIMIT); }
+ (void)setAudioMuteOnDisabledSpeedLimit:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_AUDIO_MUTE_ON_DISABLED_SPEED_LIMIT, (bool)enabled); }
+ (BOOL)audioMuteSwitchObey { return ((int)Config::Get(Config::MAIN_MUTE_SWITCH_MODE)) != 0; }
+ (void)setAudioMuteSwitchObey:(BOOL)obey { Config::SetBaseOrCurrent(Config::MAIN_MUTE_SWITCH_MODE, (int)(obey ? 1 : 0)); }

// Config > GameCube
+ (BOOL)mainSkipIPL { return Config::Get(Config::MAIN_SKIP_IPL); }
+ (void)setMainSkipIPL:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_SKIP_IPL, (bool)enabled); }
+ (NSInteger)mainGCLanguage { return (NSInteger)Config::Get(Config::MAIN_GC_LANGUAGE); }
+ (void)setMainGCLanguage:(NSInteger)lang {
  Config::SetBaseOrCurrent(Config::MAIN_GC_LANGUAGE, (int)lang);
  // Bug 6: persist immediately so the selection survives a relaunch and so
  // mainGCLanguageIsSet reports YES afterward (matches DSU/Save idiom).
  Config::Save();
}
+ (BOOL)mainGCLanguageIsSet {
  // Base layer always exists once config is loaded; Exists() distinguishes an
  // explicitly-stored value from the compiled Info<> default (0).
  std::shared_ptr<Config::Layer> base = Config::GetLayer(Config::LayerType::Base);
  return (base && base->Exists(Config::MAIN_GC_LANGUAGE.GetLocation())) ? YES : NO;
}

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

#if USE_RETRO_ACHIEVEMENTS
// RetroAchievements (Config + control)
+ (BOOL)raEnabled { return Config::Get(Config::RA_ENABLED); }
+ (void)setRaEnabled:(BOOL)enabled {
  Config::SetBaseOrCurrent(Config::RA_ENABLED, (bool)enabled);
  if (enabled) AchievementManager::GetInstance().Init(nullptr); else AchievementManager::GetInstance().Shutdown();
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
+ (void)raInit { AchievementManager::GetInstance().Init(nullptr); }
+ (void)raShutdown { AchievementManager::GetInstance().Shutdown(); }
+ (void)raLogin:(NSString*)password { AchievementManager::GetInstance().Login(password.UTF8String ? password.UTF8String : ""); }
+ (void)raLogout { AchievementManager::GetInstance().Logout(); }
#endif // USE_RETRO_ACHIEVEMENTS

// Graphics > Enhancements
+ (BOOL)gfxEnhanceForceTrueColor { return Config::Get(Config::GFX_ENHANCE_FORCE_TRUE_COLOR); }
+ (void)setGfxEnhanceForceTrueColor:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_ENHANCE_FORCE_TRUE_COLOR, (bool)enabled); }
+ (BOOL)gfxEnhanceDisableCopyFilter { return Config::Get(Config::GFX_ENHANCE_DISABLE_COPY_FILTER); }
+ (void)setGfxEnhanceDisableCopyFilter:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_ENHANCE_DISABLE_COPY_FILTER, (bool)enabled); }
+ (NSInteger)gfxEnhanceAnisotropySamples {
  // stored as exponent x for 1<<x; translate to samples for UI
  int af = (int)Config::Get(Config::GFX_ENHANCE_MAX_ANISOTROPY);
  int samples = 1 << std::clamp(af, 0, 4);
  return samples;
}
+ (void)setGfxEnhanceAnisotropySamples:(NSInteger)samples {
  int s = (int)samples;
  int x = 0;
  if (s >= 16) x = 4; else if (s >= 8) x = 3; else if (s >= 4) x = 2; else if (s >= 2) x = 1; else x = 0;
  Config::SetBaseOrCurrent(Config::GFX_ENHANCE_MAX_ANISOTROPY, static_cast<AnisotropicFilteringMode>(x));
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
// iCube: ARM64 NEON texture decoder (default on; A/B toggle)
+ (BOOL)gfxHackNeonTextureDecode { return Config::Get(Config::GFX_HACK_NEON_TEXTURE_DECODE); }
+ (void)setGfxHackNeonTextureDecode:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_HACK_NEON_TEXTURE_DECODE, (bool)enabled); }
+ (NSInteger)gfxHackViSkipMode { return (NSInteger)Config::Get(Config::GFX_HACK_VI_SKIP_MODE); }
+ (void)setGfxHackViSkipMode:(NSInteger)mode { Config::SetBaseOrCurrent(Config::GFX_HACK_VI_SKIP_MODE, (TriState)mode); }
+ (BOOL)gfxHackViDecimateInterlace { return Config::Get(Config::GFX_HACK_VI_DECIMATE_INTERLACE); }
+ (void)setGfxHackViDecimateInterlace:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_HACK_VI_DECIMATE_INTERLACE, (bool)enabled); }
+ (BOOL)gfxHackFastTextureSampling { return Config::Get(Config::GFX_HACK_FAST_TEXTURE_SAMPLING); }
+ (void)setGfxHackFastTextureSampling:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_HACK_FAST_TEXTURE_SAMPLING, (bool)enabled); }
+ (BOOL)gfxHackFastMath { return Config::Get(Config::GFX_HACK_FAST_MATH); }
+ (void)setGfxHackFastMath:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_HACK_FAST_MATH, (bool)enabled); }
+ (BOOL)gfxUseComputeEfbXfb { return Config::Get(Config::GFX_USE_COMPUTE_EFBXFB); }
+ (void)setGfxUseComputeEfbXfb:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_USE_COMPUTE_EFBXFB, (bool)enabled); }
+ (BOOL)gfxUseComputeVertexDecode { return Config::Get(Config::GFX_USE_COMPUTE_VERTEX_DECODE); }
+ (void)setGfxUseComputeVertexDecode:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_USE_COMPUTE_VERTEX_DECODE, (bool)enabled); }
+ (BOOL)gfxHackNoMipmapping { return Config::Get(Config::GFX_HACK_NO_MIPMAPPING); }
+ (void)setGfxHackNoMipmapping:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_HACK_NO_MIPMAPPING, (bool)enabled); }
+ (BOOL)gfxHackEarlyXfbOutput { return Config::Get(Config::GFX_HACK_EARLY_XFB_OUTPUT); }
+ (void)setGfxHackEarlyXfbOutput:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_HACK_EARLY_XFB_OUTPUT, (bool)enabled); }
+ (BOOL)gfxHackSkipDuplicateXFBs { return Config::Get(Config::GFX_HACK_SKIP_DUPLICATE_XFBS); }
+ (void)setGfxHackSkipDuplicateXFBs:(BOOL)enabled { Config::SetBaseOrCurrent(Config::GFX_HACK_SKIP_DUPLICATE_XFBS, (bool)enabled); }

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

+ (BOOL)mainEmulateSkylanderPortal { return Config::Get(Config::MAIN_EMULATE_SKYLANDER_PORTAL); }
+ (void)setMainEmulateSkylanderPortal:(BOOL)enabled { Config::SetBaseOrCurrent(Config::MAIN_EMULATE_SKYLANDER_PORTAL, (bool)enabled); }

// iCube: gameplay/perf "Reset Settings".
//
// Goal: restore the optimized default config for everything that affects how a
// game plays/performs (video, hacks, resolution, shaders, CPU, audio) WITHOUT
// disturbing identity/custom data (remote-source logins, servers, imported
// library, RetroAchievements credentials, controller device assignments).
//
// Mechanism: the UI writes every gameplay/perf value via SetBaseOrCurrent. When
// no game is running (the state when "Reset" is tapped from root Settings) that
// writes to the Base layer. Deleting a key from a layer makes Config::Get fall
// through to the compiled Info<> default (see Layer.h Get<>()). So we delete
// each RESET key from every layer it could live in. PRESERVE keys are simply
// absent from this list, so they are untouched.
//
// We intentionally do NOT RemoveLayer(GlobalGame/LocalGame) here: those layers
// can hold per-game controller overrides (PRESERVE). Key-scoped deletion is the
// conservative choice.
+ (void)resetGameplayConfigKeys {
  // Delete a key from every layer it could live in, so Config::Get falls through
  // to the compiled Info<> default.
  //
  // IMPORTANT: Config::DeleteKey(layer, info) dereferences GetLayer(layer) without
  // a null check (Config.h:134). When no game is running the CurrentRun/LocalGame/
  // GlobalGame layers are typically absent, so we must guard with GetLayer() first
  // — exactly as the existing resetPageToDefaults does. Base always exists.
  static const Config::LayerType kLayers[] = {
    Config::LayerType::CurrentRun,
    Config::LayerType::LocalGame,
    Config::LayerType::GlobalGame,
    Config::LayerType::Base,
  };
  auto del = [](const auto& info) {
    for (Config::LayerType lt : kLayers) {
      if (Config::GetLayer(lt)) {
        Config::DeleteKey(lt, info);
      }
    }
  };

  // ---- CPU / core (perf) ----
  del(Config::MAIN_CPU_CORE);
  del(Config::MAIN_CPU_THREAD);
  del(Config::MAIN_MMU);
  del(Config::MAIN_ACCURATE_CPU_CACHE);
  del(Config::MAIN_DISABLE_ICACHE);
  del(Config::MAIN_LOW_DCBZ_HACK);
  del(Config::MAIN_FP_FAST);
  del(Config::MAIN_FASTMEM);
  del(Config::MAIN_SYNC_ON_SKIP_IDLE);
  del(Config::MAIN_RELAXED_IDLE_DETECTION);
  del(Config::MAIN_FAST_FORWARD_CTR_IDLE);
  del(Config::MAIN_CACHED_INTERPRETER_PREFETCH);   // default true -> optimized
  // CIR optimization toggles: compiled defaults already match iCube intent, so del-to-default is correct.
  del(Config::MAIN_CIR_PIC_LOADSTORE);
  del(Config::MAIN_CIR_MICROOP_FUSION);
  del(Config::MAIN_CIR_MICROOP_FUSION_VALIDATE);
  del(Config::MAIN_CIR_BLOCK_LINKING);
  del(Config::MAIN_CIR_BLOCK_LINKING_VALIDATE);
  del(Config::MAIN_CIR_SPECIALIZED_OPS);
  del(Config::MAIN_CIR_SPECIALIZED_OPS_VALIDATE);
  del(Config::MAIN_CIR_DEAD_FLAG_ELIM);
  del(Config::MAIN_CIR_DEAD_FLAG_ELIM_VALIDATE);
  del(Config::MAIN_CIR_DEAD_FPRF_ELIM);
  del(Config::MAIN_CIR_DEAD_FPRF_ELIM_VALIDATE);
  del(Config::MAIN_CIR_PSQ_FASTPATH);
  del(Config::MAIN_CIR_PSQ_FASTPATH_VALIDATE);
  del(Config::MAIN_OVERCLOCK_ENABLE);
  del(Config::MAIN_OVERCLOCK);
  del(Config::MAIN_VI_OVERCLOCK_ENABLE);
  del(Config::MAIN_VI_OVERCLOCK);
  del(Config::MAIN_RAM_OVERRIDE_ENABLE);
  del(Config::MAIN_MEM1_SIZE);
  del(Config::MAIN_MEM2_SIZE);
  del(Config::MAIN_DSP_THREAD);
  del(Config::MAIN_EMULATION_SPEED);
  del(Config::MAIN_FAST_DISC_SPEED);
  del(Config::MAIN_CUSTOM_RTC_ENABLE);
  del(Config::MAIN_CUSTOM_RTC_VALUE);

  // ---- Misc gameplay / boot feature toggles ----
  del(Config::MAIN_SKIP_IPL);                 // boot: GC IPL/BIOS intro skip
  del(Config::MAIN_EMULATE_SKYLANDER_PORTAL); // peripheral emulation (default off)

  // ---- Audio ----
  del(Config::MAIN_AUDIO_BACKEND);
  del(Config::MAIN_AUDIO_VOLUME);
  del(Config::MAIN_AUDIO_LATENCY);
  del(Config::MAIN_AUDIO_MUTE_ON_DISABLED_SPEED_LIMIT);
  del(Config::MAIN_MUTE_SWITCH_MODE);

  // ---- Graphics: general / backend / resolution ----
  del(Config::MAIN_GFX_BACKEND);
  del(Config::GFX_VSYNC);
  del(Config::GFX_ASPECT_RATIO);
  del(Config::GFX_EFB_SCALE);
  del(Config::GFX_WIDESCREEN_HACK);
  del(Config::GFX_DISABLE_FOG);
  del(Config::GFX_ENABLE_GPU_TEXTURE_DECODING);
  del(Config::GFX_ASYNC_PRESENT);
  del(Config::GFX_AUTO_IR_ENABLE);
  del(Config::GFX_AUTO_IR_TARGET_FPS);
  del(Config::GFX_AUTO_IR_MIN_SCALE);
  del(Config::GFX_AUTO_IR_MAX_SCALE);
  del(Config::GFX_AUTO_IR_SHOW_OSD);
  del(Config::GFX_SHADER_COMPILATION_MODE);
  del(Config::GFX_WAIT_FOR_SHADERS_BEFORE_STARTING);
  del(Config::GFX_SHADER_COMPILER_THREADS);
  del(Config::GFX_SHADER_PRECOMPILER_THREADS);
  del(Config::GFX_CROP);

  // ---- Graphics: enhancements ----
  del(Config::GFX_ENHANCE_FORCE_TRUE_COLOR);
  del(Config::GFX_ENHANCE_DISABLE_COPY_FILTER);
  del(Config::GFX_ENHANCE_MAX_ANISOTROPY);
  del(Config::GFX_ENHANCE_ARBITRARY_MIPMAP_DETECTION);
  del(Config::GFX_ENHANCE_ARBITRARY_MIPMAP_DETECTION_THRESHOLD);
  del(Config::GFX_ENHANCE_HDR_OUTPUT);

  // ---- Graphics: hacks (incl. iCube perf) ----
  del(Config::GFX_HACK_EFB_ACCESS_ENABLE);
  del(Config::GFX_HACK_SKIP_EFB_COPY_TO_RAM);
  del(Config::GFX_HACK_SKIP_XFB_COPY_TO_RAM);
  del(Config::GFX_HACK_IMMEDIATE_XFB);
  del(Config::GFX_HACK_COPY_EFB_SCALED);
  del(Config::GFX_HACK_EFB_EMULATE_FORMAT_CHANGES);
  del(Config::GFX_HACK_VERTEX_ROUNDING);
  del(Config::GFX_HACK_FORCE_PROGRESSIVE);
  del(Config::GFX_HACK_DEFER_EFB_COPIES);
  del(Config::GFX_HACK_NEON_TEXTURE_DECODE);       // default true -> optimized
  del(Config::GFX_HACK_GPU_EFB_PEEK_RESOLVE);      // default false
  del(Config::GFX_HACK_VI_SKIP_MODE);
  del(Config::GFX_HACK_VI_DECIMATE_INTERLACE);
  del(Config::GFX_HACK_FAST_TEXTURE_SAMPLING);
  del(Config::GFX_HACK_FAST_MATH);
  del(Config::GFX_USE_COMPUTE_EFBXFB);
  del(Config::GFX_USE_COMPUTE_VERTEX_DECODE);
  del(Config::GFX_HACK_NO_MIPMAPPING);
  del(Config::GFX_HACK_EARLY_XFB_OUTPUT);
  del(Config::GFX_HACK_SKIP_DUPLICATE_XFBS);
  del(Config::GFX_HACK_DISABLE_COPY_TO_VRAM);
  del(Config::GFX_HACK_EFB_DEFER_INVALIDATION);

  // ---- Graphics: advanced/rendering ----
  del(Config::GFX_FAST_DEPTH_CALC);
  del(Config::GFX_ENABLE_PIXEL_LIGHTING);
  del(Config::GFX_BACKEND_MULTITHREADING);
  del(Config::GFX_SHADER_CACHE);
  del(Config::GFX_SAVE_TEXTURE_CACHE_TO_STATE);
  del(Config::GFX_PREFER_VS_FOR_LINE_POINT_EXPANSION);
  del(Config::GFX_CPU_CULL);
  del(Config::GFX_HIRES_TEXTURES);
  del(Config::GFX_CACHE_HIRES_TEXTURES);
  del(Config::GFX_MODS_ENABLE);

  // Force performant values whose compiled default is CONSERVATIVE on iOS, so "reset to optimal"
  // actually lands on the fast configuration instead of the slow upstream default.
  //
  // MAIN_CPU_THREAD (dual-core): force OFF (single-core). It was previously forced ON here as a
  // "~2x perf" default, but on device dual-core HARD-HANGS most games a few seconds into boot
  // (CPU<->GPU FIFO-fence deadlock on the lean CachedInterpreter — see DolphinCoreService revert
  // 6af4263ec3). Reset-to-defaults must land on the safe single-core config, matching the startup
  // default. (fastmem, EFB-to-texture/XFB-to-texture on, 1x IR, MMU/accurate-cache off all DO
  // compile to the optimal default, so deleting those is correct — but fast-disc, DSP-thread, and
  // immediate-XFB do NOT compile to iCube's value; they're forced just below.)
  Config::SetBase(Config::MAIN_CPU_THREAD, false);

  // GFX_WAIT_FOR_SHADERS_BEFORE_STARTING defaults FALSE upstream, which gives the awful combo of
  // Synchronous shader compilation WITHOUT precompiling = mid-gameplay stutter. iCube precompiles
  // up front (one-time boot wait, then no stutter), so force it on at reset too — a plain
  // delete-to-default would silently land back on the stuttery upstream default. Mode stays
  // Synchronous/Specialized (the upstream default reset lands on = the intended iCube mode).
  Config::SetBase(Config::GFX_WAIT_FOR_SHADERS_BEFORE_STARTING, true);

  // fast-disc, DSP-on-thread, and immediate-XFB all compile to the CONSERVATIVE upstream default
  // (false) — the OPPOSITE of what DolphinCoreService applies at launch via SetBaseIfUnspecified.
  // A plain delete-to-default silently lands them on the slow upstream value (the user-visible bug:
  // "reset flips some Generals to the opposite of recommended"), so force iCube's value here too,
  // matching the startup defaults. (GFX_ASYNC_PRESENT already compiles to true on Apple ARM64, so
  // it's correctly covered by the delete above.)
  Config::SetBase(Config::MAIN_FAST_DISC_SPEED, true);
  Config::SetBase(Config::MAIN_DSP_THREAD, true);
  Config::SetBase(Config::GFX_HACK_IMMEDIATE_XFB, true);

  // GFX_HACK_VI_SKIP_MODE compiles to TriState::Auto on Apple (GraphicsSettings.cpp). Reset should
  // land on Auto too — Auto is the bounded (4-skip cap) FALLBACK catch-up for the adaptive-clock-OFF
  // case, and when the adaptive clock is ON (the default) the runtime resolver forces VISkip Off
  // anyway. So the plain del(GFX_HACK_VI_SKIP_MODE) above is the correct reset; no forced override
  // here. (Matches the DolphinCoreService launch default, which also SetBaseIfUnspecified's Auto.)

  // NOTE: intentionally NOT reset (identity/custom/non-gameplay):
  //   - DSU servers/enable (ciface DualShockUDPClient::SERVERS / SERVERS_ENABLED)
  //   - RA_USERNAME / RA_HOST_URL / RA_* (RetroAchievements login)
  //   - GetInfoForSIDevice / GetInfoForWiimoteSource (controller assignments)
  //   - MAIN_INPUT_BACKGROUND_INPUT, wiimote scanning/speaker (input prefs)
  //   - SYSCONF_* and MAIN_WII_* region/console identity
  //   - MAIN_GFX/perf stats overlays (cosmetic; left as-is)
}

+ (void)resetGameplayUserDefaults {
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  // Removing a key makes the app-side default apply again, e.g. the vertex loader
  // defaults to NEON when icube_vertex_loader_mode is unset (EmulationCoordinator
  // ICubeJitlessVertexLoaderType), and triple-buffering defaults to true.
  NSArray<NSString*>* gameplayKeys = @[
    @"adaptive_clock_enable",
    @"adaptive_clock_schema_v",
    @"adaptive_clock_speed_threshold",
    @"adaptive_clock_sweep_step",
    @"icube_vertex_loader_mode",
    @"gfx_triple_buffering",
    @"gfx_force_scale_one_non_promo",
    @"ui_frame_cap",
    @"ui_gfx_backend",
    @"fast_forward_speed_percent",
    // CoreAudio DSP effect chain (audio, gameplay-affecting)
    @"ca_fx_crush_bits", @"ca_fx_crush_down", @"ca_fx_crush_enabled",
    @"ca_fx_delay_enabled", @"ca_fx_delay_fb", @"ca_fx_delay_ms",
    @"ca_fx_eq_enabled", @"ca_fx_eq_high", @"ca_fx_eq_low", @"ca_fx_eq_mid",
  ];
  for (NSString* k in gameplayKeys) {
    [d removeObjectForKey:k];
  }
  // Per-game learned adaptive-clock baselines: prefix-scan exactly like
  // EmulationCoordinator does when reading them back.
  NSDictionary<NSString*, id>* all = [d dictionaryRepresentation];
  for (NSString* key in all) {
    if ([key hasPrefix:@"adaptive_clock_cpu_"] || [key hasPrefix:@"adaptive_clock_vi_"]) {
      [d removeObjectForKey:key];
    }
  }
}

+ (void)resetAllToDefaults {
  // Reset gameplay/perf settings (video, hacks, resolution, shaders, CPU, audio)
  // to their optimized compiled defaults, WITHOUT touching identity/custom data
  // (remote-source logins, servers, imported library, RetroAchievements creds,
  // controller device assignments). See resetGameplayConfigKeys for the explicit
  // RESET vs PRESERVE split.
  [DOLConfigBridge resetGameplayConfigKeys];
  [DOLConfigBridge resetGameplayUserDefaults];
  // Persist Base layer to disk; defaults remain for the cleared keys.
  Config::Save();
}

+ (void)flushSettingsToDisk {
  // Persist any in-memory Base config changes to the INI. Most setters write Base via
  // SetBaseOrCurrent without an immediate Save(), so a setting toggled in the menu would
  // otherwise be lost on app termination (it reverts to its compiled/launch default on the
  // next launch — the visible "some toggles forget their value" bug). Called on app
  // background. Safe while emulating: per-game changes live in CurrentRun, and Save() only
  // serializes the Base layer.
  Config::Save();
}

+ (void)resetPageToDefaults:(NSInteger)page {
  auto safe_delete = [](auto info) {
    // Only delete from CurrentRun if that layer exists and the active layer is CurrentRun
    if (Config::GetActiveLayerForConfig(info) == Config::LayerType::CurrentRun) {
      if (Config::GetLayer(Config::LayerType::CurrentRun)) {
        Config::DeleteKey(Config::LayerType::CurrentRun, info);
      }
    }
  };

  switch (page) {
    case 0:
      safe_delete(Config::MAIN_CPU_THREAD);
      safe_delete(Config::MAIN_ENABLE_CHEATS);
      safe_delete(Config::MAIN_OVERRIDE_REGION_SETTINGS);
      safe_delete(Config::MAIN_AUTO_DISC_CHANGE);
      safe_delete(Config::MAIN_FAST_DISC_SPEED);
      safe_delete(Config::MAIN_DSP_THREAD);
      safe_delete(Config::MAIN_FALLBACK_REGION);
      safe_delete(Config::MAIN_EMULATION_SPEED);
      break;
    case 1:
      safe_delete(Config::MAIN_GFX_BACKEND);
      safe_delete(Config::GFX_VSYNC);
      safe_delete(Config::GFX_EFB_SCALE);
      safe_delete(Config::GFX_WIDESCREEN_HACK);
      safe_delete(Config::GFX_DISABLE_FOG);
      safe_delete(Config::GFX_ASYNC_PRESENT);
      safe_delete(Config::GFX_AUTO_IR_ENABLE);
      safe_delete(Config::GFX_AUTO_IR_TARGET_FPS);
      safe_delete(Config::GFX_AUTO_IR_MIN_SCALE);
      safe_delete(Config::GFX_AUTO_IR_MAX_SCALE);
      safe_delete(Config::GFX_AUTO_IR_SHOW_OSD);
      safe_delete(Config::GFX_SHADER_COMPILATION_MODE);
      safe_delete(Config::GFX_WAIT_FOR_SHADERS_BEFORE_STARTING);
      break;
    case 2:
      safe_delete(Config::MAIN_INPUT_BACKGROUND_INPUT);
      for (int p = 1; p <= 4; ++p) {
        safe_delete(Config::GetInfoForSIDevice(p));
        safe_delete(Config::GetInfoForWiimoteSource(p));
      }
      break;
    case 3:
      safe_delete(Config::MAIN_FASTMEM);
      safe_delete(Config::MAIN_SYNC_ON_SKIP_IDLE);
      break;
    case 4:
    default:
      break;
  }
  Config::Save();
}

+ (NSInteger)skylanderLoadFromPath:(NSString*)path
{
  std::string p = std::string(path.UTF8String);
  File::IOFile sky_file(p, "r+b");
  if (!sky_file)
    return -1;
  auto& system = Core::System::GetInstance();
  u8 slot = system.GetSkylanderPortal().LoadSkylander(std::make_unique<IOS::HLE::USB::SkylanderFigure>(std::move(sky_file)));
  return slot == 0xFF ? -1 : (slot + 1);
}
+ (BOOL)skylanderRemoveAtSlot:(NSInteger)slot
{
  if (slot <= 0) return NO;
  auto& system = Core::System::GetInstance();
  return system.GetSkylanderPortal().RemoveSkylander((u8)(slot - 1)) ? YES : NO;
}
+ (void)skylanderClearAll
{
  auto& system = Core::System::GetInstance();
  for (int i = 0; i < 16; i++)
    system.GetSkylanderPortal().RemoveSkylander((u8)i);
}

@end

// MARK: - DSU Client (Cemuhook DualShock UDP) bridging

@implementation DOLConfigBridge (DSU)

+ (BOOL)dsuClientEnabled
{
  return Config::Get(ciface::DualShockUDPClient::Settings::SERVERS_ENABLED);
}

+ (void)setDsuClientEnabled:(BOOL)enabled
{
  Config::SetBaseOrCurrent(ciface::DualShockUDPClient::Settings::SERVERS_ENABLED, (bool)enabled);
  Config::Save();
}

+ (NSString*)dsuServersString
{
  const std::string v = Config::Get(ciface::DualShockUDPClient::Settings::SERVERS);
  return [NSString stringWithUTF8String:v.c_str()];
}

+ (void)setDsuServersString:(NSString*)servers
{
  const char* cstr = servers ? servers.UTF8String : "";
  Config::SetBaseOrCurrent(ciface::DualShockUDPClient::Settings::SERVERS, std::string(cstr));
  Config::Save();
}

+ (NSArray<NSDictionary<NSString*, id>*>*)dsuServersParsed
{
  NSMutableArray* arr = [NSMutableArray array];
  NSString* raw = [self dsuServersString];
  if (raw.length == 0) return arr;
  // One-time normalization: strip stray '@' characters introduced by older builds
  if ([raw containsString:@"@"]) {
    NSString* normalized = [raw stringByReplacingOccurrencesOfString:@"@" withString:@""];
    if (![normalized isEqualToString:raw]) {
      [self setDsuServersString:normalized]; // also saves
      raw = normalized;
    }
  }
  NSArray<NSString*>* entries = [raw componentsSeparatedByString:@";"];
  for (NSString* e in entries) {
    if (e.length == 0) continue;
    NSArray<NSString*>* parts = [e componentsSeparatedByString:@":"];
    if (parts.count < 3) continue;
    NSString* desc = [parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString* addr = [parts[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSInteger port = (parts[2].integerValue);
    [arr addObject:@{ @"description": desc ?: @"", @"address": addr ?: @"", @"port": @(port) }];
  }
  return arr;
}

+ (void)addDsuServer:(NSString*)desc address:(NSString*)address port:(NSInteger)port
{
  if (desc.length == 0) desc = @"DS4";
  if (address.length == 0) return;
  if (port <= 0 || port >= 65536) return;
  // Sanitize address (remove stray '@')
  NSString* addr = [address stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  NSRange at = [addr rangeOfString:@"@"]; if (at.location != NSNotFound) { addr = [addr substringToIndex:at.location]; }
  NSString* raw = [self dsuServersString];
  NSString* entry = [NSString stringWithFormat:@"%@:%@:%ld;", desc, addr, (long)port];
  // Avoid duplicate exact entries
  if (raw && [raw containsString:entry]) return;
  NSString* updated = raw ? [raw stringByAppendingString:entry] : entry;
  [self setDsuServersString:updated]; // also saves
}

+ (void)removeDsuServerAtIndex:(NSInteger)index
{
  if (index < 0) return;
  NSString* raw = [self dsuServersString];
  if (raw.length == 0) return;
  NSMutableArray<NSString*>* entries = [[raw componentsSeparatedByString:@";"] mutableCopy];
  // Remove empty tail element if present due to trailing ';'
  if (entries.lastObject.length == 0) [entries removeLastObject];
  if (index >= (NSInteger)entries.count) return;
  [entries removeObjectAtIndex:index];
  // Rebuild string ensuring trailing ';'
  NSMutableString* rebuilt = [NSMutableString string];
  for (NSString* e in entries) {
    if (e.length == 0) continue;
    [rebuilt appendString:e];
    [rebuilt appendString:@";"];
  }
  [self setDsuServersString:rebuilt]; // also saves
}

+ (NSUInteger)dsuClientRxCount
{
  return (NSUInteger)ciface::DualShockUDPClient::g_rx_counter.load(std::memory_order_relaxed);
}

@end
