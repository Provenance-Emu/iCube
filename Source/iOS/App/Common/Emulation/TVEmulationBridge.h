// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

@class EmulationBootParameter;
@class UIView;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TVDiscChangeResult) {
  TVDiscChangeResultScheduled,
  TVDiscChangeResultFileUnavailable,
  TVDiscChangeResultInvalidDisc,
  TVDiscChangeResultIncompatibleSystem,
  TVDiscChangeResultNoRunningGame,
  TVDiscChangeResultPendingInsertion,
};

/// Identity captured with the serialized state, returned only after its file has been committed.
@interface TVSaveStateSnapshot : NSObject
@property (nonatomic, readonly, copy) NSString* filePath;
@property (nonatomic, readonly, copy) NSString* gameID;
@property (nonatomic, readonly) NSInteger playTimeSeconds;
@property (nonatomic, readonly, copy) NSDate* savedAt;
@property (nonatomic, readonly) uint64_t sessionIdentifier;
@end

@interface TVEmulationBridge : NSObject

+ (void)runWithBootParameter:(EmulationBootParameter*)param;
+ (void)stop;
/// User Quit: a failed enabled auto-save leaves the session running and returns NO.
/// A nonnil path must come from a successful save snapshot; it is copied to auto instead of serialized twice.
+ (BOOL)stopForUserWithSavedStatePath:(nullable NSString*)savedStatePath NS_SWIFT_NAME(stopForUser(savedStatePath:));
+ (BOOL)stopForUserWithSavedStatePath:(nullable NSString*)savedStatePath expectedGameID:(nullable NSString*)expectedGameID NS_SWIFT_NAME(stopForUser(savedStatePath:expectedGameID:));
+ (BOOL)stopForUserWithSavedStatePath:(nullable NSString*)savedStatePath expectedGameID:(nullable NSString*)expectedGameID expectedSessionIdentifier:(uint64_t)session NS_SWIFT_NAME(stopForUser(savedStatePath:expectedGameID:expectedSessionIdentifier:));
+ (uint64_t)currentSessionIdentifier;
/// Explicit user recovery, or programmatic stop after its own save policy has run.
+ (void)stopWithoutSaving;
+ (BOOL)stopWithoutSavingForUserExpectedSessionIdentifier:(uint64_t)session NS_SWIFT_NAME(stopWithoutSavingForUser(expectedSessionIdentifier:));
+ (BOOL)isRunning;
+ (void)pause;
+ (void)resume;
/// Non-blocking pause/resume for the app-inactive transition (PauseArbiter only): the SetState runs on the
/// host queue, so the main thread never waits for the CPU thread there. A pause or resume made after
/// the request supersedes it if it has not run yet.
+ (void)pauseAsync;
+ (void)resumeAsync;
+ (BOOL)isPaused;
/// True while a `pauseAsync` / `resumeAsync` is still waiting on the host queue or inside its state change.
+ (BOOL)hasQueuedPauseRequest;
/// The console's reset button: the running game restarts from power-on. Resumes a paused core,
/// because a reset only takes effect while the CPU runs. No-op when nothing is running.
+ (void)resetSystem;
/// Validates a local disc and queues the console's eject/insert events without rebooting.
/// Keeps a paused core paused; insertion completes after the caller resumes through PauseArbiter.
+ (TVDiscChangeResult)changeDiscAtPath:(NSString*)path NS_SWIFT_NAME(changeDisc(atPath:));

// Convenience wrappers for Swift
// Launch a game file at path; sensible defaults applied.
// Path should point to a GameCube/Wii image supported by Dolphin.
// Returns immediately; emulation runs on background thread.
+ (void)launchGameAtPath:(NSString*)path;
// Register the main display UIView that will host the Metal surface.
+ (void)registerMainDisplayView:(UIView*)view;

// Savestates
// Returns YES only after the state worker committed this save. `wait` remains for source compatibility.
+ (BOOL)saveStateToSlot:(NSInteger)slot wait:(BOOL)wait;
+ (nullable TVSaveStateSnapshot*)saveStateSnapshotToSlot:(NSInteger)slot NS_SWIFT_NAME(saveStateSnapshot(toSlot:));
+ (nullable TVSaveStateSnapshot*)saveStateSnapshotToSlot:(NSInteger)slot expectedGameID:(nullable NSString*)expectedGameID NS_SWIFT_NAME(saveStateSnapshot(toSlot:expectedGameID:));
+ (nullable TVSaveStateSnapshot*)saveStateSnapshotToSlot:(NSInteger)slot expectedGameID:(nullable NSString*)expectedGameID expectedSessionIdentifier:(uint64_t)session NS_SWIFT_NAME(saveStateSnapshot(toSlot:expectedGameID:expectedSessionIdentifier:));
/// UI slot consent: rechecks captured path and actual occupancy under the core guard. Nil path is legacy overwrite.
+ (nullable TVSaveStateSnapshot*)saveStateSnapshotToSlot:(NSInteger)slot expectedGameID:(nullable NSString*)expectedGameID expectedSessionIdentifier:(uint64_t)session expectedPath:(nullable NSString*)expectedPath allowOverwrite:(BOOL)allowOverwrite NS_SWIFT_NAME(saveStateSnapshot(toSlot:expectedGameID:expectedSessionIdentifier:expectedPath:allowOverwrite:));
/// Unique history paths only; validates identity and StateSaves containment under the core guard.
+ (nullable TVSaveStateSnapshot*)saveStateSnapshotToPath:(NSString*)path expectedGameID:(NSString*)expectedGameID expectedSessionIdentifier:(uint64_t)session NS_SWIFT_NAME(saveStateSnapshot(toPath:expectedGameID:expectedSessionIdentifier:));
// YES while the core can take a save or load (running, including a user pause).
+ (BOOL)isStateOperationAllowed;
+ (void)loadStateFromSlot:(NSInteger)slot;

// Save-state identity / paths.
// Authoritative values from the core, used by the Swift save-manager to name
// metadata/thumbnail sidecars consistently with the files Core/State.cpp writes.
// currentGameID is the running title's ID ("" if nothing is running).
// stateFilePathForSlot mirrors Core/State.cpp MakeStateFilename ("{dir}{GameID}.s{NN}");
// returns nil when no game is running.
+ (NSString*)currentGameID;
+ (nullable NSString*)stateFilePathForSlot:(NSInteger)slot;

// Running title's cumulative play time (TimePlayed.ini via Core/TimePlayed.h),
// in whole seconds. The core's "Play Time Tracker" thread (CPUManager, gated
// by Config::MAIN_TIME_TRACKING, default on) flushes to the ini in <= 30s
// increments while running, so this can lag the true elapsed time by up to
// ~30s. 0 when nothing is running or tracking is disabled. Used to stamp
// SaveStateMetadata.playTimeSeconds at save time (see SaveStateService).
+ (NSInteger)currentGamePlayTimeSeconds;

// Resume / auto-state. A dedicated "{StateSavesDir}{GameID}.auto" file, separate
// from the numbered slots, used by "resume where I left off". Uses State::SaveAs/
// LoadAs directly so it never collides with the slot scheme. autoStateFilePath
// returns nil when no game is running, and for a boot of a GameMod descriptor
// (a patched game shares the vanilla game's id, so it never resumes).
+ (nullable NSString*)autoStateFilePath;
+ (BOOL)saveStateToPath:(NSString*)path wait:(BOOL)wait;
+ (void)loadStateFromPath:(NSString*)path;
/// YES means requested, not completed. The queued job rechecks identity before loading.
+ (BOOL)loadStateFromPath:(NSString*)path expectedGameID:(NSString*)expectedGameID expectedSessionIdentifier:(uint64_t)session NS_SWIFT_NAME(loadState(fromPath:expectedGameID:expectedSessionIdentifier:));

// Returns YES if the state file at path was written by a build whose save format
// matches the running build (header SCM revision == current). Conservative: a
// genuinely-loadable cross-revision state may report NO. NO if the file is missing
// or its header can't be read.
+ (BOOL)stateFileIsCompatibleAtPath:(NSString*)path;

// Request a screenshot PNG be written to path. Backend-agnostic (goes through
// Dolphin's FrameDumper, not the Metal layer). ASYNCHRONOUS and non-blocking:
// the capture lands on the next presented frame, so if emulation is paused or
// stopping there may be no frame and no file is written (callers must tolerate a
// missing thumbnail). Used to capture save-state thumbnails at save time.
+ (void)captureScreenshotToPath:(NSString*)path;

// Speed / Fast-forward
// Toggle temporary throttler disable (turbo). Returns the new state.
// Overscan compensation (external display on iOS, main TV on tvOS)
+ (BOOL)isOverscanCompensationApplicable;
+ (BOOL)overscanFullscreenEnabled;
+ (void)setOverscanFullscreenEnabled:(BOOL)enabled;

// Display / Orientation
+ (void)resizeSurfaceNow;
+ (void)reloadShadersNow;
// Speed / Fast-forward
// Toggle temporary throttler disable (turbo). Returns the new state.
+ (BOOL)toggleFastForward;
+ (BOOL)isFastForwardEnabled;
// Persists `percent` under the shared "fast_forward_speed_percent" UserDefaults key
// (0 = unlimited) and, if fast-forward is already running, re-applies it live so a
// speed change does not require toggling off and back on. Does not itself enable
// fast-forward; call -toggleFastForward for that when -isFastForwardEnabled is NO.
+ (void)setFastForwardSpeedPercent:(NSInteger)percent;

// Pause-menu quick settings. Both read/write Dolphin's current-run config layer, so they apply live
// (EFB scale on the next frame) and are not persisted by themselves.
// Internal resolution: Config::GFX_EFB_SCALE (0 = auto, 1 = native, 2 = 2x, ...).
+ (NSInteger)internalResolution;
+ (void)setInternalResolution:(NSInteger)scale;
// Audio volume as a 0...100 percentage: Config::MAIN_AUDIO_VOLUME.
+ (NSInteger)audioVolumePercent;
+ (void)setAudioVolumePercent:(NSInteger)percent;

// System Detection
+ (BOOL)isCurrentSystemWii;
+ (float)currentDrawAspectRatio;
// Enables/disables the emulated Wiimote's own IMUPoint group so it stops fighting with the
// app's own touch/gyro IR. `wiimote` is the zero-based Wii Remote slot (0-3). Callers acting
// for the on-screen overlay pass `ControllerManager.shared.touchscreenSlot(system: .wii)` and
// do nothing when it is nil: falling back to 0 would switch a physical Wii Remote 1's pointer
// off. Enabling is refused on a slot bound to the Touchscreen (the group stays off there).
+ (void)setWiiIMUPointEnabled:(BOOL)enabled forWiimote:(NSInteger)wiimote;

// Video Geometry
// Returns the current video content rect in the coordinate space of the registered main display view.
+ (CGRect)currentVideoContentRect;

@end

NS_ASSUME_NONNULL_END
