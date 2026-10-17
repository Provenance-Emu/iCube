// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

// iCube: MetalFX spatial upscaling of the XFB to the screen picture at present time. Built only where CMake
// defines ICUBE_METALFX (iOS): Apple TV GPUs don't support MetalFX, and the tvOS slice must not
// link the framework.

#pragma once

#include <Metal/Metal.h>

#include <memory>

#include "Common/CommonTypes.h"
#include "Common/MathUtil.h"
#include "VideoBackends/Metal/MRCHelpers.h"

class AbstractTexture;
@protocol MTLFXSpatialScaler;

namespace Metal
{
class Texture;

class SpatialUpscaler
{
public:
  SpatialUpscaler();
  ~SpatialUpscaler();

  // Whether this device can run the MetalFX spatial scaler at all.
  static bool IsSupported();

  // Upscales source_rc of source to out_width x out_height on its own command buffer, after
  // flushing the work that produced source. Returns nullptr when the scaler can't be built.
  const AbstractTexture* Upscale(const AbstractTexture* source,
                                 const MathUtil::Rectangle<int>& source_rc, u32 out_width,
                                 u32 out_height);

private:
  bool EnsureResources(const AbstractTexture* source, u32 in_width, u32 in_height, u32 out_width,
                       u32 out_height);

  MRCOwned<id<MTLFXSpatialScaler>> m_scaler;
  MRCOwned<id<MTLTexture>> m_input;
  MRCOwned<id<MTLTexture>> m_output_2d;  // 2D view of m_output's single layer, for MetalFX
  std::unique_ptr<Texture> m_output;     // 2D array, what Dolphin's blit shaders sample
  MTLPixelFormat m_format = MTLPixelFormatInvalid;
  u32 m_in_width = 0;
  u32 m_in_height = 0;
  u32 m_out_width = 0;
  u32 m_out_height = 0;
  // Building the scaler failed for this configuration; don't retry until it changes.
  bool m_failed = false;
};
}  // namespace Metal
