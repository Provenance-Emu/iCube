// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

// TARGET PATH (when integrated):
//   Source/iOS/App/Common/Bridging/DOLPerfBridge.mm

#import "DOLPerfBridge.h"

#import <Foundation/Foundation.h>

// C++ includes
#include "VideoCommon/PerformanceMetrics.h"

@implementation DOLPerfBridge

+ (NSDictionary<NSString*, NSNumber*>*)snapshot {
  // g_perf_metrics is the global instance declared at the bottom of
  // PerformanceMetrics.h. Its getters are atomic / any-thread-safe, so no
  // locking or main-thread hop is needed here.
  const double fps = g_perf_metrics.GetFPS();
  const double vps = g_perf_metrics.GetVPS();
  const double speed = g_perf_metrics.GetSpeed();
  const double maxSpeed = g_perf_metrics.GetMaxSpeed();

  // frameTimeMs is *derived* from the smoothed FPS — average frame time, not a
  // per-frame dt. Kept for backwards compatibility / a quick smoothed read.
  const double frameTimeMs = (fps > 0.0) ? (1000.0 / fps) : 0.0;

  // rawFrameTimeMs is the last raw per-frame delta (PerformanceMetrics core
  // accessor added for this bench). The benchmark samples THIS at display rate
  // and de-dups on change to build a true frame-time distribution / 1%-low.
  const double rawFrameTimeMs = g_perf_metrics.GetLastRawFrameTimeMs();

  return @{
    @"fps" : @(fps),
    @"vps" : @(vps),
    @"speed" : @(speed),
    @"maxSpeed" : @(maxSpeed),
    @"frameTimeMs" : @(frameTimeMs),
    @"rawFrameTimeMs" : @(rawFrameTimeMs),
  };
}

@end
