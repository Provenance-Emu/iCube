import Foundation
import Metal

// The runner redirects texture/clear-buffer allocations and the clear encoder in a
// temporary copy of FilterChain to
// deterministically exercise allocation failure without exhausting GPU memory.
var allocations: [(Int, Int)] = []
var failAllocation: Int?
func auditMakeTexture(_ device: MTLDevice, _ descriptor: MTLTextureDescriptor) -> MTLTexture? {
  allocations.append((descriptor.width, descriptor.height))
  if allocations.count == failAllocation { return nil }
  return device.makeTexture(descriptor: descriptor)
}
var failClearBuffer = false
var failClearEncoder = false
var forcedMaxBufferLength: Int?
var oversizedClearBufferRequests = 0
func auditMaxBufferLength(_ device: MTLDevice) -> Int {
  min(forcedMaxBufferLength ?? device.maxBufferLength, device.maxBufferLength)
}
var clearBufferAttempts = 0
var clearEncoderAttempts = 0
func auditMakeClearBuffer(_ device: MTLDevice, _ length: Int) -> MTLBuffer? {
  clearBufferAttempts += 1
  if length > auditMaxBufferLength(device) {
    oversizedClearBufferRequests += 1
    return nil
  }
  return failClearBuffer ? nil : device.makeBuffer(length: length, options: [.storageModePrivate])
}
func auditMakeClearEncoder(_ commandBuffer: MTLCommandBuffer) -> MTLBlitCommandEncoder? {
  clearEncoderAttempts += 1
  return failClearEncoder ? nil : commandBuffer.makeBlitCommandEncoder()
}
struct Container: CompiledShaderContainer {
  let shader: Compiled.Shader
  func getLUTByName(_ name: String) throws -> Data { fatalError("No LUTs in fixture") }
}
let vertex = """
#include <metal_stdlib>
using namespace metal;
struct Input { float4 p [[attribute(0)]]; };
vertex float4 main0(Input v [[stage_in]]) { return float4(v.p.xy * 2.0 - 1.0, 0, 1); }
"""
let fragment = """
#include <metal_stdlib>
using namespace metal;
fragment float4 main0() { return float4(0,1,0,1); }
"""
func preset(scales: [CGFloat], feedback: Bool = false, history: Int = 0, mode: String = "source") -> Container {
  let empty = Compiled.BufferDescriptor(bindingVert: nil, bindingFrag: nil, size: 0, uniforms: [])
  let passes = scales.enumerated().map { i, scale in
    let axis: Compiled.ShaderPassScale = mode == "viewport" ? .viewport(scale: scale)
      : (mode == "absolute" ? .absolute(size: Int(scale)) : .source(scale: scale))
    return Compiled.ShaderPass(index: i, vertexSource: vertex, fragmentSource: fragment,
      frameCountMod: 0, scaleX: axis, scaleY: axis,
      filter: .nearest, wrapMode: .edge, format: .bgra8Unorm, isFeedback: feedback,
      buffers: [empty, empty], textures: [], alias: nil)
  }
  return Container(shader: .init(passes: passes, parameters: [], luts: [], historyCount: history, languageVersion: .version2_4))
}
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() { fatalError(message) }
}
guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
  fatalError("Host Metal device unavailable; runtime checks did not run")
}
func texture(_ size: Int, color: [UInt8]? = nil) -> MTLTexture {
  let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
  d.usage = [.shaderRead, .renderTarget]
  d.storageMode = .shared
  let t = device.makeTexture(descriptor: d)!
  if let color {
    let bytes = [[UInt8]](repeating: color, count: size * size).flatMap { $0 }
    bytes.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: size * 4) }
  }
  return t
}
let output = texture(8)
func frame(_ chain: FilterChain, sourceSize: Int = 4, drawableSize: Int = 8, sourceColor: [UInt8] = [0,0,255,255]) -> [UInt8] {
  let source = texture(sourceSize, color: sourceColor)
  chain.drawableSize = CGSize(width: drawableSize, height: drawableSize)
  chain.setSourceRect(CGRect(x: 0, y: 0, width: sourceSize, height: sourceSize), aspect: CGSize(width: 1, height: 1))
  let cb = queue.makeCommandBuffer()!
  let rpd = MTLRenderPassDescriptor()
  rpd.colorAttachments[0].texture = output
  rpd.colorAttachments[0].loadAction = .clear
  rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
  rpd.colorAttachments[0].storeAction = .store
  chain.render(sourceTexture: source, commandBuffer: cb, renderPassDescriptor: rpd)
  cb.commit(); cb.waitUntilCompleted()
  require(cb.status == .completed, "GPU command failed: \(String(describing: cb.error))")
  var pixel = [UInt8](repeating: 0, count: 4)
  output.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(4,4,1,1), mipmapLevel: 0)
  return pixel
}
func chain(_ c: Container) throws -> FilterChain {
  let f = try FilterChain(device: device)
  try f.setCompiledShader(c)
  allocations = []; failAllocation = nil
  failClearBuffer = false; failClearEncoder = false
  clearBufferAttempts = 0; clearEncoderAttempts = 0
  forcedMaxBufferLength = nil; oversizedClearBufferRequests = 0
  return f
}
let red: [UInt8] = [0,0,255,255], green: [UInt8] = [0,255,0,255]
if CommandLine.arguments.contains("--baseline-crash") {
  let f = try chain(preset(scales: [0]))
  _ = frame(f)
  fatalError("Baseline unexpectedly survived")
}
// Finite checks precede integer conversion; rounded-zero and chained oversize
// checks must reject the whole plan before the first pass allocates.
#if DEBUG
// Override any persisted host preference only in this process. The first
// diagnostic must execute even when the fitted drawable contains NaN/inf.
var debugPreferences = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
debugPreferences["shader_debug_log_once"] = true
UserDefaults.standard.setVolatileDomain(debugPreferences, forName: UserDefaults.argumentDomain)
require(UserDefaults.standard.bool(forKey: "shader_debug_log_once"), "First-render diagnostic must be enabled")
let firstInvalidViewport = try chain(preset(scales: [1.5]))
require(frame(firstInvalidViewport, drawableSize: 0) == [0,0,0,255],
        "First invalid viewport must complete with the render-pass clear result")
require(allocations.isEmpty, "First invalid viewport must not allocate targets")
require(frame(firstInvalidViewport) == green, "Valid frame after first-render diagnostic must recover")
print("PASS: DEBUG first-render diagnostic explicitly enabled; zero/invalid viewport clears and next valid frame recovers")
#endif
for scales: [CGFloat] in [[0], [-1], [.nan], [.infinity], [0.001], [100000], [1,100000]] {
  let f = try chain(preset(scales: scales))
  require(frame(f) == red, "Invalid dimensions must draw the unfiltered source")
  require(allocations.isEmpty, "Invalid plan allocated a partial chain")
}
for n in [8192,16384,32768] {
  require(FilterChain.textureDimensions(CGSize(width: n, height: 1), limit: n) != nil, "Maximum rejected")
  require(FilterChain.textureDimensions(CGSize(width: n+1, height: 1), limit: n) == nil, "Over maximum accepted")
}
for (mode, scale): (String, CGFloat) in [("viewport", 0.75), ("absolute", 6)] {
  let f = try chain(preset(scales: [scale], mode: mode))
  require(frame(f) == green, "Valid viewport/absolute shader must render")
  require(allocations.contains { $0 == (6,6) }, "Viewport/absolute scale changed")
}
for historyCount in [0,1] {
  let failed = try chain(preset(scales: [1.5], feedback: true, history: historyCount))
  for _ in 0..<3 {
    allocations = []; failAllocation = 2
    require(frame(failed) == red, "Repeated allocation failure must bypass")
    require(failed._clearTextures.isEmpty, "Failed frames retained pending clear textures")
  }
  allocations = []; failAllocation = nil
  require(frame(failed) == green, "Repeated allocation failure must recover")
}
for failBuffer in [true, false] {
  let clearing = try chain(preset(scales: [1.5], feedback: true, history: 1))
  failClearBuffer = failBuffer
  failClearEncoder = !failBuffer
  for i in 0..<3 {
    allocations = []; clearBufferAttempts = 0; clearEncoderAttempts = 0
    let currentSource: [UInt8] = i % 2 == 0 ? red : [255,0,0,255]
    require(frame(clearing, sourceColor: currentSource) == currentSource,
            "Failed clearing must draw the current source with no open encoder")
    require(allocations.count == 4, "Fixture must allocate feedback and history before clear failure")
    require(clearBufferAttempts == 1, "Fixture did not reach clear-buffer allocation")
    require(clearEncoderAttempts == (failBuffer ? 0 : 1), "Buffer must allocate before opening encoder")
    require(clearing._clearTextures.isEmpty, "Clear failure retained pending textures")
  }
  allocations = []; failClearBuffer = false; failClearEncoder = false
  clearBufferAttempts = 0; clearEncoderAttempts = 0
  require(frame(clearing) == green, "Clear failure must recover on the next frame")
  require(allocations.count == 4, "Retry must rebuild feedback and history resources")
  require(clearBufferAttempts == 1 && clearEncoderAttempts == 1, "Recovery must clear the rebuilt resources")
}
// Exercise the production checked arithmetic without requesting large resources.
let gib = 1_073_741_824
let rgba32 = FilterChain.clearTextureLayout(width: 8192, height: 8192,
                                          bytesPerPixel: MTLPixelFormat.rgba32Float.bytesPerPixel, maxBufferLength: gib)
require(rgba32?.bytesPerRow == 131072 && rgba32?.bytesPerImage == gib, "Exact GiB limit must be allowed")
require(FilterChain.clearTextureLayout(width: 8192, height: 8192, bytesPerPixel: 16,
                                      maxBufferLength: gib - 1) == nil, "One byte above device limit must be rejected")
for bpp in [1,2,4,8,16] {
  let layout = FilterChain.clearTextureLayout(width: 7, height: 5, bytesPerPixel: bpp, maxBufferLength: 35 * bpp)
  require(layout?.bytesPerRow == 7 * bpp && layout?.bytesPerImage == 35 * bpp, "Valid pixel layout changed")
  require(FilterChain.clearTextureLayout(width: 7, height: 5, bytesPerPixel: bpp,
                                        maxBufferLength: 35 * bpp - 1) == nil, "Over-limit pixel layout accepted")
}
for (width, height, bpp, limit) in [(0,1,4,64), (-1,1,4,64), (1,0,4,64), (1,-1,4,64),
                                    (1,1,0,64), (1,1,-1,64), (1,1,4,0), (1,1,4,-1),
                                    (Int.max,1,2,Int.max), (Int.max,2,1,Int.max)] {
  require(FilterChain.clearTextureLayout(width: width, height: height, bytesPerPixel: bpp,
                                        maxBufferLength: limit) == nil, "Invalid/overflowing layout must fail gracefully")
}
require(FilterChain.clearTextureLayout(width: 1, height: 1, bytesPerPixel: MTLPixelFormat.invalid.bytesPerPixel,
                                      maxBufferLength: 64) == nil, "Unknown pixel layout must fail gracefully")
let limited = try chain(preset(scales: [1.5], feedback: true, history: 1))
// This fixture allocates only 6x6 BGRA targets (144 bytes), never GiB buffers.
forcedMaxBufferLength = 143
for i in 0..<3 {
  clearBufferAttempts = 0; clearEncoderAttempts = 0; oversizedClearBufferRequests = 0
  let currentSource: [UInt8] = i % 2 == 0 ? red : [255,0,0,255]
  require(frame(limited, sourceColor: currentSource) == currentSource, "Buffer limit must fall back to the current source")
  require(clearBufferAttempts == 0 && oversizedClearBufferRequests == 0,
          "Oversized clear buffer must be rejected before makeBuffer")
  require(clearEncoderAttempts == 0, "Oversized clear must not open an encoder")
  require(limited._clearTextures.isEmpty, "Oversized clear must discard pending textures")
}
forcedMaxBufferLength = 144
require(frame(limited) == green, "An exact-limit buffer must recover on the next frame")
require(clearBufferAttempts == 1 && clearEncoderAttempts == 1, "Exact-limit clear must allocate and encode normally")
require(oversizedClearBufferRequests == 0, "A clear exceeded its modeled device limit")
forcedMaxBufferLength = nil
print("PASS: tiny modeled maxBufferLength rejects before buffer/encoder, current-source fallback repeats, exact-limit next frame recovers")
let lifecycle = try chain(preset(scales: [1.5]))
_ = frame(lifecycle, drawableSize: 0)
require(allocations.isEmpty, "Zero viewport lifecycle must not allocate")
require(frame(lifecycle) == green, "Viewport lifecycle must recover")
let valid = try chain(preset(scales: [1.5]))
require(frame(valid) == green, "Valid shader must render")
require(allocations.contains { $0 == (6,6) }, "Valid scale changed")
allocations = []
require(frame(valid, sourceSize: 6) == green, "Source resize must render")
require(allocations.contains { $0 == (9,9) }, "Source resize did not invalidate targets")
let retry = try chain(preset(scales: [1.5], feedback: true))
failAllocation = 2
require(frame(retry) == red, "Failed feedback allocation must bypass shader")
allocations = []; failAllocation = nil
require(frame(retry) == green, "Feedback allocation must retry")
require(allocations.count == 2, "Retry reused an incomplete feedback pair")
let history = try chain(preset(scales: [1.5], history: 1))
failAllocation = 2
require(frame(history) == red, "Failed history allocation must bypass shader")
allocations = []; failAllocation = nil
require(frame(history) == green, "History allocation must retry")
let directFeedback = try chain(preset(scales: [2], feedback: true))
require(frame(directFeedback) == green, "Feedback pass at viewport size must allocate both targets")
require(allocations.count == 2, "Direct optimization lost feedback target")
let recovery = try chain(preset(scales: [0.1]))
require(frame(recovery, sourceSize: 4) == red, "Rounded-zero should bypass")
require(frame(recovery, sourceSize: 8) == green, "New source size should recover")
print("PASS: actual FilterChain host Metal invalid dimensions, whole-plan preflight, valid scaling, source resize, texture/clear-buffer/clear-encoder failure and retry, feedback, history, and recovery")
