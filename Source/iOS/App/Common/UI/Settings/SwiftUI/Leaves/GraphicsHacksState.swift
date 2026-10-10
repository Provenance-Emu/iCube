// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Snapshot of Config for the Hacks screen. Defaults match the old view's `@State` defaults.
struct GraphicsHacksState: Equatable {
  var textureCacheSamples = 128
  var bboxEnabled = false
  var bboxSyncMode = 0
  var backendSupportsBbox = true
  var efbAccess = false
  var skipEfbToRam = true
  var skipXfbToRam = true
  var immediateXfb = false
  var copyEfbScaled = true
  var earlyXfbOutput = true
  var skipDuplicateXFBs = true
  var efbFormatChanges = false
  var vertexRounding = false
  var forceProgressive = true
  var deferEfbCopies = true
  var viSkipMode = 2
  var fastTextureSampling = true
  var fastMath = true
  var useComputeEfbXfb = false
  var useComputeVertexDecode = false
  var noMipmapping = false
  var gpuEfbPeekResolve = false
  var viDecimateInterlace = false

  /// The Safe/Default/Fast ladder: any stored value other than 512 or 0 shows as Default (128), never a dash.
  static func normalizedTextureCacheSamples(_ samples: Int) -> Int {
    switch samples {
    case 512, 0: return samples
    default: return 128
    }
  }
}

/// One user edit. The host applies it to its snapshot AND to Config; the builder only emits it.
enum GraphicsHacksChange: Equatable {
  case textureCacheSamples(Int)
  case bboxEnabled(Bool)
  case bboxSyncMode(Int)
  case efbAccess(Bool)
  case skipEfbToRam(Bool)
  case skipXfbToRam(Bool)
  case immediateXfb(Bool)
  case copyEfbScaled(Bool)
  case earlyXfbOutput(Bool)
  case skipDuplicateXFBs(Bool)
  case efbFormatChanges(Bool)
  case vertexRounding(Bool)
  case forceProgressive(Bool)
  case deferEfbCopies(Bool)
  case viSkipMode(Int)
  case fastTextureSampling(Bool)
  case fastMath(Bool)
  case useComputeEfbXfb(Bool)
  case useComputeVertexDecode(Bool)
  case noMipmapping(Bool)
  case gpuEfbPeekResolve(Bool)
  case viDecimateInterlace(Bool)
}
