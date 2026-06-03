// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Typed config bridge for Graphics settings (safe for Swift)
@interface DOLConfigBridge : NSObject

// Backend
+ (NSString *)gfxBackend;
+ (void)setGfxBackend:(NSString *)value;

// VSync
+ (BOOL)gfxVSync;
+ (void)setGfxVSync:(BOOL)enabled;

// Aspect ratio (underlying enum rawValue)
+ (NSInteger)gfxAspectRatio;
+ (void)setGfxAspectRatio:(NSInteger)value;

// Graphics > Settings
// Internal Resolution (EFB Scale)
// Returns the configured EFB scale integer (see Config::GFX_EFB_SCALE)
// Caller is responsible for mapping to display labels.
// Also see Config::GFX_MAX_EFB_SCALE for bounds if needed.
+ (NSInteger)gfxEfbScale;
+ (void)setGfxEfbScale:(NSInteger)scale;
// Maximum Internal Resolution supported by backend/device
+ (NSInteger)gfxEfbMaxScale;
// GPU Texture Decoding
+ (BOOL)gfxEnableGPUTextureDecoding;
+ (void)setGfxEnableGPUTextureDecoding:(BOOL)enabled;
// Widescreen Hack (boolean)
+ (BOOL)gfxWidescreenHack;
+ (void)setGfxWidescreenHack:(BOOL)enabled;
// Disable Fog (boolean)
+ (BOOL)gfxDisableFog;
+ (void)setGfxDisableFog:(BOOL)enabled;

// Async present
+ (BOOL)gfxAsyncPresent;
+ (void)setGfxAsyncPresent:(BOOL)enabled;

// Auto IR
+ (BOOL)gfxAutoIREnable;
+ (void)setGfxAutoIREnable:(BOOL)enabled;
+ (NSInteger)gfxAutoIRTargetFPS;
+ (void)setGfxAutoIRTargetFPS:(NSInteger)fps;
+ (NSInteger)gfxAutoIRMinScale;
+ (void)setGfxAutoIRMinScale:(NSInteger)scale;
+ (NSInteger)gfxAutoIRMaxScale;
+ (void)setGfxAutoIRMaxScale:(NSInteger)scale;
+ (BOOL)gfxAutoIRShowOSD;
+ (void)setGfxAutoIRShowOSD:(BOOL)enabled;

// Shader compilation
+ (NSInteger)gfxShaderCompilationMode;
+ (void)setGfxShaderCompilationMode:(NSInteger)mode;
+ (BOOL)gfxWaitForShadersBeforeStarting;
+ (void)setGfxWaitForShadersBeforeStarting:(BOOL)enabled;

// Controllers (single page)
+ (BOOL)mainBackgroundInput;
+ (void)setMainBackgroundInput:(BOOL)enabled;
+ (BOOL)wiimoteContinuousScanning;
+ (void)setWiimoteContinuousScanning:(BOOL)enabled;
+ (BOOL)wiimoteEnableSpeaker;
+ (void)setWiimoteEnableSpeaker:(BOOL)enabled;
+ (BOOL)connectWiimotesForControllerInterface;
+ (void)setConnectWiimotesForControllerInterface:(BOOL)enabled;

// Debug
+ (BOOL)mainFastmem;
+ (void)setMainFastmem:(BOOL)enabled;
+ (BOOL)mainSyncOnSkipIdle;
+ (void)setMainSyncOnSkipIdle:(BOOL)enabled;

// Idle loop detection / fast-forward toggles
+ (BOOL)mainRelaxedIdleDetection;
+ (void)setMainRelaxedIdleDetection:(BOOL)enabled;
+ (BOOL)mainFastForwardCtrIdle;
+ (void)setMainFastForwardCtrIdle:(BOOL)enabled;

// Config > General
+ (BOOL)mainCpuThread;
+ (void)setMainCpuThread:(BOOL)enabled;
+ (BOOL)mainEnableCheats;
+ (void)setMainEnableCheats:(BOOL)enabled;
+ (BOOL)mainOverrideRegionSettings;
+ (void)setMainOverrideRegionSettings:(BOOL)enabled;
+ (BOOL)mainAutoDiscChange;
+ (void)setMainAutoDiscChange:(BOOL)enabled;
+ (BOOL)mainFastDiscSpeed;
+ (void)setMainFastDiscSpeed:(BOOL)enabled;
+ (BOOL)mainDSPThread;
+ (void)setMainDSPThread:(BOOL)enabled;
+ (NSInteger)mainFallbackRegion;
+ (void)setMainFallbackRegion:(NSInteger)regionRaw;
+ (NSInteger)mainEmulationSpeedPercent;
+ (void)setMainEmulationSpeedPercent:(NSInteger)percent;

// Controllers > Touchscreen (iOS)
+ (float)mainTouchPadOpacity;
+ (void)setMainTouchPadOpacity:(float)opacity;
+ (NSInteger)mainTouchPadIRMode;
+ (void)setMainTouchPadIRMode:(NSInteger)mode;

// Config > Advanced
+ (NSInteger)mainCpuCore;
+ (void)setMainCpuCore:(NSInteger)core;
+ (BOOL)mainMMU;
+ (void)setMainMMU:(BOOL)enabled;
+ (BOOL)mainPauseOnPanic;
+ (void)setMainPauseOnPanic:(BOOL)enabled;
+ (BOOL)mainAccurateCpuCache;
+ (void)setMainAccurateCpuCache:(BOOL)enabled;
+ (BOOL)mainDisableICache;
+ (void)setMainDisableICache:(BOOL)enabled;
// Cached Interpreter: block linking toggle

+ (BOOL)mainLowDCBZHack;
+ (void)setMainLowDCBZHack:(BOOL)enabled;
// Cached Interpreter: fast FP paths (experimental)
+ (BOOL)mainFpFast;
+ (void)setMainFpFast:(BOOL)enabled;
// Cached Interpreter: Apple-Silicon hot-loop software-prefetch (default on; A/B toggle)
+ (BOOL)mainCachedInterpreterPrefetch;
+ (void)setMainCachedInterpreterPrefetch:(BOOL)enabled;
+ (BOOL)mainOverclockEnable;
+ (void)setMainOverclockEnable:(BOOL)enabled;
+ (NSInteger)mainOverclockPercent;
+ (void)setMainOverclockPercent:(NSInteger)percent;
+ (BOOL)mainViOverclockEnable;
+ (void)setMainViOverclockEnable:(BOOL)enabled;
+ (NSInteger)mainViOverclockPercent;
+ (void)setMainViOverclockPercent:(NSInteger)percent;
+ (BOOL)mainRamOverrideEnable;
+ (void)setMainRamOverrideEnable:(BOOL)enabled;
+ (NSInteger)mainMem1SizeMB;
+ (void)setMainMem1SizeMB:(NSInteger)mb;
+ (NSInteger)mainMem2SizeMB;
+ (void)setMainMem2SizeMB:(NSInteger)mb;
+ (BOOL)mainCustomRtcEnable;
+ (void)setMainCustomRtcEnable:(BOOL)enabled;
+ (NSInteger)mainCustomRtcValue;
+ (void)setMainCustomRtcValue:(NSInteger)unixSeconds;

// Config > Interface
+ (BOOL)mainUseBuiltInTitleDatabase;
+ (void)setMainUseBuiltInTitleDatabase:(BOOL)enabled;
+ (BOOL)mainUseGameCovers;
+ (void)setMainUseGameCovers:(BOOL)enabled;
+ (BOOL)mainConfirmOnStop;
+ (void)setMainConfirmOnStop:(BOOL)enabled;
+ (BOOL)mainUsePanicHandlers;
+ (void)setMainUsePanicHandlers:(BOOL)enabled;
+ (BOOL)mainOSDMessages;
+ (void)setMainOSDMessages:(BOOL)enabled;

// Config > Audio
+ (NSArray<NSString*> *)audioBackends;
+ (NSString *)audioBackend;
+ (void)setAudioBackend:(NSString *)backend;
+ (NSInteger)audioVolume;
+ (void)setAudioVolume:(NSInteger)percent;
+ (BOOL)audioStretch;
+ (void)setAudioStretch:(BOOL)enabled;
+ (NSInteger)audioStretchLatencyMs;
+ (void)setAudioStretchLatencyMs:(NSInteger)ms;
+ (BOOL)audioMuteOnDisabledSpeedLimit;
+ (void)setAudioMuteOnDisabledSpeedLimit:(BOOL)enabled;
+ (BOOL)audioMuteSwitchObey;
+ (void)setAudioMuteSwitchObey:(BOOL)obey;

// Config > GameCube
+ (BOOL)mainSkipIPL;
+ (void)setMainSkipIPL:(BOOL)enabled;
+ (NSInteger)mainGCLanguage;
+ (void)setMainGCLanguage:(NSInteger)lang;
// YES if MAIN_GC_LANGUAGE has ever been explicitly persisted to the Base layer
// (i.e. the user picked a language). NO means the value is still the compiled
// default and the UI may derive a locale-based default instead. (Bug 6)
+ (BOOL)mainGCLanguageIsSet;

// Config > Wii (SYSCONF and MAIN)
+ (BOOL)sysconfPAL60;
+ (void)setSysconfPAL60:(BOOL)enabled;
+ (BOOL)sysconfScreensaver;
+ (void)setSysconfScreensaver:(BOOL)enabled;
+ (BOOL)mainWiiKeyboard;
+ (void)setMainWiiKeyboard:(BOOL)enabled;
+ (BOOL)mainWiiWiiLinkEnable;
+ (void)setMainWiiWiiLinkEnable:(BOOL)enabled;
+ (BOOL)mainWiiSDCard;
+ (void)setMainWiiSDCard:(BOOL)enabled;
+ (BOOL)mainAllowSDWrites;
+ (void)setMainAllowSDWrites:(BOOL)enabled;
+ (BOOL)mainWiiSDCardEnableFolderSync;
+ (void)setMainWiiSDCardEnableFolderSync:(BOOL)enabled;
+ (BOOL)sysconfWidescreen;
+ (void)setSysconfWidescreen:(BOOL)enabled;
+ (NSInteger)sysconfLanguage;
+ (void)setSysconfLanguage:(NSInteger)lang;
+ (NSInteger)sysconfSoundMode;
+ (void)setSysconfSoundMode:(NSInteger)mode;
+ (NSInteger)sysconfSensorBarPosition;
+ (void)setSysconfSensorBarPosition:(NSInteger)pos;
+ (NSInteger)sysconfSensorBarSensitivity;
+ (void)setSysconfSensorBarSensitivity:(NSInteger)sens;
+ (NSInteger)sysconfSpeakerVolume;
+ (void)setSysconfSpeakerVolume:(NSInteger)vol;
+ (BOOL)sysconfWiimoteMotor;
+ (void)setSysconfWiimoteMotor:(BOOL)enabled;

// RetroAchievements (Config + control)
#if USE_RETRO_ACHIEVEMENTS
+ (BOOL)raEnabled;
+ (void)setRaEnabled:(BOOL)enabled;
+ (NSString*)raUsername;
+ (void)setRaUsername:(NSString*)username;
+ (BOOL)raHardcoreEnabled;
+ (void)setRaHardcoreEnabled:(BOOL)enabled;
+ (BOOL)raUnofficialEnabled;
+ (void)setRaUnofficialEnabled:(BOOL)enabled;
+ (BOOL)raEncoreEnabled;
+ (void)setRaEncoreEnabled:(BOOL)enabled;
+ (BOOL)raSpectatorEnabled;
+ (void)setRaSpectatorEnabled:(BOOL)enabled;
+ (BOOL)raDiscordPresenceEnabled;
+ (void)setRaDiscordPresenceEnabled:(BOOL)enabled;
+ (BOOL)raProgressEnabled;
+ (void)setRaProgressEnabled:(BOOL)enabled;
+ (NSString*)raHostURL;
+ (void)setRaHostURL:(NSString*)url;
+ (BOOL)raHasAPIToken;
+ (void)raInit;
+ (void)raShutdown;
+ (void)raLogin:(NSString*)password;
+ (void)raLogout;
#endif

// Controllers > Types
+ (NSInteger)gcPortDeviceForPort:(NSInteger)portOneBased;
+ (void)setGCPortDeviceForPort:(NSInteger)portOneBased device:(NSInteger)device;
+ (NSInteger)wiimoteSourceForIndex:(NSInteger)indexOneBased;
+ (void)setWiimoteSourceForIndex:(NSInteger)indexOneBased source:(NSInteger)source;

// Graphics > Enhancements
+ (BOOL)gfxEnhanceForceTrueColor;
+ (void)setGfxEnhanceForceTrueColor:(BOOL)enabled;
+ (BOOL)gfxEnhanceDisableCopyFilter;
+ (void)setGfxEnhanceDisableCopyFilter:(BOOL)enabled;
+ (NSInteger)gfxEnhanceAnisotropySamples;
+ (void)setGfxEnhanceAnisotropySamples:(NSInteger)samples;

// Arbitrary mipmap detection
+ (BOOL)gfxEnhanceArbitraryMipmapDetection;
+ (void)setGfxEnhanceArbitraryMipmapDetection:(BOOL)enabled;
+ (float)gfxEnhanceArbitraryMipmapDetectionThreshold;
+ (void)setGfxEnhanceArbitraryMipmapDetectionThreshold:(float)threshold;
// HDR output
+ (BOOL)gfxEnhanceHDROutput;
+ (void)setGfxEnhanceHDROutput:(BOOL)enabled;

// Graphics > Hacks
+ (BOOL)gfxHackEfbAccessEnable;
+ (void)setGfxHackEfbAccessEnable:(BOOL)enabled;
+ (BOOL)gfxHackSkipEfbCopyToRam;
+ (void)setGfxHackSkipEfbCopyToRam:(BOOL)enabled;
+ (BOOL)gfxHackSkipXfbCopyToRam;
+ (void)setGfxHackSkipXfbCopyToRam:(BOOL)enabled;
+ (BOOL)gfxHackImmediateXfb;
+ (void)setGfxHackImmediateXfb:(BOOL)enabled;
+ (BOOL)gfxHackCopyEfbScaled;
+ (void)setGfxHackCopyEfbScaled:(BOOL)enabled;
+ (BOOL)gfxHackEfbEmulateFormatChanges;
+ (void)setGfxHackEfbEmulateFormatChanges:(BOOL)enabled;
+ (BOOL)gfxHackVertexRounding;
+ (void)setGfxHackVertexRounding:(BOOL)enabled;
+ (BOOL)gfxHackForceProgressive;
+ (void)setGfxHackForceProgressive:(BOOL)enabled;
+ (BOOL)gfxHackDeferEfbCopies;
+ (void)setGfxHackDeferEfbCopies:(BOOL)enabled;
// iCube: ARM64 NEON texture decoder (default on; A/B toggle)
+ (BOOL)gfxHackNeonTextureDecode;
+ (void)setGfxHackNeonTextureDecode:(BOOL)enabled;
+ (NSInteger)gfxHackViSkipMode;
+ (void)setGfxHackViSkipMode:(NSInteger)mode;
+ (BOOL)gfxHackViDecimateInterlace;
+ (void)setGfxHackViDecimateInterlace:(BOOL)enabled;
+ (BOOL)gfxHackFastTextureSampling;
+ (void)setGfxHackFastTextureSampling:(BOOL)enabled;
+ (BOOL)gfxHackFastMath;
+ (void)setGfxHackFastMath:(BOOL)enabled;
+ (BOOL)gfxUseComputeEfbXfb;
+ (void)setGfxUseComputeEfbXfb:(BOOL)enabled;
+ (BOOL)gfxHackNoMipmapping;
+ (void)setGfxHackNoMipmapping:(BOOL)enabled;
+ (BOOL)gfxHackEarlyXfbOutput;
+ (void)setGfxHackEarlyXfbOutput:(BOOL)enabled;
+ (BOOL)gfxHackSkipDuplicateXFBs;
+ (void)setGfxHackSkipDuplicateXFBs:(BOOL)enabled;

// Graphics > Advanced
// Performance Statistics
+ (BOOL)gfxShowFPS;
+ (void)setGfxShowFPS:(BOOL)enabled;
+ (BOOL)gfxShowVPS;
+ (void)setGfxShowVPS:(BOOL)enabled;
+ (BOOL)gfxShowSpeed;
+ (void)setGfxShowSpeed:(BOOL)enabled;
+ (BOOL)gfxShowFTimes;
+ (void)setGfxShowFTimes:(BOOL)enabled;
+ (BOOL)gfxShowVTimes;
+ (void)setGfxShowVTimes:(BOOL)enabled;
+ (BOOL)gfxShowGraphs;
+ (void)setGfxShowGraphs:(BOOL)enabled;
+ (BOOL)gfxLogRenderTimeToFile;
+ (void)setGfxLogRenderTimeToFile:(BOOL)enabled;
+ (BOOL)gfxShowSpeedColors;
+ (void)setGfxShowSpeedColors:(BOOL)enabled;

// Debugging
+ (BOOL)gfxOverlayStats;
+ (void)setGfxOverlayStats:(BOOL)enabled;
+ (BOOL)gfxEnableValidationLayer;
+ (void)setGfxEnableValidationLayer:(BOOL)enabled;

// Utility
+ (BOOL)gfxHiresTextures;
+ (void)setGfxHiresTextures:(BOOL)enabled;
+ (BOOL)gfxCacheHiresTextures;
+ (void)setGfxCacheHiresTextures:(BOOL)enabled;
+ (BOOL)gfxHackDisableCopyToVRAM;
+ (void)setGfxHackDisableCopyToVRAM:(BOOL)enabled;
+ (BOOL)gfxModsEnable;
+ (void)setGfxModsEnable:(BOOL)enabled;

// Misc
+ (BOOL)gfxCrop;
+ (void)setGfxCrop:(BOOL)enabled;
+ (BOOL)sysconfProgressiveScan;
+ (void)setSysconfProgressiveScan:(BOOL)enabled;

// Shader Threads
+ (NSInteger)gfxShaderCompilerThreads;
+ (void)setGfxShaderCompilerThreads:(NSInteger)value;
+ (NSInteger)gfxShaderPrecompilerThreads;
+ (void)setGfxShaderPrecompilerThreads:(NSInteger)value;

// Experimental
+ (BOOL)gfxHackEfbDeferInvalidation;
+ (void)setGfxHackEfbDeferInvalidation:(BOOL)enabled;

// Rendering (existing advanced toggles)
+ (BOOL)gfxFastDepthCalc;
+ (void)setGfxFastDepthCalc:(BOOL)enabled;
+ (BOOL)gfxEnablePixelLighting;
+ (void)setGfxEnablePixelLighting:(BOOL)enabled;
+ (BOOL)gfxBackendMultithreading;
+ (void)setGfxBackendMultithreading:(BOOL)enabled;
+ (BOOL)gfxShaderCache;
+ (void)setGfxShaderCache:(BOOL)enabled;
+ (BOOL)gfxSaveTextureCacheToState;
+ (void)setGfxSaveTextureCacheToState:(BOOL)enabled;
+ (BOOL)gfxPreferVSForLinePointExpansion;
+ (void)setGfxPreferVSForLinePointExpansion:(BOOL)enabled;
+ (BOOL)gfxCpuCull;
+ (void)setGfxCpuCull:(BOOL)enabled;

+ (void)resetAllToDefaults NS_SWIFT_NAME(resetAllToDefaults());
+ (void)resetPageToDefaults:(NSInteger)page NS_SWIFT_NAME(resetPage(toDefaults:)); // 0=config, 1=graphics, 2=controllers, 3=debug, 4=about

+ (NSArray<NSString*>*)audioBackendsForPicker;

// Main.EmulatedUSBDevices (subset for iOS)
+ (BOOL)mainEmulateSkylanderPortal;
+ (void)setMainEmulateSkylanderPortal:(BOOL)enabled;
+ (NSInteger)skylanderLoadFromPath:(NSString*)path;
+ (BOOL)skylanderRemoveAtSlot:(NSInteger)slot;
+ (void)skylanderClearAll;

// DSU (Cemuhook DualShock UDP) Client Settings
// Enable/disable DSU client backend in ControllerInterface
+ (BOOL)dsuClientEnabled;
+ (void)setDsuClientEnabled:(BOOL)enabled;
// Raw servers string (format: "desc:address:port;...")
+ (NSString*)dsuServersString;
+ (void)setDsuServersString:(NSString*)servers;
// Parsed helpers for Swift UI
+ (NSArray<NSDictionary<NSString*, id>*>*)dsuServersParsed; // keys: description, address, port(NSNumber)
+ (void)addDsuServer:(NSString*)desc address:(NSString*)address port:(NSInteger)port;
+ (void)removeDsuServerAtIndex:(NSInteger)index;
// Debug metrics
+ (NSUInteger)dsuClientRxCount;

@end

NS_ASSUME_NONNULL_END
