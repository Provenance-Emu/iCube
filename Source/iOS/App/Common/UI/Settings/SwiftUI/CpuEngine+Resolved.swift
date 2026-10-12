// Common/UI/Settings/SwiftUI/CpuEngine+Resolved.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

extension CpuEngine {
  /// The engine that actually runs. A stored JIT engine runs as the Cached Interpreter when JIT was not acquired
  /// (mirrors `PerformanceTuningState.effectiveEngine`).
  static func resolved(stored: CpuEngine, acquiredJit: Bool) -> CpuEngine {
    if !acquiredJit && (stored == .jit64 || stored == .jitARM64) { return .cachedInterpreter }
    return stored
  }

  /// Compact label for pause-menu badges.
  var shortName: String {
    switch self {
    case .interpreter: return "INT"
    case .cachedInterpreter: return "CIR"
    case .cachedInterpreterIR: return "CIR-IR"
    case .jit64, .jitARM64: return "JIT"
    }
  }
}
