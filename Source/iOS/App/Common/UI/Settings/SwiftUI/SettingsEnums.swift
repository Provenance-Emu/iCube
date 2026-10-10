// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

// MARK: - Graphics enums

enum GraphicsBackend: CaseIterable { case metal, opengl, vulkan
  var label: String { switch self { case .metal: return L("Metal"); case .opengl: return L("OpenGL"); case .vulkan: return L("Vulkan") } }
  var backendKey: String { switch self { case .metal: return "Metal"; case .opengl: return "OGL"; case .vulkan: return "Vulkan" } }
  static func from(key: String) -> GraphicsBackend { switch key.lowercased() { case "ogl", "opengl": return .opengl; case "vulkan": return .vulkan; default: return .metal } }
}

enum AspectRatio: CaseIterable { case auto, stretch, _4_3, _16_9
  var label: String { switch self { case .auto: return L("Auto"); case .stretch: return L("Stretch to Window"); case ._4_3: return "4:3"; case ._16_9: return "16:9" } }
  var aspectRaw: Int { switch self { case .auto: return 0; case .stretch: return 3; case ._4_3: return 2; case ._16_9: return 1 } }
  static func from(raw: Int) -> AspectRatio { switch raw { case 1: return ._16_9; case 2: return ._4_3; case 3: return .stretch; default: return .auto } }
}

enum TargetFPS: CaseIterable { case unlimited, fps30, fps60, fps120
  var label: String { switch self { case .unlimited: return L("Unlimited"); case .fps30: return "30"; case .fps60: return "60"; case .fps120: return "120" } }
  var fpsValue: Int { switch self { case .unlimited: return 0; case .fps30: return 30; case .fps60: return 60; case .fps120: return 120 } }
  static func from(value: Int) -> TargetFPS { switch value { case 30: return .fps30; case 120: return .fps120; case 0: return .unlimited; default: return .fps60 } }
}

// Auto Internal Resolution min/max bounds. The core stores these as an integer EFB
// multiplier and clamps to >= 1 (AutoIRController.cpp), so only whole scales are valid.
// The old fractional options (0.5x/0.75x/1.25x/1.5x) all collapsed to 0 -> read back
// as 1.0x, i.e. they "self-reset"; they are dropped.
enum InternalScale: Int, CaseIterable { case x1_0 = 1, x2_0 = 2, x3_0 = 3, x4_0 = 4
  var label: String { switch self {
  case .x1_0: return "1x"
  case .x2_0: return "2x"
  case .x3_0: return "3x"
  case .x4_0: return "4x"
  }}
  var scaleValue: Int { rawValue }
  static func from(value: Int) -> InternalScale { InternalScale(rawValue: value) ?? .x1_0 }
}

// Mirrors Dolphin's ShaderCompilationMode (VideoConfig.h): Synchronous(0) is the
// "Specialized" mode in Dolphin's own UI; raw values must match the core 1:1 or the
// picker reads back a different option than it stored ("self-reset").
enum ShaderCompileType: CaseIterable { case specialized, exclusiveUber, hybridUber, skipDrawing
  var label: String { switch self {
  case .specialized: return L("Specialized")
  case .exclusiveUber: return L("Exclusive Ubershaders")
  case .hybridUber: return L("Hybrid Ubershaders")
  case .skipDrawing: return L("Skip Drawing")
  } }
  var modeRaw: Int { switch self { case .specialized: return 0; case .exclusiveUber: return 1; case .hybridUber: return 2; case .skipDrawing: return 3 } }
  static func from(raw: Int) -> ShaderCompileType { switch raw { case 1: return .exclusiveUber; case 2: return .hybridUber; case 3: return .skipDrawing; default: return .specialized } }
}

// MARK: - CPU engine

// Raw values MUST match PowerPC::CPUCore (PowerPC.h): Interpreter=0, JIT64=1,
// JITARM64=4, CachedInterpreter=5. The enum is gapped (2 and 3 are retired cores),
// so naive sequential raw values would write/read the wrong core — e.g. a stored
// Cached Interpreter (5) would read back as JIT, and selecting Cached Interpreter
// would actually store JIT64. Declaration order (not raw value) drives the picker
// display order, so the user-facing list is unchanged.
enum CpuEngine: Int, CaseIterable {
  case interpreter = 0
  case cachedInterpreter = 5
  case cachedInterpreterIR = 6
  case jit64 = 1
  case jitARM64 = 4
  var label: String {
    switch self {
    case .interpreter: return L("Interpreter (slowest)")
    // "(slower)" was upstream's wording relative to the JIT, which non-jailbroken iOS never gets;
    // on device this engine measured ~1.7x faster than the IR one (2026-09-16 A/B).
    case .cachedInterpreter: return L("Cached Interpreter (recommended)")
    case .cachedInterpreterIR: return L("Cached Interpreter IR (experimental, usually slower)")
    case .jit64: return L("JIT Recompiler for x86-64 (recommended)")
    case .jitARM64: return L("JIT Recompiler for ARM64 (recommended)")
    }
  }
  static func from(raw: Int) -> CpuEngine { CpuEngine(rawValue: raw) ?? .jitARM64 }
}
