// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

// D16 follow-up: real per-preset preview thumbnails for `ShaderQuickPickerView`.
//
// `DOLShaderPostProcessor` is a singleton bound to the one live render pipeline —
// `UserDefaults`-driven, notification-driven, and mutated from the render loop.
// iFly's `ShaderPreviewGenerator` (the reference design named in the task) looks
// isolated at a glance but is NOT: its `renderPreview(for:...)` writes
// `shader_preset_path` / `shader_enabled` into `UserDefaults.standard`, calls
// `DOLShaderPostProcessor.shared.reloadShadersNow()`, renders through the SHARED
// processor, then restores the previous values. That is temporary mutation of
// live, persisted state — exactly what this feature must not do (a card render
// racing a real preset pick, or a crash between the mutate and the restore,
// would corrupt the user's actual shader choice). This file does not reuse that
// pattern.
//
// Instead, `ShaderPreviewRenderer` builds a throwaway `FilterChain` — the same
// public type `DOLShaderPostProcessor` wraps, but a brand new instance, on its
// own `MTLCommandQueue`, that never touches `DOLShaderPostProcessor.shared`,
// never reads or writes `UserDefaults`, and never posts a notification. It is
// local to one function call: the `FilterChain`, the decoded
// `CompiledShaderContainer`, and the textures involved are only ever referenced
// from that call's stack, so they are released the moment the render finishes —
// nothing here is retained across previews. Parameters render at the preset's
// compiled DEFAULT values (not the user's persisted per-parameter overrides):
// this keeps the renderer's isolation total (no `UserDefaults` reads at all),
// at the cost of a hero/card preview that won't reflect a hand-tuned parameter
// until the preset is actually loaded live.
//
// Because compiling and rendering an arbitrary bundled preset touches far more
// shader code than the live pipeline ever does in practice (a user only ever
// loads the ONE preset they picked; the picker grid wants to compile all of
// them), every failure mode is handled by returning `nil` rather than
// propagating — including a soft, best-effort time limit on top of the
// synchronous compile+render. That time limit cannot interrupt a Metal call
// already in flight (Swift has no safe way to abort a blocking driver call), so
// it is a "stop waiting" limit for the caller, not a hard kill: see the
// `onRealWorkCompleted` plumbing below and in `ShaderPreviewCache`, which keeps
// the concurrency-limiting slot held until the abandoned work actually finishes,
// not merely until the caller stops waiting for it.
import CoreGraphics
import Foundation
@preconcurrency import Metal
import MetalKit

enum ShaderPreviewRenderer {
  /// Every preview — hero or grid card — renders at this one fixed size, so the
  /// hero card and the matching selected grid card share a cache key (see
  /// `ShaderPreviewCache`) instead of paying for the same preset/frame pair
  /// twice. Chosen to match a roughly 4:3 game frame at thumbnail scale; display
  /// call sites crop/scale to their own aspect via `.aspectRatio(contentMode: .fill)`.
  static let thumbnailSize = CGSize(width: 320, height: 240)

  /// Width the shared source frame is downsampled to before it is handed to any
  /// preset's `FilterChain`. Shaders are written against console-resolution
  /// input; rendering every bundled preset against a full screenshot-resolution
  /// frame is the single biggest avoidable cost in the whole feature.
  static let sourceDownscaleMaxWidth: CGFloat = 640

  /// Soft ceiling the caller (`ShaderPreviewCache`) waits before giving up on a
  /// single preset's compile+render and falling back to the existing badge.
  static let defaultTimeout: TimeInterval = 2.0

  /// Ceiling for the GPU-side `waitUntilCompleted` equivalent inside the
  /// synchronous render itself. Deliberately looser than `defaultTimeout` — it
  /// only exists so a wedged command buffer doesn't hang the background queue
  /// forever; the caller has usually already stopped waiting by then via the
  /// `defaultTimeout` race.
  private static let gpuWaitTimeout: TimeInterval = 4.0

  /// `false` on the Simulator (per spec, unconditionally — this keeps preview
  /// generation out of CI/tests regardless of whether the Simulator's own Metal
  /// backend happens to be usable) or when no Metal device exists at all.
  static var isSupported: Bool {
    #if targetEnvironment(simulator)
    return false
    #else
    return MTLCreateSystemDefaultDevice() != nil
    #endif
  }

  /// Downscale `image` so its width is at most `maxWidth`, preserving aspect.
  /// Pure Core Graphics — no Metal, so it is exercised on the Simulator and in
  /// unit tests same as on device. Returns `image` unchanged (never `nil`) if it
  /// is already narrow enough or the resize fails for any reason — a full-size
  /// render is more expensive but not wrong, so failing open here is safe.
  static func downscaledCGImage(_ image: CGImage, maxWidth: CGFloat) -> CGImage {
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    guard maxWidth > 0, width > maxWidth, height > 0 else { return image }

    let scale = maxWidth / width
    let newWidth = Int(maxWidth.rounded())
    let newHeight = max(1, Int((height * scale).rounded()))

    guard let colorSpace = image.colorSpace,
          let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return image }

    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
    return context.makeImage() ?? image
  }

  /// Renders `presetURL` against `sourceImage` into a thumbnail-sized `CGImage`,
  /// entirely off an isolated `FilterChain`. Fails soft (`nil`) on any error —
  /// missing/corrupt preset data, a `FilterChain`/Metal failure, or exceeding
  /// `timeout` — never throws, never crashes the caller's flow.
  ///
  /// `onRealWorkCompleted` fires exactly once, when the underlying background
  /// work item actually finishes (success, failure, or its own internal
  /// `gpuWaitTimeout`) — which may be AFTER this function has already returned
  /// `nil` to its caller because `timeout` elapsed first. `ShaderPreviewCache`
  /// uses this to hold its concurrency slot until the real work is done, so a
  /// slow preset can't let more renders pile up than intended just because the
  /// UI stopped waiting for it.
  static func renderPreview(
    presetURL: URL,
    sourceImage: CGImage,
    timeout: TimeInterval = defaultTimeout,
    onRealWorkCompleted: (@Sendable () -> Void)? = nil
  ) async -> CGImage? {
    guard isSupported, let device = MTLCreateSystemDefaultDevice() else {
      onRealWorkCompleted?()
      return nil
    }

    return await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
      let resumeLock = NSLock()
      var didResume = false
      func resumeOnce(_ value: CGImage?) {
        resumeLock.lock()
        let shouldResume = !didResume
        didResume = true
        resumeLock.unlock()
        if shouldResume { continuation.resume(returning: value) }
      }

      // Global CONCURRENT queue: the timeout block below must be able to fire
      // independently of the (possibly slow) render block, which a serial queue
      // would not allow — the timeout would just queue up behind the render.
      DispatchQueue.global(qos: .utility).async {
        let result = renderPreviewSync(device: device, presetURL: presetURL, sourceImage: sourceImage)
        resumeOnce(result)
        onRealWorkCompleted?()
      }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
        resumeOnce(nil)
      }
    }
  }

  // MARK: - Synchronous render (background queue only)

  private static func renderPreviewSync(device: MTLDevice, presetURL: URL, sourceImage: CGImage) -> CGImage? {
    autoreleasepool {
      guard let commandQueue = device.makeCommandQueue() else { return nil }

      // `ZipCompiledShaderContainer.Decoder` extracts into a fresh
      // NSTemporaryDirectory() subfolder and never cleans it up (no `deinit`) —
      // fine for the live singleton, which does this once per user pick, but
      // the picker grid does this once per BUNDLED PRESET. Snapshot/diff the
      // temp dir so the extraction folder this call creates gets removed once
      // `setCompiledShader` has copied everything it needs out of it (LUTs are
      // loaded eagerly inside `setCompiledShader`, so nothing later needs the
      // extracted files on disk).
      let tempDir = FileManager.default.temporaryDirectory
      let entriesBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? [])

      let container: CompiledShaderContainer
      do {
        if let data = try? Data(contentsOf: presetURL) {
          container = try ZipCompiledShaderContainer.Decoder(data: data)
        } else {
          container = try ZipCompiledShaderContainer.Decoder(url: presetURL)
        }
      } catch {
        return nil
      }

      guard let filter = try? FilterChain(device: device) else {
        cleanUpExtractionArtifacts(in: tempDir, notPresentBefore: entriesBefore)
        return nil
      }
      do {
        try filter.setCompiledShader(container)
      } catch {
        cleanUpExtractionArtifacts(in: tempDir, notPresentBefore: entriesBefore)
        return nil
      }
      // `setCompiledShader` -> `freeShaderResources` leaves `hasShader = false`;
      // every existing call site (see `DOLShaderPostProcessor.ensurePresetLoaded`)
      // sets this by hand right after a successful load. Skipping it makes
      // `renderOffscreenPasses` return immediately and every preview silently
      // become "the raw source frame, unmodified" — a failure that looks like
      // success rather than like a missing thumbnail.
      filter.hasShader = true
      cleanUpExtractionArtifacts(in: tempDir, notPresentBefore: entriesBefore)

      let loader = MTKTextureLoader(device: device)
      guard let sourceTexture = try? loader.newTexture(cgImage: sourceImage, options: [.SRGB: false]) else {
        return nil
      }

      let outWidth = Int(thumbnailSize.width)
      let outHeight = Int(thumbnailSize.height)
      let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: outWidth, height: outHeight, mipmapped: false
      )
      outputDescriptor.usage = [.renderTarget, .shaderRead]
      outputDescriptor.storageMode = .shared
      guard let outputTexture = device.makeTexture(descriptor: outputDescriptor) else { return nil }
      guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

      // Deliberately do NOT call `filter.setOutputPixelFormat(_:)` — its default
      // (`.bgra8Unorm`, matching `outputDescriptor` above) is already what we
      // want, and that setter `fatalError`s if pipeline-state recreation fails.
      // Skipping the call entirely skips that landmine.
      let srcSize = CGSize(width: sourceTexture.width, height: sourceTexture.height)
      filter.drawableSize = thumbnailSize
      filter.setSourceRect(CGRect(origin: .zero, size: srcSize), aspect: srcSize)

      let rpd = MTLRenderPassDescriptor()
      rpd.colorAttachments[0].texture = outputTexture
      // `.clear`, not `.dontCare`: nothing else ever wrote to this brand-new
      // offscreen texture, unlike the live drawable the singleton renders into.
      rpd.colorAttachments[0].loadAction = .clear
      rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
      rpd.colorAttachments[0].storeAction = .store

      filter.render(sourceTexture: sourceTexture, commandBuffer: commandBuffer, renderPassDescriptor: rpd, flipVertically: false)

      let semaphore = DispatchSemaphore(value: 0)
      commandBuffer.addCompletedHandler { _ in semaphore.signal() }
      commandBuffer.commit()
      _ = semaphore.wait(timeout: .now() + gpuWaitTimeout)
      guard commandBuffer.status == .completed else { return nil }

      return cgImage(from: outputTexture)
    }
  }

  /// Removes any temp-directory entries that appeared during this call and
  /// whose name matches `ZipCompiledShaderContainer`'s own extraction prefixes
  /// ("oe_shader_decode" / "oe_shader_decode_data"). Deliberately scoped this
  /// narrowly (name prefix + "didn't exist before this call") rather than
  /// reaching into `ZipCompiledShaderContainer.Decoder` itself, which is shared
  /// code the live pipeline also depends on.
  private static func cleanUpExtractionArtifacts(in tempDir: URL, notPresentBefore entriesBefore: Set<String>) {
    guard let entriesAfter = try? FileManager.default.contentsOfDirectory(atPath: tempDir.path) else { return }
    for name in entriesAfter where !entriesBefore.contains(name) && name.hasPrefix("oe_shader_decode") {
      try? FileManager.default.removeItem(at: tempDir.appendingPathComponent(name))
    }
  }

  /// Reads `texture` back to a `CGImage`. `texture` is `.bgra8Unorm` — the
  /// bitmap info below (`.noneSkipFirst` + `.byteOrder32Little`) tells CoreGraphics
  /// to treat the raw bytes as little-endian BGRX and ignore the alpha channel
  /// entirely, rather than mapping it as premultiplied RGBA (which would swap
  /// the red/blue channels AND respect alpha — many compiled shaders leave the
  /// final pass's alpha at 0, which would otherwise render every preview fully
  /// transparent).
  private static func cgImage(from texture: MTLTexture) -> CGImage? {
    let width = texture.width
    let height = texture.height
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    texture.getBytes(&pixels, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: bytesPerRow,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: bitmapInfo,
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  }
}
