// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "VideoBackends/Metal/MTLSpatialUpscaler.h"

#include <MetalFX/MetalFX.h>

#include "Common/Logging/Log.h"

#include "VideoBackends/Metal/MTLGfx.h"
#include "VideoBackends/Metal/MTLObjectCache.h"
#include "VideoBackends/Metal/MTLStateTracker.h"
#include "VideoBackends/Metal/MTLTexture.h"
#include "VideoBackends/Metal/MTLUtil.h"

#include "VideoCommon/TextureConfig.h"

namespace Metal
{
SpatialUpscaler::SpatialUpscaler() = default;

SpatialUpscaler::~SpatialUpscaler() = default;

bool SpatialUpscaler::IsSupported()
{
  return [MTLFXSpatialScalerDescriptor supportsDevice:g_device];
}

bool SpatialUpscaler::EnsureResources(const AbstractTexture* source, u32 in_width, u32 in_height,
                                      u32 out_width, u32 out_height)
{
  const MTLPixelFormat format = Util::FromAbstract(source->GetFormat());
  if (format == m_format && in_width == m_in_width && in_height == m_in_height &&
      out_width == m_out_width && out_height == m_out_height)
  {
    return !m_failed;
  }

  m_format = format;
  m_in_width = in_width;
  m_in_height = in_height;
  m_out_width = out_width;
  m_out_height = out_height;
  m_scaler = nullptr;
  m_input = nullptr;
  m_output_2d = nullptr;
  m_output.reset();
  m_failed = true;

  @autoreleasepool
  {
    MRCOwned<MTLFXSpatialScalerDescriptor*> desc =
        MRCTransfer([MTLFXSpatialScalerDescriptor new]);
    [desc setColorTextureFormat:format];
    [desc setOutputTextureFormat:format];
    [desc setInputWidth:in_width];
    [desc setInputHeight:in_height];
    [desc setOutputWidth:out_width];
    [desc setOutputHeight:out_height];
    // The XFB holds gamma-encoded RGBA8.
    [desc setColorProcessingMode:MTLFXSpatialScalerColorProcessingModePerceptual];
    MRCOwned<id<MTLFXSpatialScaler>> scaler =
        MRCTransfer([desc newSpatialScalerWithDevice:g_device]);
    if (!scaler)
    {
      WARN_LOG_FMT(VIDEO, "MetalFX: no spatial scaler for {}x{} -> {}x{}, format {}", in_width,
                   in_height, out_width, out_height, static_cast<u32>(format));
      return false;
    }

    MTLTextureDescriptor* in_desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                           width:in_width
                                                          height:in_height
                                                       mipmapped:NO];
    [in_desc setStorageMode:MTLStorageModePrivate];
    [in_desc setUsage:[scaler colorTextureUsage] | MTLTextureUsageShaderRead];
    MRCOwned<id<MTLTexture>> input = MRCTransfer([g_device newTextureWithDescriptor:in_desc]);

    // Dolphin's blit shaders sample texture2d_array; MetalFX writes a plain 2D texture. One
    // single-layer array texture serves both through a 2D view.
    MRCOwned<MTLTextureDescriptor*> out_desc = MRCTransfer([MTLTextureDescriptor new]);
    [out_desc setTextureType:MTLTextureType2DArray];
    [out_desc setPixelFormat:format];
    [out_desc setWidth:out_width];
    [out_desc setHeight:out_height];
    [out_desc setArrayLength:1];
    [out_desc setStorageMode:MTLStorageModePrivate];
    [out_desc setUsage:[scaler outputTextureUsage] | MTLTextureUsageShaderRead];
    MRCOwned<id<MTLTexture>> output = MRCTransfer([g_device newTextureWithDescriptor:out_desc]);
    if (!input || !output)
      return false;
    [input setLabel:@"MetalFX Input"];
    [output setLabel:@"MetalFX Output"];

    MRCOwned<id<MTLTexture>> output_2d =
        MRCTransfer([output newTextureViewWithPixelFormat:format
                                              textureType:MTLTextureType2D
                                                   levels:NSMakeRange(0, 1)
                                                   slices:NSMakeRange(0, 1)]);
    if (!output_2d)
      return false;

    const TextureConfig config(out_width, out_height, 1, 1, 1, source->GetFormat(),
                               AbstractTextureFlag_RenderTarget,
                               AbstractTextureType::Texture_2DArray);
    m_output = std::make_unique<Texture>(std::move(output), config);
    m_output_2d = std::move(output_2d);
    m_input = std::move(input);
    m_scaler = std::move(scaler);
  }

  INFO_LOG_FMT(VIDEO, "MetalFX: spatial scaler {}x{} -> {}x{}", in_width, in_height, out_width,
               out_height);
  m_failed = false;
  return true;
}

const AbstractTexture* SpatialUpscaler::Upscale(const AbstractTexture* source,
                                                const MathUtil::Rectangle<int>& source_rc,
                                                u32 out_width, u32 out_height)
{
  if (source->GetSamples() != 1 || source_rc.left < 0 || source_rc.top < 0 ||
      source_rc.right > static_cast<int>(source->GetWidth()) ||
      source_rc.bottom > static_cast<int>(source->GetHeight()))
  {
    return nullptr;
  }

  const u32 in_width = static_cast<u32>(source_rc.GetWidth());
  const u32 in_height = static_cast<u32>(source_rc.GetHeight());
  if (!EnsureResources(source, in_width, in_height, out_width, out_height))
    return nullptr;

  @autoreleasepool
  {
    // The XFB was produced on the current render command buffer; submit it first so this one,
    // committed after it on the same queue, sees the finished picture.
    g_state_tracker->FlushEncoders();

    id<MTLCommandBuffer> cmdbuf = [g_queue commandBuffer];
    [cmdbuf setLabel:@"MetalFX Upscale"];

    // Copying the visible rect into a 2D texture also drops the XFB's crop offset and padding.
    id<MTLBlitCommandEncoder> blit = [cmdbuf blitCommandEncoder];
    [blit copyFromTexture:static_cast<const Texture*>(source)->GetMTLTexture()
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(source_rc.left, source_rc.top, 0)
               sourceSize:MTLSizeMake(in_width, in_height, 1)
                toTexture:m_input
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];

    id<MTLFXSpatialScaler> scaler = m_scaler;
    [scaler setColorTexture:m_input];
    [scaler setOutputTexture:m_output_2d];
    [scaler setInputContentWidth:in_width];
    [scaler setInputContentHeight:in_height];
    [scaler encodeToCommandBuffer:cmdbuf];

    [cmdbuf addCompletedHandler:^(id<MTLCommandBuffer> buf) { AddGPUTime(buf, true); }];
    [cmdbuf commit];
  }

  return m_output.get();
}
}  // namespace Metal
