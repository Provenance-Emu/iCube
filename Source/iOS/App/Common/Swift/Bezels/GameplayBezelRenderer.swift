// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import MetalKit
import SkinKitBezels
import UIKit

/// One game session owns the request and GPU failure latch, independently of its view layout.
final class GameplayBezelRenderer: @unchecked Sendable {
  struct Request: Equatable, Sendable {
    let bezel: TVBezel
    let canvas: CGSize
    let viewport: CGRect
    let surfaceAspect: CGFloat
    let pixelWidth: CGFloat
    let shape: TVBezelPictureShape
    let lightsRoom: Bool
    let flatGlass: Bool
  }

  /// A scene ready to draw: SkinKit's description of it, its filter chain and a plain chain for the tube.
  typealias Loaded = (scene: TVBezelScene, chain: FilterChain, plain: FilterChain)

  /// How many frames in a row may fail to encode before the scene is given up. A chain that is still preparing
  /// its next frame fails for a frame or two; a second of failures is not that.
  static let encodeFailureLimit = 60

  private static let loadQueue = DispatchQueue(label: "iCube.TVBezel.load", qos: .userInitiated)
  private let lock = NSLock()
  private let loader: @Sendable (Request) -> Loaded?
  private var generation = 0
  private var request: Request?
  private var loaded: Loaded?
  private var dropped = false
  /// `request` could not be loaded or drawn. It stays the request, so the same one is not loaded again on every
  /// layout pass, but it no longer counts as requested: the screen filter and the image path take over.
  private var requestFailed = false
  private var encodeFailures = 0

  /// - Parameter loader: builds a request's scene; tests replace it.
  init(loader: @escaping @Sendable (Request) -> Loaded? = { GameplayBezelRenderer.load($0) }) {
    self.loader = loader
  }

  private var picture: CGRect?
  private var tube: MTLTexture?

  static func presetURL(_ id: String, in bundle: Bundle = .main) -> URL? {
    guard let path = TVBezelShader.libraryPath(ofPresetID: id),
          let root = bundle.resourceURL else { return nil }
    let url = root.appendingPathComponent("compiled_shaders").appendingPathComponent(path + ".oecompiledshader")
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  static let supportsRoomLight = MTLCreateSystemDefaultDevice() != nil && presetURL(TVBezelShader.ambientID) != nil

  var isRequested: Bool { lock.withLock { request != nil && !dropped && !requestFailed } }
  var isReady: Bool { lock.withLock { loaded != nil } }
  var pictureInViewport: CGRect? { lock.withLock { picture } }

  @MainActor
  func update(_ next: Request?, didLoad: @escaping @MainActor @Sendable () -> Void) -> Bool {
    let token = lock.withLock { () -> Int? in
      guard request != next, !dropped else { return nil }
      generation += 1
      request = next
      loaded = nil
      tube = nil
      picture = nil
      requestFailed = false
      encodeFailures = 0
      return generation
    }
    guard let token else { return false }
    TVEmulationBridge.redrawPausedFrame()
    guard let next else { return true }
    Self.loadQueue.async { [weak self] in
      guard let self, self.lock.withLock({ self.generation == token && !self.dropped }) else { return }
      let loaded = self.loader(next)
      DispatchQueue.main.async {
        let accepted = self.lock.withLock {
          guard self.generation == token, !self.dropped else { return false }
          self.loaded = loaded
          // A scene that did not load must not keep the screen filter off or the image path away.
          self.requestFailed = loaded == nil
          return true
        }
        guard accepted else { return }
        if loaded == nil {
          self.didFail?(next.bezel.id)
        } else {
          didLoad()
        }
        TVEmulationBridge.redrawPausedFrame()
      }
    }
    return true
  }

  static func load(_ request: Request, findPreset: (String) -> URL? = { presetURL($0) })
    -> (scene: TVBezelScene, chain: FilterChain, plain: FilterChain)? {
    let key = TVBezelScene.key(bezel: request.bezel, lightsRoom: request.lightsRoom, flatGlass: request.flatGlass,
                               scenePixelWidth: request.pixelWidth, canvas: request.canvas, shape: request.shape)
    guard let scene = TVBezelScene.make(bezel: request.bezel, lightsRoom: request.lightsRoom, flatGlass: request.flatGlass,
                                        scenePixelWidth: request.pixelWidth, key: key, canvas: request.canvas,
                                        shape: request.shape, hasPreset: { findPreset($0) != nil }),
      let url = findPreset(scene.presetID), let device = MTLCreateSystemDefaultDevice() else { return nil }
    do {
      let container = try ZipCompiledShaderContainer.Decoder(url: url)
      defer { container.removeExtractedFiles() }
      let chain = try FilterChain(device: device)
      var textures: [String: MTLTexture] = [:]
      if let png = scene.borderPNG {
        guard container.shader.luts.contains(where: { $0.name == TVBezelShader.borderTextureName }) else { return nil }
        textures[TVBezelShader.borderTextureName] = try MTKTextureLoader(device: device).newTexture(
          data: png, options: [.SRGB: false, .generateMipmaps: false])
      }
      try chain.setCompiledShader(container, textures: textures)
      chain.setDefaultFilteringLinear(true)
      for (name, value) in scene.values {
        chain.setValue(CGFloat(value), forParameterName: name)
      }
      return (scene, chain, try FilterChain(device: device))
    } catch {
      NSLog("[Bezels] Could not load %@: %@", scene.presetID, String(describing: error))
      return nil
    }
  }

  /// Runs on Dolphin's video thread. A requested but unavailable scene leaves the source frame intact.
  func render(game: MTLTexture, target: MTLTexture, pictureFilter: FilterChain?,
              commandBuffer: MTLCommandBuffer, flip: Bool) -> Bool {
    lock.withLock {
      guard !dropped, let request, let (scene, chain, plain) = loaded else { return false }
      let size = CGSize(width: target.width, height: target.height)
      // SwiftUI and the Metal layer can deliver a rotation on different frames.
      guard abs(size.width / size.height - request.surfaceAspect) < 0.02 else { return false }
      let viewport = CGRect(x: request.viewport.minX * size.width, y: request.viewport.minY * size.height,
                            width: request.viewport.width * size.width, height: request.viewport.height * size.height)
        .integral.intersection(CGRect(origin: .zero, size: size))
      guard !viewport.isEmpty else { return false }
      var encoded = false
      defer {
        if encoded {
          encodeFailures = 0
        } else {
          // One frame that could not be encoded is retried on the next: the scene stays loaded.
          picture = nil
          encodeFailures += 1
          if encodeFailures >= Self.encodeFailureLimit { giveUpLocked(request) }
        }
      }
      let width = max(1, Int((scene.tubeRect.width / scene.canvas.width * viewport.width).rounded()))
      let height = max(1, Int((scene.tubeRect.height / scene.canvas.height * viewport.height).rounded()))
      if tube?.width != width || tube?.height != height || tube?.pixelFormat != target.pixelFormat {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: target.pixelFormat, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        tube = target.device.makeTexture(descriptor: descriptor)
      }
      guard let tube else { return false }
      let tubeSize = CGSize(width: width, height: height)
      let gameSize = CGSize(width: game.width, height: game.height)
      let bounds = CGRect(origin: .zero, size: tubeSize)
      let gameRect = ICubeBezels.aspectFit(aspect: gameSize.width / gameSize.height, in: bounds).integral.intersection(bounds)
      let first = pictureFilter ?? plain
      first.setOutputPixelFormat(tube.pixelFormat)
      first.drawableSize = tubeSize
      first.outputRect = gameRect
      first.setSourceRect(CGRect(origin: .zero, size: gameSize), aspect: gameSize)
      let drewTube = first.render(sourceTexture: game, commandBuffer: commandBuffer, renderPassDescriptor: Self.pass(tube),
                                  flipVertically: flip)
      guard drewTube else { return false }
      chain.setOutputPixelFormat(target.pixelFormat)
      chain.drawableSize = size
      chain.outputRect = viewport
      chain.setSourceRect(bounds, aspect: tubeSize)
      guard chain.render(sourceTexture: tube, commandBuffer: commandBuffer, renderPassDescriptor: Self.pass(target),
                         requiresShader: true) else { return false }

      picture = CGRect(
        x: (viewport.minX + scene.tubeRect.minX / scene.canvas.width * viewport.width + gameRect.minX) / size.width,
        y: (viewport.minY + scene.tubeRect.minY / scene.canvas.height * viewport.height + gameRect.minY) / size.height,
        width: gameRect.width / size.width, height: gameRect.height / size.height)
      commandBuffer.addCompletedHandler { [weak self] buffer in
        guard let error = buffer.error else { return }
        let action = TVFrameFailure.action(for: error)
        guard action != .logOnly else { return }
        DispatchQueue.main.async { [weak self] in self?.dropAfterGPUFailure(action) }
      }
      encoded = true
      return true
    }
  }

  private static func pass(_ target: MTLTexture) -> MTLRenderPassDescriptor {
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
    pass.colorAttachments[0].storeAction = .store
    return pass
  }

  /// Call with `lock` held, on the video thread: the scene cannot be drawn. The request stops counting as
  /// requested and the session is told, so the screen falls back to the TV as an image.
  private func giveUpLocked(_ request: Request) {
    loaded = nil
    tube = nil
    picture = nil
    requestFailed = true
    encodeFailures = 0
    let token = generation
    let bezelID = request.bezel.id
    NSLog("[Bezels] Could not encode the TV scene for %d frames; falling back", Self.encodeFailureLimit)
    DispatchQueue.main.async { [weak self] in
      guard let self, self.lock.withLock({ self.generation == token && self.requestFailed }) else { return }
      self.didFail?(bezelID)
      TVEmulationBridge.redrawPausedFrame()
    }
  }

  @MainActor var didDrop: (() -> Void)?
  /// The scene of the TV with this id could not be loaded or drawn. The GPU is not at fault (that is `didDrop`),
  /// so only this TV's scene is given up: the session shows it as an image instead.
  @MainActor var didFail: ((String) -> Void)?

  @MainActor
  private func dropAfterGPUFailure(_ action: TVFrameFailure.Action) {
    // Command buffers in flight when the app leaves the foreground time out as a matter of course: that is not
    // a GPU that cannot draw the TV, so it does not cost the player the TV for the rest of the game. A real
    // failure shows again on the first frames after the app returns, and is latched then.
    guard action == .accessRevoked || UIApplication.shared.applicationState == .active else { return }
    let didChange = lock.withLock {
      guard !dropped else { return false }
      dropped = true
      request = nil
      requestFailed = false
      loaded = nil
      tube = nil
      picture = nil
      return true
    }
    guard didChange else { return }
    NSLog("[Bezels] Disabled for this game session after a Metal command buffer failure")
    didDrop?()
    if action != .accessRevoked { TVEmulationBridge.redrawPausedFrame() }
  }
}
