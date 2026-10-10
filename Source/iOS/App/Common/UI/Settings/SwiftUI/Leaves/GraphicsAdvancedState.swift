// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Metal TriState knobs (present-drawable, manual-upload); raw values are what Config stores.
enum MetalTriState: Int, CaseIterable {
  case off = 0
  case on = 1
  case auto = 2
}

/// Every Bool setting on the screen, named like the old `@State` var. One case per row keeps `Change` from growing 24 cases.
enum GraphicsAdvancedFlag: CaseIterable {
  case showFPS, showVPS, showSpeed, showFrameTimes, showVBlankTimes, showGraphs, logRenderTime, speedColors
  case overlayStats, validationLayer
  case hiresTextures, prefetchTextures, disableEfbToVRAM, graphicsMods
  case cropPicture, progressiveScan
  case fastDepth, pixelLighting, backendMT, shaderCache, saveTexCache, preferVSForLines, cpuCull
  case deferEfbInvalidation

  var keyPath: WritableKeyPath<GraphicsAdvancedState, Bool> {
    switch self {
    case .showFPS: return \.showFPS
    case .showVPS: return \.showVPS
    case .showSpeed: return \.showSpeed
    case .showFrameTimes: return \.showFrameTimes
    case .showVBlankTimes: return \.showVBlankTimes
    case .showGraphs: return \.showGraphs
    case .logRenderTime: return \.logRenderTime
    case .speedColors: return \.speedColors
    case .overlayStats: return \.overlayStats
    case .validationLayer: return \.validationLayer
    case .hiresTextures: return \.hiresTextures
    case .prefetchTextures: return \.prefetchTextures
    case .disableEfbToVRAM: return \.disableEfbToVRAM
    case .graphicsMods: return \.graphicsMods
    case .cropPicture: return \.cropPicture
    case .progressiveScan: return \.progressiveScan
    case .fastDepth: return \.fastDepth
    case .pixelLighting: return \.pixelLighting
    case .backendMT: return \.backendMT
    case .shaderCache: return \.shaderCache
    case .saveTexCache: return \.saveTexCache
    case .preferVSForLines: return \.preferVSForLines
    case .cpuCull: return \.cpuCull
    case .deferEfbInvalidation: return \.deferEfbInvalidation
    }
  }
}

/// Snapshot of Config for the Graphics Advanced screen. Defaults match the old view's `@State` defaults.
struct GraphicsAdvancedState: Equatable {
  var showFPS = false
  var showVPS = false
  var showSpeed = false
  var showFrameTimes = false
  var showVBlankTimes = false
  var showGraphs = false
  var logRenderTime = false
  var speedColors = false
  var overlayStats = false
  var validationLayer = false
  var hiresTextures = false
  var prefetchTextures = false
  var disableEfbToVRAM = false
  var graphicsMods = false
  var cropPicture = false
  var progressiveScan = false
  var fastDepth = true
  var pixelLighting = false
  var backendMT = true
  var shaderCache = true
  var saveTexCache = false
  var preferVSForLines = false
  var cpuCull = false
  var deferEfbInvalidation = false
  var compilerThreads = 1
  var precompilerThreads = 1
  var maxThreads = 2
  var usePresentDrawable = MetalTriState.auto.rawValue
  var manuallyUploadBuffers = MetalTriState.auto.rawValue
  /// Total size of the installed custom texture packs. The host measures it off the main thread (`TexturePackSize`) and
  /// `sync()` carries it forward, so a Config resync does not wipe it.
  var texturePackBytes: Int64 = 0
  var physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory

  /// Prefetch keeps every texture of a pack resident, and the core lets that cache reach half of RAM (CustomAssetCache);
  /// next to the emulator itself, a pack above a quarter of RAM risks a memory kill, so warn from there.
  static let prefetchWarningRAMDivisor: UInt64 = 4

  static func isTooLargeToPrefetch(bytes: Int64, physicalMemory: UInt64) -> Bool {
    bytes > 0 && UInt64(bytes) > physicalMemory / prefetchWarningRAMDivisor
  }

  /// Only worth showing while the packs load and prefetch is on: otherwise nothing is held in memory.
  var showsTexturePackWarning: Bool {
    hiresTextures && prefetchTextures && Self.isTooLargeToPrefetch(bytes: texturePackBytes, physicalMemory: physicalMemory)
  }

  /// One core is left to the emulator; the rest may compile shaders. Never below 1.
  static func maxThreads(forProcessorCount count: Int) -> Int {
    max(1, max(2, count) - 1)
  }

  /// Unset (0) or negative is the default of two threads (or fewer on a small device).
  static func threadCount(stored: Int, maxThreads: Int) -> Int {
    stored <= 0 ? min(2, maxThreads) : stored
  }

  /// The tri-state list, plus the stored value when it is none of them, so the row shows the raw value instead of a dash.
  static func triStateRawValues(including stored: Int) -> [Int] {
    let known = MetalTriState.allCases.map(\.rawValue)
    return known.contains(stored) ? known : known + [stored]
  }
}

/// Size of the installed custom texture packs (Load/Textures).
enum TexturePackSize {
  static func bytesOnDisk() async -> Int64 {
    await Task.detached(priority: .utility) { bytesOnDiskSync() }.value
  }

  /// Synchronous on purpose: the directory enumerator can't be iterated from an async context.
  private nonisolated static func bytesOnDiskSync() -> Int64 {
    let root = URL(fileURLWithPath: UserFolderUtil.getUserFolder())
      .appendingPathComponent("Load/Textures", isDirectory: true)
    guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else {
      return 0
    }
    var total: Int64 = 0
    for case let url as URL in files {
      total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    return total
  }
}

/// One user edit. The host applies it to its snapshot AND to Config; the builder only emits it.
enum GraphicsAdvancedChange: Equatable {
  case flag(GraphicsAdvancedFlag, Bool)
  case compilerThreads(Int)
  case precompilerThreads(Int)
  case presentDrawable(Int)
  case manuallyUploadBuffers(Int)
}
