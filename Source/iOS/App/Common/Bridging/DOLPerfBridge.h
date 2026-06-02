// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

// TARGET PATH (when integrated):
//   Source/iOS/App/Common/Bridging/DOLPerfBridge.h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Read-only bridge surfacing Dolphin's global `g_perf_metrics`
/// (`VideoCommon/PerformanceMetrics.h`) to Swift/ObjC.
///
/// All underlying getters are documented as callable from any thread
/// (PerformanceMetrics.h:40 — "Getter Functions. May be called from any
/// thread."), so `+snapshot` is safe to call off the main thread. No
/// `@MainActor` hop is required for reads.
@interface DOLPerfBridge : NSObject

/// A point-in-time snapshot of the emulator's performance counters.
///
/// Keys (all `NSNumber`, never nil):
///  - `fps`            : rendered frames per second (`GetFPS`)
///  - `vps`            : vblanks per second (`GetVPS`)
///  - `speed`          : emulation speed as a ratio, 1.0 == 100% (`GetSpeed`)
///  - `maxSpeed`       : achievable speed ratio w/o throttle (`GetMaxSpeed`)
///  - `frameTimeMs`    : derived as `1000.0 / fps` (0 when fps == 0).
///                       Average frame time implied by the *smoothed* FPS.
///  - `rawFrameTimeMs` : last raw per-frame dt in ms
///                       (`GetLastRawFrameTimeMs`, atomic, any thread). This is
///                       the per-frame value the benchmark samples to compute a
///                       genuine 1%-low (vs the smoothed `frameTimeMs`).
+ (NSDictionary<NSString*, NSNumber*>*)snapshot;

@end

NS_ASSUME_NONNULL_END
