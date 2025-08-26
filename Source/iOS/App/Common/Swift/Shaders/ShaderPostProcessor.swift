import Foundation
import Metal
import MetalKit

@objc final class DOLShaderPostProcessor: NSObject {
	@objc static let shared = DOLShaderPostProcessor()
	private override init() {}
	private var device: MTLDevice?
	private var filter: FilterChain?
	private var library: CompiledShaderContainer?
	private var cachedPresetPath: String?
	private var lastDrawableSize: CGSize = .zero
	private var debugChecker: MTLTexture?

	@objc func configureWithDevice(_ device: MTLDevice) {
		if self.device?.registryID != device.registryID {
			self.device = device
			self.filter = try? FilterChain(device: device)
			self.library = nil
			self.cachedPresetPath = nil
			self.debugChecker = nil
		}
	}

	// Resolve a stored preset path to a valid URL in the current install.
	// Accepts absolute bundle paths from older installs, file URLs, or relative paths under the app bundle.
	private func resolvePresetURL(from storedPath: String) -> URL? {
		let p = storedPath.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !p.isEmpty else { return nil }

		let fm = FileManager.default
		let bundleURL = Bundle.main.bundleURL
		let bundlePath = bundleURL.path

		// Helper to persist a normalized relative path back to defaults
		func saveRelativeIfUnderBundle(_ absolutePath: String) {
			if absolutePath.hasPrefix(bundlePath), let range = absolutePath.range(of: ".app/") {
				let suffix = String(absolutePath[range.upperBound...])
				UserDefaults.standard.set(suffix, forKey: "shader_preset_path")
				print("[Shaders] Swift: normalized preset path -> relative='\(suffix)'")
			}
		}

		// 1) Handle file URL
		if p.hasPrefix("file://"), let url = URL(string: p) {
			let absPath = url.path
			if fm.fileExists(atPath: absPath) {
				saveRelativeIfUnderBundle(absPath)
				return URL(fileURLWithPath: absPath)
			}
			// Try to rebuild against current bundle if previous bundle path changed
			if let dotApp = absPath.range(of: ".app/") {
				let suffix = String(absPath[dotApp.upperBound...])
				let rebuilt = bundleURL.appendingPathComponent(suffix)
				if fm.fileExists(atPath: rebuilt.path) {
					UserDefaults.standard.set(suffix, forKey: "shader_preset_path")
					print("[Shaders] Swift: rebuilt preset path from old bundle -> 'file://\(rebuilt.path)'")
					return rebuilt
				}
			}
		}

		// 2) Handle absolute POSIX path
		if p.hasPrefix("/") {
			if fm.fileExists(atPath: p) {
				saveRelativeIfUnderBundle(p)
				return URL(fileURLWithPath: p)
			}
			if let dotApp = p.range(of: ".app/") {
				let suffix = String(p[dotApp.upperBound...])
				let rebuilt = bundleURL.appendingPathComponent(suffix)
				if fm.fileExists(atPath: rebuilt.path) {
					UserDefaults.standard.set(suffix, forKey: "shader_preset_path")
					print("[Shaders] Swift: rebuilt preset path from old bundle -> 'file://\(rebuilt.path)'")
					return rebuilt
				}
			}
		}

		// 3) Treat as relative path under current bundle
		let rel = bundleURL.appendingPathComponent(p)
		if fm.fileExists(atPath: rel.path) {
			return rel
		}

		// 4) Try resourcesURL explicitly (paranoid)
		if let res = Bundle.main.resourceURL?.appendingPathComponent(p), fm.fileExists(atPath: res.path) {
			return res
		}

		return nil
	}

	private func ensurePresetLoaded() {
		guard let filter else { return }
		let enabled = UserDefaults.standard.bool(forKey: "shader_enabled")
		print("[Shaders] Swift: ensurePresetLoaded enabled=\(enabled)")
		guard enabled else {
			filter.hasShader = false
			library = nil
			cachedPresetPath = nil
			print("[Shaders] Swift: disabled -> clearing")
			return
		}
		let p = UserDefaults.standard.string(forKey: "shader_preset_path") ?? ""
		print("[Shaders] Swift: preset path='\(p)'")
		guard !p.isEmpty else {
			filter.hasShader = false
			library = nil
			cachedPresetPath = nil
			print("[Shaders] Swift: no preset path set")
			return
		}
		// Reload if path changed OR we currently have no shader loaded
		if p == cachedPresetPath && filter.hasShader {
			return
		}
		guard let url = resolvePresetURL(from: p) else {
			filter.hasShader = false
			library = nil
			cachedPresetPath = nil
			print("[Shaders] Swift: failed to resolve preset path for current bundle")
			return
		}
		let exists = FileManager.default.fileExists(atPath: url.path)
		print("[Shaders] Swift: preset exists=\(exists)")
		do {
			let data = try Data(contentsOf: url)
			print("[Shaders] Swift: loading container from data, bytes=\(data.count)")
			let container = try ZipCompiledShaderContainer.Decoder(data: data)
			library = container
			try filter.setCompiledShader(container)
			filter.hasShader = true
			cachedPresetPath = p
			print("[Shaders] Swift: loaded preset OK, hasShader=\(filter.hasShader)")
			return
		} catch {
			print("[Shaders] Swift: data decode failed: \(error)")
		}
		do {
			print("[Shaders] Swift: trying url decode fallback")
			let container = try ZipCompiledShaderContainer.Decoder(url: url)
			library = container
			try filter.setCompiledShader(container)
			filter.hasShader = true
			cachedPresetPath = p
			print("[Shaders] Swift: loaded preset via url OK, hasShader=\(filter.hasShader)")
			return
		} catch {
			filter.hasShader = false
			library = nil
			cachedPresetPath = nil
			print("[Shaders] Swift: failed to load preset: \(error)")
		}
	}

	private func makeCheckerTexture(tile: Int = 16, tiles: Int = 16) -> MTLTexture? {
		guard let device else { return nil }
		let width = tile * tiles
		let height = tile * tiles
		var data = [UInt32](repeating: 0, count: width * height)
		let c0: UInt32 = 0xFF000000 // black BGRA
		let c1: UInt32 = 0xFFFFFFFF // white BGRA
		for y in 0..<height {
			for x in 0..<width {
				let sx = x / tile
				let sy = y / tile
				data[y * width + x] = ((sx + sy) & 1) == 0 ? c0 : c1
			}
		}
		guard let ctx = CGContext(data: &data,
								 width: width,
								height: height,
								bitsPerComponent: 8,
								bytesPerRow: width * 4,
								space: CGColorSpaceCreateDeviceRGB(),
								bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
		else { return nil }
		guard let img = ctx.makeImage() else { return nil }
		let loader = MTKTextureLoader(device: device)
		return try? loader.newTexture(cgImage: img, options: [MTKTextureLoader.Option.SRGB: false])
	}

	@objc func renderSource(_ source: MTLTexture, commandBuffer cb: MTLCommandBuffer, drawable: CAMetalDrawable) {
		guard let device else { return }
		configureWithDevice(device)
		ensurePresetLoaded()
		guard let filter else {
			// No filter: blit copy
			if let blit = cb.makeBlitCommandEncoder() {
				print("[Shaders] Swift: no FilterChain; blit copy")
				blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0), sourceSize: .init(width: source.width, height: source.height, depth: 1), to: drawable.texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init(x: 0, y: 0, z: 0))
				blit.endEncoding()
			}
			return
		}
		print("[Shaders] Swift: FilterChain ready: hasShader=\(filter.hasShader)")

		let dst = drawable.texture
		let srcSize = CGSize(width: source.width, height: source.height)
		let dstSize = CGSize(width: dst.width, height: dst.height)
		print("[Shaders] Swift: render begin hasShader=\(filter.hasShader) src=\(Int(srcSize.width))x\(Int(srcSize.height)) dst=\(Int(dstSize.width))x\(Int(dstSize.height)) fmt src=\(source.pixelFormat.rawValue) dst=\(dst.pixelFormat.rawValue)")

		// Debug checkerboard: bypass compiled shader and draw a known pattern
		if UserDefaults.standard.bool(forKey: "shader_debug_checker") {
			if debugChecker == nil { debugChecker = makeCheckerTexture() }
			guard let tex = debugChecker else { return }
			let rpd = MTLRenderPassDescriptor()
			rpd.colorAttachments[0].texture = dst
			rpd.colorAttachments[0].loadAction = .clear
			rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
			rpd.colorAttachments[0].storeAction = .store
			/* keep compiled shader active to render over checkerboard */
			filter.setOutputPixelFormat(dst.pixelFormat)
			filter.drawableSize = dstSize
			let texSize = CGSize(width: tex.width, height: tex.height)
			filter.setSourceRect(CGRect(origin: .zero, size: texSize), aspect: texSize)
			let applied = UserDefaults.standard.bool(forKey: "shader_debug_checker_apply")
			if applied, filter.hasShader {
				// Run full pipeline over checkerboard
				filter.render(sourceTexture: tex, commandBuffer: cb, renderPassDescriptor: rpd, flipVertically: false)
				print("[Shaders] Swift: checker with shader applied")
			} else {
				// Show checker alone
				filter.hasShader = false
				filter.render(sourceTexture: tex, commandBuffer: cb, renderPassDescriptor: rpd, flipVertically: false)
				print("[Shaders] Swift: debug checker drawn")
			}
			return
		}

		guard filter.hasShader else {
			if let blit = cb.makeBlitCommandEncoder() {
				print("[Shaders] Swift: no active shader; blit copy")
				blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0), sourceSize: .init(width: source.width, height: source.height, depth: 1), to: dst, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init(x: 0, y: 0, z: 0))
				blit.endEncoding()
			}
			return
		}

		let rpd = MTLRenderPassDescriptor()
		rpd.colorAttachments[0].texture = dst
		rpd.colorAttachments[0].loadAction = .load
		rpd.colorAttachments[0].storeAction = .store

		// If the filter doesn't draw anything, ensure we copy src->dst so the screen isn't black
		let preMarker = cb.makeBlitCommandEncoder()
		preMarker?.label = "PostProcess preCopy"
		preMarker?.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0), sourceSize: .init(width: source.width, height: source.height, depth: 1), to: dst, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init(x: 0, y: 0, z: 0))
		preMarker?.endEncoding()

		// Debug bypass: show the source without applying the compiled shader
		if UserDefaults.standard.bool(forKey: "shader_bypass") {
			print("[Shaders] Swift: bypass enabled -> showing source only")
			return
		}

		// Debug: Fill the drawable to verify the render pass works if enabled
		if UserDefaults.standard.bool(forKey: "shader_debug_fill") {
			let dbg = MTLRenderPassDescriptor()
			dbg.colorAttachments[0].texture = dst
			dbg.colorAttachments[0].loadAction = .clear
			dbg.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 1)
			dbg.colorAttachments[0].storeAction = .store
			if let enc = cb.makeRenderCommandEncoder(descriptor: dbg) {
				enc.endEncoding()
			}
			print("[Shaders] Swift: debug fill applied")
		}

		// Pipe sizes/pixelFormat into the filter
		filter.setOutputPixelFormat(dst.pixelFormat)
		filter.drawableSize = dstSize
		filter.setSourceRect(CGRect(origin: .zero, size: srcSize), aspect: srcSize)

		// Optional: show an intermediate pass
		if UserDefaults.standard.bool(forKey: "shader_debug_show_pass_enabled"),
		   let idx = UserDefaults.standard.object(forKey: "shader_debug_show_pass") as? NSNumber {
			let passIndex = idx.intValue
			if filter.debugRenderPass(index: Int(passIndex), commandBuffer: cb, renderPassDescriptor: rpd) {
				print("[Shaders] Swift: showing pass #\(passIndex) / count=\(filter.debugPassCount)")
				return
			} else {
				print("[Shaders] Swift: invalid pass index #\(passIndex) (count=\(filter.debugPassCount))")
			}
		}

		// Invoke the filter
		let flip = (UserDefaults.standard.object(forKey: "shader_flip_vertical") as? Bool) ?? true
		filter.render(sourceTexture: source, commandBuffer: cb, renderPassDescriptor: rpd, flipVertically: flip)
		print("[Shaders] Swift: render end (flip=\(flip))")
	}
}
