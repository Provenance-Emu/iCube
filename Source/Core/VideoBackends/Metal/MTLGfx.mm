// Copyright 2022 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "VideoBackends/Metal/MTLGfx.h"

#include "VideoBackends/Metal/MTLBoundingBox.h"
#include "VideoBackends/Metal/MTLObjectCache.h"
#include "VideoBackends/Metal/MTLPipeline.h"
#include "VideoBackends/Metal/MTLStateTracker.h"
#include "VideoBackends/Metal/MTLTexture.h"
#include "VideoBackends/Metal/MTLUtil.h"
#include "VideoBackends/Metal/MTLVertexFormat.h"
#include "VideoBackends/Metal/MTLVertexManager.h"

#include "VideoCommon/FramebufferManager.h"
#include "VideoCommon/Present.h"
#include "VideoCommon/VideoBackendBase.h"
#include "Core/Config/GraphicsSettings.h"
#include "Common/Config/Config.h"

#include <fstream>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

@interface DOLShaderPostProcessor : NSObject
+ (instancetype)shared;
- (void)configureWithDevice:(id<MTLDevice>)device;
- (void)renderSource:(id<MTLTexture>)source commandBuffer:(id<MTLCommandBuffer>)cb drawable:(id<CAMetalDrawable>)drawable;
@end

Metal::Gfx::Gfx(MRCOwned<CAMetalLayer*> layer) : m_layer(std::move(layer))
{
  UpdateActiveConfig();
  [m_layer setDisplaySyncEnabled:g_ActiveConfig.bVSyncActive];

  SetupSurface();
  g_state_tracker->FlushEncoders();


}

Metal::Gfx::~Gfx() = default;

bool Metal::Gfx::IsHeadless() const
{
  return m_layer == nullptr;
}

// MARK: Texture Creation

static MTLTextureType FromAbstract(AbstractTextureType type, bool multisample)
{
  switch (type)
  {
  case AbstractTextureType::Texture_2D:
    return multisample ? MTLTextureType2DMultisample : MTLTextureType2D;
  case AbstractTextureType::Texture_2DArray:
    return multisample ? MTLTextureType2DMultisampleArray : MTLTextureType2DArray;
  case AbstractTextureType::Texture_CubeMap:
    return MTLTextureTypeCube;
  }

  ASSERT(false);
  return MTLTextureType2DArray;
}

std::unique_ptr<AbstractTexture> Metal::Gfx::CreateTexture(const TextureConfig& config,
                                                           std::string_view name)
{
  @autoreleasepool
  {
    MRCOwned<MTLTextureDescriptor*> desc = MRCTransfer([MTLTextureDescriptor new]);
    [desc setTextureType:FromAbstract(config.type, config.samples > 1)];
    [desc setPixelFormat:Util::FromAbstract(config.format)];
    [desc setWidth:config.width];
    [desc setHeight:config.height];
    [desc setMipmapLevelCount:config.levels];
    [desc setArrayLength:config.layers];
    [desc setSampleCount:config.samples];
    [desc setStorageMode:MTLStorageModePrivate];
    MTLTextureUsage usage = MTLTextureUsageShaderRead;
    if (config.IsRenderTarget())
      usage |= MTLTextureUsageRenderTarget;
    if (config.IsComputeImage())
      usage |= MTLTextureUsageShaderWrite;
    [desc setUsage:usage];
    id<MTLTexture> texture = [g_device newTextureWithDescriptor:desc];
    if (!texture)
      return nullptr;

    if (name.empty())
      [texture setLabel:[NSString stringWithFormat:@"Texture %d", m_texture_counter++]];
    else
      [texture setLabel:MRCTransfer([[NSString alloc] initWithBytes:name.data()
                                                             length:name.size()
                                                           encoding:NSUTF8StringEncoding])];
    return std::make_unique<Texture>(MRCTransfer(texture), config);
  }
}

std::unique_ptr<AbstractStagingTexture>
Metal::Gfx::CreateStagingTexture(StagingTextureType type, const TextureConfig& config)
{
  @autoreleasepool
  {
    const size_t stride = config.GetStride();
    const size_t buffer_size = stride * static_cast<size_t>(config.height);

    MTLResourceOptions options = MTLStorageModeShared;
    if (type == StagingTextureType::Upload)
      options |= MTLResourceCPUCacheModeWriteCombined;
    if (type == StagingTextureType::Upload)
      options |= MTLResourceHazardTrackingModeUntracked;

    id<MTLBuffer> buffer = [g_device newBufferWithLength:buffer_size options:options];
    if (!buffer)
      return nullptr;
    [buffer
        setLabel:[NSString stringWithFormat:@"Staging Texture %d", m_staging_texture_counter++]];
    return std::make_unique<StagingTexture>(MRCTransfer(buffer), type, config);
  }
}

std::unique_ptr<AbstractFramebuffer>
Metal::Gfx::CreateFramebuffer(AbstractTexture* color_attachment, AbstractTexture* depth_attachment,
                              std::vector<AbstractTexture*> additional_color_attachments)
{
  AbstractTexture* const either_attachment = color_attachment ? color_attachment : depth_attachment;
  return std::make_unique<Framebuffer>(
      color_attachment, depth_attachment, std::move(additional_color_attachments),
      either_attachment->GetWidth(), either_attachment->GetHeight(), either_attachment->GetLayers(),
      either_attachment->GetSamples());
}

// MARK: Pipeline Creation

std::unique_ptr<AbstractShader> Metal::Gfx::CreateShaderFromSource(ShaderStage stage,
                                                                   std::string_view source,
                                                                   std::string_view name)
{
  std::optional<std::string> msl = Util::TranslateShaderToMSL(stage, source);
  if (!msl.has_value())
  {
    PanicAlertFmt("Failed to convert shader {} to MSL", name);
    return nullptr;
  }

  return CreateShaderFromMSL(stage, std::move(*msl), source, name);
}

std::unique_ptr<AbstractShader> Metal::Gfx::CreateShaderFromBinary(ShaderStage stage,
                                                                   const void* data, size_t length,
                                                                   std::string_view name)
{
  return CreateShaderFromMSL(stage, std::string(static_cast<const char*>(data), length), {}, name);
}

// clang-format off

static const char* StageFilename(ShaderStage stage)
{
  switch (stage)
  {
  case ShaderStage::Vertex:   return "vs";
  case ShaderStage::Geometry: return "gs";
  case ShaderStage::Pixel:    return "ps";
  case ShaderStage::Compute:  return "cs";
  }
}

static NSString* GenericShaderName(ShaderStage stage)
{
  switch (stage)
  {
  case ShaderStage::Vertex:   return @"Vertex shader %d";
  case ShaderStage::Geometry: return @"Geometry shader %d";
  case ShaderStage::Pixel:    return @"Pixel shader %d";
  case ShaderStage::Compute:  return @"Compute shader %d";
  }
}

// clang-format on

std::unique_ptr<AbstractShader> Metal::Gfx::CreateShaderFromMSL(ShaderStage stage, std::string msl,
                                                                std::string_view glsl,
                                                                std::string_view name)
{
  @autoreleasepool
  {
    NSError* err = nullptr;
    auto DumpBadShader = [&](std::string_view msg) {
      static int counter = 0;
      std::string filename = VideoBackendBase::BadShaderFilename(StageFilename(stage), counter++);
      std::ofstream stream(filename);
      if (stream.good())
      {
        stream << msl << std::endl;
        stream << "/*" << std::endl;
        stream << msg << std::endl;
        stream << "Error:" << std::endl;
        stream << [[err localizedDescription] UTF8String] << std::endl;
        if (!glsl.empty())
        {
          stream << "Original GLSL:" << std::endl;
          stream << glsl << std::endl;
        }
        else
        {
          stream << "Shader was created with cached MSL so no GLSL is available." << std::endl;
        }
      }

      stream << std::endl;
      stream << "Dolphin Version: " << Common::GetScmRevStr() << std::endl;
      stream << "Video Backend: " << g_video_backend->GetDisplayName() << std::endl;
      stream << "*/" << std::endl;
      stream.close();

      PanicAlertFmt("{} (written to {})\n", msg, filename);
    };

    auto lib = MRCTransfer([g_device newLibraryWithSource:[NSString stringWithUTF8String:msl.data()]
                                                  options:({
                                                    MTLCompileOptions* opt = [MTLCompileOptions new];
#if defined(MTLLanguageVersion3_2)
                                                    if (@available(iOS 18.0, tvOS 18.0, macOS 15.0, *))
                                                      opt.languageVersion = MTLLanguageVersion3_2;
                                                    else
#endif
#if defined(MTLLanguageVersion3_1)
                                                    if (@available(iOS 17.0, tvOS 17.0, macOS 14.0, *))
                                                      opt.languageVersion = MTLLanguageVersion3_1;
                                                    else
#endif
#if defined(MTLLanguageVersion3_0)
                                                    if (@available(iOS 16.0, tvOS 16.0, macOS 13.0, *))
                                                      opt.languageVersion = MTLLanguageVersion3_0;
                                                    else
#endif
#if defined(MTLLanguageVersion2_4)
                                                    if (@available(iOS 15.0, tvOS 15.0, macOS 12.0, *))
                                                      opt.languageVersion = MTLLanguageVersion2_4;
                                                    else
#endif
#if defined(MTLLanguageVersion2_3)
                                                    if (@available(iOS 14.0, tvOS 14.0, macOS 11.0, *))
                                                      opt.languageVersion = MTLLanguageVersion2_3;
                                                    else
#endif
#if defined(MTLLanguageVersion2_2)
                                                      opt.languageVersion = MTLLanguageVersion2_2;
#endif
                                                    opt.fastMathEnabled = Config::Get(Config::GFX_HACK_FAST_MATH);
                                                    opt; })
                                                   error:&err]);
    if (err)
    {
      DumpBadShader(fmt::format("Failed to compile {}", name));
      return nullptr;
    }
    auto fn = MRCTransfer([lib newFunctionWithName:@"main0"]);
    if (!fn)
    {
      DumpBadShader(fmt::format("Shader {} is missing its main0 function", name));
      return nullptr;
    }
    if (!name.empty())
      [fn setLabel:MRCTransfer([[NSString alloc] initWithBytes:name.data()
                                                        length:name.size()
                                                      encoding:NSUTF8StringEncoding])];
    else
      [fn setLabel:[NSString stringWithFormat:GenericShaderName(stage),
                                              m_shader_counter[static_cast<u32>(stage)]++]];
    [lib setLabel:[fn label]];
    if (stage == ShaderStage::Compute)
    {
      MTLComputePipelineReflection* reflection = nullptr;
      auto desc = [MTLComputePipelineDescriptor new];
      [desc setComputeFunction:fn];
      [desc setLabel:[fn label]];
#if __has_feature(objc_arc)
#else
#endif
      if (@available(iOS 14.0, tvOS 14.0, macOS 11.0, *))
      {
        if (Metal::g_pipeline_archive)
          [desc setBinaryArchives:@[ Metal::g_pipeline_archive ]];
      }
      MRCOwned<id<MTLComputePipelineState>> pipeline =
          MRCTransfer([g_device newComputePipelineStateWithDescriptor:desc
                                                              options:MTLPipelineOptionArgumentInfo
                                                           reflection:&reflection
                                                                error:&err]);
      if (err)
      {
        DumpBadShader(fmt::format("Failed to compile compute pipeline {}", name));
        return nullptr;
      }
      return std::make_unique<ComputePipeline>(stage, reflection, std::move(msl), std::move(fn),
                                               std::move(pipeline));
    }
    return std::make_unique<Shader>(stage, std::move(msl), std::move(fn));
  }
}

std::unique_ptr<NativeVertexFormat>
Metal::Gfx::CreateNativeVertexFormat(const PortableVertexDeclaration& vtx_decl)
{
  @autoreleasepool
  {
    return std::make_unique<VertexFormat>(vtx_decl);
  }
}

std::unique_ptr<AbstractPipeline> Metal::Gfx::CreatePipeline(const AbstractPipelineConfig& config,
                                                             const void* cache_data,
                                                             size_t cache_data_length)
{
  return g_object_cache->CreatePipeline(config);
}

void Metal::Gfx::Flush()
{
  @autoreleasepool
  {
    g_state_tracker->FlushEncoders();
  }
}

void Metal::Gfx::WaitForGPUIdle()
{
  @autoreleasepool
  {
    g_state_tracker->FlushEncoders();
    if (!g_ActiveConfig.bAsyncPresent)
      g_state_tracker->WaitForFlushedEncoders();
  }
}

void Metal::Gfx::OnConfigChanged(u32 bits)
{
  AbstractGfx::OnConfigChanged(bits);

  if (bits & CONFIG_CHANGE_BIT_VSYNC)
    [m_layer setDisplaySyncEnabled:g_ActiveConfig.bVSyncActive];

  if (bits & CONFIG_CHANGE_BIT_ANISOTROPY)
  {
    g_object_cache->ReloadSamplers();
    g_state_tracker->ReloadSamplers();
  }
}

void Metal::Gfx::ClearRegion(const MathUtil::Rectangle<int>& target_rc, bool color_enable,
                             bool alpha_enable, bool z_enable, u32 color, u32 z)
{
  u32 framebuffer_width = m_current_framebuffer->GetWidth();
  u32 framebuffer_height = m_current_framebuffer->GetHeight();
  // All Metal render passes are fullscreen, so we can only run a fast clear if the target is too
  if (target_rc == MathUtil::Rectangle<int>(0, 0, framebuffer_width, framebuffer_height))
  {
    // Determine whether the EFB has an alpha channel. If it doesn't, we can clear the alpha
    // channel to 0xFF. This hopefully allows us to use the fast path in most cases.
    if (bpmem.zcontrol.pixel_format == PixelFormat::RGB565_Z16 ||
        bpmem.zcontrol.pixel_format == PixelFormat::RGB8_Z24 ||
        bpmem.zcontrol.pixel_format == PixelFormat::Z24)
    {
      // Force alpha writes, and clear the alpha channel. This is different from the other backends,
      // where the existing values of the alpha channel are preserved.
      alpha_enable = true;
      color &= 0x00FFFFFF;
    }

    bool c_ok = (color_enable && alpha_enable) ||
                g_state_tracker->GetCurrentFramebuffer()->GetColorFormat() ==
                    AbstractTextureFormat::Undefined;
    bool z_ok = z_enable || g_state_tracker->GetCurrentFramebuffer()->GetDepthFormat() ==
                                AbstractTextureFormat::Undefined;
    if (c_ok && z_ok)
    {
      @autoreleasepool
      {
        // clang-format off
        MTLClearColor clear_color = MTLClearColorMake(
            static_cast<double>((color >> 16) & 0xFF) / 255.0,
            static_cast<double>((color >>  8) & 0xFF) / 255.0,
            static_cast<double>((color >>  0) & 0xFF) / 255.0,
            static_cast<double>((color >> 24) & 0xFF) / 255.0);
        // clang-format on
        float z_normalized = static_cast<float>(z & 0xFFFFFF) / 16777216.0f;
        if (!g_Config.backend_info.bSupportsReversedDepthRange)
          z_normalized = 1.f - z_normalized;
        g_state_tracker->BeginClearRenderPass(clear_color, z_normalized);
        return;
      }
    }
  }

  g_state_tracker->EnableEncoderLabel(false);
  AbstractGfx::ClearRegion(target_rc, color_enable, alpha_enable, z_enable, color, z);
#if !defined(NDEBUG)
  g_state_tracker->EnableEncoderLabel(true);
#else
  g_state_tracker->EnableEncoderLabel(false);
#endif
}

void Metal::Gfx::SetPipeline(const AbstractPipeline* pipeline)
{
  g_state_tracker->SetPipeline(static_cast<const Pipeline*>(pipeline));
}

void Metal::Gfx::SetFramebuffer(AbstractFramebuffer* framebuffer)
{
  // Shouldn't be bound as a texture.
  if (AbstractTexture* color = framebuffer->GetColorAttachment())
    g_state_tracker->UnbindTexture(static_cast<Texture*>(color)->GetMTLTexture());
  if (AbstractTexture* depth = framebuffer->GetDepthAttachment())
    g_state_tracker->UnbindTexture(static_cast<Texture*>(depth)->GetMTLTexture());

  m_current_framebuffer = framebuffer;
  g_state_tracker->SetCurrentFramebuffer(static_cast<Framebuffer*>(framebuffer));
}

void Metal::Gfx::SetAndDiscardFramebuffer(AbstractFramebuffer* framebuffer)
{
  @autoreleasepool
  {
    SetFramebuffer(framebuffer);
    g_state_tracker->BeginRenderPass(MTLLoadActionDontCare);
  }
}

void Metal::Gfx::SetAndClearFramebuffer(AbstractFramebuffer* framebuffer,
                                        const ClearColor& color_value, float depth_value)
{
  @autoreleasepool
  {
    SetFramebuffer(framebuffer);
    MTLClearColor color =
        MTLClearColorMake(color_value[0], color_value[1], color_value[2], color_value[3]);
    g_state_tracker->BeginClearRenderPass(color, depth_value);
  }
}

void Metal::Gfx::SetScissorRect(const MathUtil::Rectangle<int>& rc)
{
  g_state_tracker->SetScissor(rc);
}

void Metal::Gfx::SetTexture(u32 index, const AbstractTexture* texture)
{
  g_state_tracker->SetTexture(
      index, texture ? static_cast<const Texture*>(texture)->GetMTLTexture() : nullptr);
}

void Metal::Gfx::SetSamplerState(u32 index, const SamplerState& state)
{
  g_state_tracker->SetSampler(index, state);
}

void Metal::Gfx::SetComputeImageTexture(u32 index, AbstractTexture* texture, bool read, bool write)
{
  g_state_tracker->SetTexture(index + VideoCommon::MAX_COMPUTE_SHADER_SAMPLERS,
                              texture ? static_cast<const Texture*>(texture)->GetMTLTexture() :
                                        nullptr);
}

void Metal::Gfx::UnbindTexture(const AbstractTexture* texture)
{
  g_state_tracker->UnbindTexture(static_cast<const Texture*>(texture)->GetMTLTexture());
}

void Metal::Gfx::SetViewport(float x, float y, float width, float height, float near_depth,
                             float far_depth)
{
  g_state_tracker->SetViewport(x, y, width, height, near_depth, far_depth);
}

void Metal::Gfx::Draw(u32 base_vertex, u32 num_vertices)
{
  @autoreleasepool
  {
    g_state_tracker->Draw(base_vertex, num_vertices);
  }
}

void Metal::Gfx::DrawIndexed(u32 base_index, u32 num_indices, u32 base_vertex)
{
  @autoreleasepool
  {
    g_state_tracker->DrawIndexed(base_index, num_indices, base_vertex);
  }
}

void Metal::Gfx::DispatchComputeShader(const AbstractShader* shader,  //
                                       u32 groupsize_x, u32 groupsize_y, u32 groupsize_z,
                                       u32 groups_x, u32 groups_y, u32 groups_z)
{
  @autoreleasepool
  {
    g_state_tracker->SetPipeline(static_cast<const ComputePipeline*>(shader));
    g_state_tracker->DispatchComputeShader(groupsize_x, groupsize_y, groupsize_z,  //
                                           groups_x, groups_y, groups_z);
  }
}

bool Metal::Gfx::BindBackbuffer(const ClearColor& clear_color)
{
  @autoreleasepool
  {
    CheckForSurfaceChange();
    CheckForSurfaceResize();
    // Fast-fail: avoid blocking waiting for a drawable when async present is enabled
    CAMetalLayer* layer = m_layer;
    if ([layer respondsToSelector:@selector(setAllowsNextDrawableTimeout:)])
      layer.allowsNextDrawableTimeout = NO;
    if ([layer respondsToSelector:@selector(setMaximumDrawableCount:)])
      layer.maximumDrawableCount = 3;
    if (@available(iOS 13.0, *))
    {
      id<CAMetalDrawable> next = [layer nextDrawable];
      if (!next && g_ActiveConfig.bAsyncPresent)
      {
        // Skip this frame to avoid stalling the CPU thread
        return false;
      }
      m_drawable = MRCRetain(next);
      // If shaders are enabled via app preferences, render to an offscreen texture,
      // then post-process into the drawable before present. Otherwise render directly.
      bool use_post = false;
      @try {
        use_post = [[NSUserDefaults standardUserDefaults] boolForKey:@"shader_enabled"];
      } @catch (...) {
        use_post = false;
      }

      if (use_post)
      {
        // Create or resize offscreen color target matching drawable
        id<MTLTexture> draw_tex = [m_drawable texture];
        MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:draw_tex.pixelFormat
                                                                                       width:draw_tex.width
                                                                                      height:draw_tex.height
                                                                                   mipmapped:NO];
        desc.storageMode = MTLStorageModePrivate;
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 140000
        desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | (MTLTextureUsage) (1 << 3);
#else
        desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
#endif
        static id<MTLTexture> s_offscreen = nil;
        if (s_offscreen == nil || s_offscreen.width != draw_tex.width || s_offscreen.height != draw_tex.height || s_offscreen.pixelFormat != draw_tex.pixelFormat)
        {
          s_offscreen = [g_device newTextureWithDescriptor:desc];
          [s_offscreen setLabel:@"Dolphin Offscreen Color for PostProcess"];
        }
        m_backbuffer->UpdateBackbufferTexture(s_offscreen);
      }
      else
      {
        m_backbuffer->UpdateBackbufferTexture([m_drawable texture]);
      }
      // Ensure the viewport matches the current render target size exactly.
      {
        id<MTLTexture> rt = [m_backbuffer->PassDesc() colorAttachments][0].texture;
        if (rt)
          g_state_tracker->SetViewport(0.0f, 0.0f, (float)rt.width, (float)rt.height, 0.0f, 1.0f);
      }
      SetAndClearFramebuffer(m_backbuffer.get(), clear_color);
      return m_drawable != nullptr;
    }
  }
}

void Metal::Gfx::PresentBackbuffer()
{
  @autoreleasepool
  {
    g_state_tracker->EndRenderPass();
    if (m_drawable)
    {
      // Decide post-processing and whether we need to blit from an offscreen target
      bool use_post = false;
      @try { use_post = [[NSUserDefaults standardUserDefaults] boolForKey:@"shader_enabled"]; } @catch (...) { use_post = false; }
      id<MTLCommandBuffer> cb = g_state_tracker->GetRenderCmdBuf();
      // Use the pass descriptor's bound color attachment (offscreen when shaders enabled) as source
      id<MTLTexture> source = [m_backbuffer->PassDesc() colorAttachments][0].texture;
      id<MTLTexture> dst = [m_drawable texture];
      // Copy from the drawable only when we rendered directly into it AND we need to sample it (post)
      static id<MTLTexture> s_src_copy = nil;
      if (use_post && dst && source == dst)
      {
        if (s_src_copy == nil || s_src_copy.width != dst.width || s_src_copy.height != dst.height || s_src_copy.pixelFormat != dst.pixelFormat)
        {
          MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:dst.pixelFormat
                                                                                           width:dst.width
                                                                                          height:dst.height
                                                                                       mipmapped:NO];
          desc.storageMode = MTLStorageModePrivate;
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 140000
          desc.usage = MTLTextureUsageShaderRead | (MTLTextureUsage) (1 << 3);
#else
          desc.usage = MTLTextureUsageShaderRead;
#endif
          s_src_copy = [g_device newTextureWithDescriptor:desc];
          [s_src_copy setLabel:@"Dolphin Post Source Copy"];
        }
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        if (blit)
        {
          [blit copyFromTexture:dst
                    sourceSlice:0
                    sourceLevel:0
                   sourceOrigin:MTLOriginMake(0, 0, 0)
                     sourceSize:MTLSizeMake(dst.width, dst.height, 1)
                      toTexture:s_src_copy
               destinationSlice:0
               destinationLevel:0
              destinationOrigin:MTLOriginMake(0, 0, 0)];
          [blit endEncoding];
          source = s_src_copy;
        }
      }
      const bool needs_blit = (source && dst && source != dst);
      // fprintf(stderr, "[Shaders] Present: use_post=%d needs_blit=%d src=%p dst=%p\n", use_post ? 1 : 0, needs_blit ? 1 : 0, (void*)source, (void*)dst);

      // Force a blit from the render target into a dedicated sampling texture to avoid tile-memory hazards
      static id<MTLTexture> s_post_src = nil;
      if (use_post && source)
      {
        if (s_post_src == nil || s_post_src.width != source.width || s_post_src.height != source.height || s_post_src.pixelFormat != source.pixelFormat)
        {
          MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:source.pixelFormat
                                                                                        width:source.width
                                                                                       height:source.height
                                                                                    mipmapped:NO];
          desc.storageMode = MTLStorageModePrivate;
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 140000
          desc.usage = MTLTextureUsageShaderRead | (MTLTextureUsage) (1 << 3);
#else
          desc.usage = MTLTextureUsageShaderRead;
#endif
          s_post_src = [g_device newTextureWithDescriptor:desc];
          [s_post_src setLabel:@"Dolphin Post Source Blit"];
        }
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        if (blit)
        {
          [blit copyFromTexture:source
                    sourceSlice:0
                    sourceLevel:0
                   sourceOrigin:MTLOriginMake(0, 0, 0)
                     sourceSize:MTLSizeMake(source.width, source.height, 1)
                      toTexture:s_post_src
               destinationSlice:0
               destinationLevel:0
              destinationOrigin:MTLOriginMake(0, 0, 0)];
          [blit endEncoding];
          source = s_post_src;
        }
      }

      // If an offscreen was used but postprocessing is disabled, blit to the drawable now.
      if (needs_blit && !use_post)
      {
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        if (blit)
        {
          [blit copyFromTexture:source
                    sourceSlice:0
                    sourceLevel:0
                   sourceOrigin:MTLOriginMake(0, 0, 0)
                     sourceSize:MTLSizeMake(source.width, source.height, 1)
                      toTexture:dst
               destinationSlice:0
               destinationLevel:0
              destinationOrigin:MTLOriginMake(0, 0, 0)];
          [blit endEncoding];
        }
      }

      if (use_post)
      {
        if (source && cb)
        {
          Class C = NSClassFromString(@"DOLShaderPostProcessor");
          if (!C)
          {
            NSString* module = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
            if (module && [module isKindOfClass:[NSString class]])
            {
              NSString* qualified = [NSString stringWithFormat:@"%@.%@", module, @"DOLShaderPostProcessor"];
              C = NSClassFromString(qualified);
              if (!C)
                fprintf(stderr, "[Shaders] Swift class not found for %s or %s\n", "DOLShaderPostProcessor", qualified.UTF8String);
            }
          }
          if (C && [C respondsToSelector:@selector(shared)])
          {
            id mgr = ((id(*)(id, SEL))[C methodForSelector:@selector(shared)])(C, @selector(shared));
            if (mgr && [mgr respondsToSelector:@selector(configureWithDevice:)])
              ((void(*)(id, SEL, id))[mgr methodForSelector:@selector(configureWithDevice:)])(mgr, @selector(configureWithDevice:), g_device);
            if (mgr && [mgr respondsToSelector:@selector(reloadShadersNow)])
              ((void(*)(id, SEL))[mgr methodForSelector:@selector(reloadShadersNow)])(mgr, @selector(reloadShadersNow));
            if (mgr && [mgr respondsToSelector:@selector(renderSource:commandBuffer:drawable:)])
            {
              // Minimal diagnostics about formats and sizes
//              fprintf(stderr, "[Shaders] Post: src %ux%u fmt=%lu -> dst %ux%u fmt=%lu\n",
//                      (unsigned)source.width, (unsigned)source.height, (unsigned long)source.pixelFormat,
//                      (unsigned)dst.width, (unsigned)dst.height, (unsigned long)dst.pixelFormat);

              ((void(*)(id, SEL, id, id, id))[mgr methodForSelector:@selector(renderSource:commandBuffer:drawable:)])(mgr, @selector(renderSource:commandBuffer:drawable:), source, cb, m_drawable);
            }
          }
          else
          {
            // Fallback: simple blit copy
            id<MTLBlitCommandEncoder> blit = [g_state_tracker->GetRenderCmdBuf() blitCommandEncoder];
            if (blit)
            {
              [blit copyFromTexture:source
                        sourceSlice:0
                        sourceLevel:0
                       sourceOrigin:MTLOriginMake(0, 0, 0)
                         sourceSize:MTLSizeMake(source.width, source.height, 1)
                          toTexture:[m_drawable texture]
                   destinationSlice:0
                   destinationLevel:0
                  destinationOrigin:MTLOriginMake(0, 0, 0)];
              [blit endEncoding];
            }
          }
        }
      }

      // PresentDrawable refuses to allow Dolphin to present faster than the display's refresh rate
      // when windowed (or fullscreen with vsync enabled, but that's more understandable).
      // On the other hand, it helps Xcode's GPU captures start and stop on frame boundaries
      // which is convenient.  Put it here as a default-off config, which we can override in Xcode.
      // It also seems to improve frame pacing, so enable it by default with vsync
      if (g_ActiveConfig.iUsePresentDrawable == TriState::On ||
          (g_ActiveConfig.iUsePresentDrawable == TriState::Auto && g_ActiveConfig.bVSyncActive))
        [g_state_tracker->GetRenderCmdBuf() presentDrawable:m_drawable];
      else
        [g_state_tracker->GetRenderCmdBuf()
            addScheduledHandler:[drawable = std::move(m_drawable)](id) { [drawable present]; }];
      m_backbuffer->UpdateBackbufferTexture(nullptr);
      m_drawable = nullptr;

      // Commit and release encoders and associated resources for this frame.
      g_state_tracker->FlushEncoders();
    }
  }
}

void Metal::Gfx::CheckForSurfaceChange()
{
  if (!g_presenter->SurfaceChangedTestAndClear())
    return;
  m_layer = MRCRetain(static_cast<CAMetalLayer*>(g_presenter->GetNewSurfaceHandle()));
  SetupSurface();
}

void Metal::Gfx::CheckForSurfaceResize()
{
  if (!g_presenter->SurfaceResizedTestAndClear())
    return;
  SetupSurface();
}

void Metal::Gfx::SetupSurface()
{
  auto info = GetSurfaceInfo();

  [m_layer setDrawableSize:{static_cast<double>(info.width), static_cast<double>(info.height)}];
  if ([m_layer respondsToSelector:@selector(setFramebufferOnly:)])
    [m_layer setFramebufferOnly:YES];
  if ([m_layer respondsToSelector:@selector(setAllowsNextDrawableTimeout:)])
    [m_layer setAllowsNextDrawableTimeout:NO];
  if ([m_layer respondsToSelector:@selector(setMaximumDrawableCount:)])
    [m_layer setMaximumDrawableCount:3];
  if ([m_layer respondsToSelector:@selector(setPresentsWithTransaction:)])
    [m_layer setPresentsWithTransaction:NO];

  TextureConfig cfg(info.width, info.height, 1, 1, 1, info.format, AbstractTextureFlag_RenderTarget,
                    AbstractTextureType::Texture_2DArray);
  m_bb_texture = std::make_unique<Texture>(nullptr, cfg);
  m_backbuffer = std::make_unique<Framebuffer>(
      m_bb_texture.get(), nullptr, std::vector<AbstractTexture*>{}, info.width, info.height, 1, 1);

  if (g_presenter)
    g_presenter->SetBackbuffer(info);
}

SurfaceInfo Metal::Gfx::GetSurfaceInfo() const
{
  if (!m_layer)  // Headless
    return {};

  const CGSize drawable = [m_layer drawableSize];
  const float scale = [m_layer contentsScale];
  return {static_cast<u32>(drawable.width), static_cast<u32>(drawable.height), scale,
          Util::ToAbstract([m_layer pixelFormat])};
}

bool Metal::Gfx::TryComputeBlitRGBA8(AbstractTexture* dst, const MathUtil::Rectangle<int>& dst_rc,
                                      const AbstractTexture* src,
                                      const MathUtil::Rectangle<int>& src_rc)
{
  if (!dst || !src)
    return false;
  if (dst_rc.GetWidth() != src_rc.GetWidth() || dst_rc.GetHeight() != src_rc.GetHeight())
    return false;
  @autoreleasepool
  {
    // Detect MSAA source
    id<MTLTexture> src_tex = static_cast<const Texture*>(src)->GetMTLTexture();
    id<MTLTexture> dst_tex = static_cast<Texture*>(dst)->GetMTLTexture();
    if (!src_tex || !dst_tex)
      return false;

    // MSAA resolve path
    if (src_tex.sampleCount > 1)
    {
      static std::unique_ptr<AbstractShader> s_resolve_ms_cs;
      if (!s_resolve_ms_cs)
      {
        static const char* msl_ms = R"(
          #include <metal_stdlib>
          using namespace metal;
          kernel void main0(texture2d_ms<float, access::read>  src  [[texture(0)]],
                            texture2d<float,    access::write> dst  [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]])
          {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
            const ushort samples = src.get_num_samples();
            float4 acc = float4(0.0);
            for (ushort s = 0; s < samples; ++s)
              acc += src.read(gid, s);
            dst.write(acc / float(samples), gid);
          }
        )";
        auto cs = CreateShaderFromMSL(ShaderStage::Compute, msl_ms, "", "resolve_rgba8_ms");
        if (!cs)
          return false;
        s_resolve_ms_cs = std::move(cs);
      }
      SetComputeImageTexture(0, const_cast<AbstractTexture*>(src), true, false);
      SetComputeImageTexture(1, dst, false, true);
      const u32 w = static_cast<u32>(dst_rc.GetWidth());
      const u32 h = static_cast<u32>(dst_rc.GetHeight());
      const u32 tgx = 16, tgy = 16;
      const u32 gx = (w + tgx - 1) / tgx;
      const u32 gy = (h + tgy - 1) / tgy;
      DispatchComputeShader(s_resolve_ms_cs.get(), tgx, tgy, 1, gx, gy, 1);
      return true;
    }

    // Non-MSAA copy path
    if (!m_rgba8_blit_cs)
    {
      static const char* msl = R"(
        #include <metal_stdlib>
        using namespace metal;
        kernel void main0(texture2d<float, access::read>  src  [[texture(0)]],
                          texture2d<float, access::write> dst  [[texture(1)]],
                          uint2 gid [[thread_position_in_grid]])
        {
          if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
          float4 c = src.read(gid);
          dst.write(c, gid);
        }
      )";
      auto cs = CreateShaderFromMSL(ShaderStage::Compute, msl, "", "blit_rgba8");
      if (!cs)
        return false;
      m_rgba8_blit_cs = std::move(cs);
    }
    SetComputeImageTexture(0, const_cast<AbstractTexture*>(src), true, false);
    SetComputeImageTexture(1, dst, false, true);
    const u32 w = static_cast<u32>(dst_rc.GetWidth());
    const u32 h = static_cast<u32>(dst_rc.GetHeight());
    const u32 tgx = 16;
    const u32 tgy = 16;
    const u32 gx = (w + tgx - 1) / tgx;
    const u32 gy = (h + tgy - 1) / tgy;
    DispatchComputeShader(m_rgba8_blit_cs.get(), tgx, tgy, 1, gx, gy, 1);
    return true;
  }
}

void Metal::Gfx::GenerateMipmaps(AbstractTexture* texture)
{
  if (!texture)
    return;
  @autoreleasepool
  {
    g_state_tracker->EndRenderPass();
    id<MTLTexture> tex = static_cast<Texture*>(texture)->GetMTLTexture();
    if (!tex || tex.mipmapLevelCount <= 1)
      return;
    id<MTLCommandBuffer> cb = g_state_tracker->GetRenderCmdBuf();
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    if (!blit)
      return;
    [blit generateMipmapsForTexture:tex];
    [blit endEncoding];
  }
}
