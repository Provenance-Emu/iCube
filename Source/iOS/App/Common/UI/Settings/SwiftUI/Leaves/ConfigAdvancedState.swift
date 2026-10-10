// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

enum ConfigAdvancedLimits {
  static let mem1MB: ClosedRange<Double> = 24 ... 64
  static let mem2MB: ClosedRange<Double> = 64 ... 128
  /// 2000-01-01 UTC: what the old view showed for an RTC that was never set.
  static let defaultRtcSeconds: TimeInterval = 946_684_800
}

/// Snapshot of Config for the Advanced screen. Defaults match the old view's `@State` defaults.
struct ConfigAdvancedState: Equatable {
  var memOverride = false
  var mem1MB = 24
  var mem2MB = 64
  var rtcEnabled = false
  var rtcDate = Date(timeIntervalSince1970: ConfigAdvancedLimits.defaultRtcSeconds)
}

/// One user edit. The host applies it to its snapshot AND to Config; the builder only emits it.
enum ConfigAdvancedChange: Equatable {
  case memOverride(Bool)
  case mem1MB(Int)
  case mem2MB(Int)
  case rtcEnabled(Bool)
  case rtcDate(Date)
}
