// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bridge exposing core state, frame stepping, screenshot capture, save states,
/// render/build info, and log tail access to the debug API (Swift/ObjC).
@interface DOLDebugBridge : NSObject

/// Current core state: "uninitialized" | "starting" | "running" | "paused" | "stopping".
+ (NSString*)coreState;

/// Pauses the running core. Returns NO if the core is not running.
+ (BOOL)pause;
/// Resumes the paused core. Returns NO if the core is not running.
+ (BOOL)resume;

/// Frame-steps the (paused) core up to `n` frames, waiting for each step to land
/// (bounded by `timeout` seconds per step). Returns the number of frames actually
/// advanced, which is less than `n` on timeout.
+ (NSInteger)frameAdvance:(NSInteger)n timeoutSeconds:(double)timeout;

/// The emulated frame counter (`MovieManager::GetCurrentFrame`).
+ (uint64_t)frameCount;

/// Captures a screenshot and returns its PNG bytes, waiting up to `timeout` seconds
/// for the async screenshot write to land. Returns nil on timeout or if not running.
+ (nullable NSData*)screenshotPNGWithTimeout:(double)timeout;

+ (BOOL)loadStateSlot:(NSInteger)slot;
+ (BOOL)loadStatePath:(NSString*)path;
+ (BOOL)saveStateSlot:(NSInteger)slot;

/// FIFO recording (Dolphin FifoRecorder). Records `frames` frames of GPU commands + the memory
/// they reference and saves a .dff to `path` when done; `fifoRecordStatus` reports progress.
/// A .dff plays back in any Dolphin FIFO player, so a phone recording replayed on a Mac tells
/// GPU-input bugs (recording already wrong) from GPU-output bugs (recording right, phone wrong).
+ (BOOL)fifoRecordStart:(NSInteger)frames path:(NSString*)path;
+ (NSDictionary<NSString*, id>*)fifoRecordStatus;

/// Interpreter FP self-test (Core/PowerPC/Interpreter/FPUSelfTest.h): fixed inputs through the
/// FP primitives under three host FPCR modes, one hex line per result. Runs on the calling thread.
+ (NSString*)fpuSelfTest;
/// Top-N guest hot blocks from the cached interpreter's block profiler (needs Main.Core.CIRProfile=true at boot).
+ (NSString*)hotBlocksReport:(NSInteger)topN;

/// Gather-pipe store self-test (CachedInterpreter.h, CIRSelfTest::RunGatherPipeSelfTest): drives the
/// shipping fused-copy byte kernel and an independent transcription of GPFifoManager::Write8 over the
/// same input on a scratch pipe and diffs FIFO bursts, per-store pipe pointer and GPR writes. Pure:
/// touches no live emulation state, so it is safe to call with or without a game running.
+ (NSString*)gatherPipeSelfTest;

/// A snapshot of render-relevant config/state.
+ (NSDictionary<NSString*, id>*)renderState;
/// Build/version info (SCM revision, branch, app version/build, configuration).
+ (NSDictionary<NSString*, id>*)buildInfo;
/// The last `count` log lines captured by the debug log ring.
+ (NSArray<NSString*>*)logTail:(NSInteger)count;

/// Invoked (on an unspecified thread) whenever a Dolphin `Config` value changes.
+ (void)setConfigChangedHandler:(nullable void (^)(void))handler;
/// Invoked (on an unspecified thread) for warning/error/notice level log lines.
+ (void)setLogHandler:(nullable void (^)(NSString* level, NSString* message))handler;
/// Invoked (on an unspecified thread) whenever the core's `Core::State` changes.
+ (void)setCoreStateHandler:(nullable void (^)(NSString* state))handler;

@end

NS_ASSUME_NONNULL_END
