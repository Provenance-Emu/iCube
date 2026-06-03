// Copyright 2022 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <memory>

#include "VideoBackends/Metal/MTLUtil.h"
#include "VideoCommon/VertexManagerBase.h"

class AbstractShader;

namespace Metal
{
class VertexManager final : public VertexManagerBase
{
public:
  VertexManager();
  ~VertexManager() override;

  void UploadUtilityUniforms(const void* uniforms, u32 uniforms_size) override;
  bool UploadTexelBuffer(const void* data, u32 data_size, TexelBufferFormat format,
                         u32* out_offset) override;
  bool UploadTexelBuffer(const void* data, u32 data_size, TexelBufferFormat format, u32* out_offset,
                         const void* palette_data, u32 palette_size,
                         TexelBufferFormat palette_format, u32* out_palette_offset) override;

  // iCube (jitless) GPU-compute vertex decode (see VertexManagerBase for the contract).
  bool TryComputeDecodeVertices(VertexLoaderBase* loader, const u8* src, u8* dst,
                                int count) override;

protected:
  void ResetBuffer(u32 vertex_stride) override;
  void CommitBuffer(u32 num_vertices, u32 vertex_stride, u32 num_indices, u32* out_base_vertex,
                    u32* out_base_index) override;
  void UploadUniforms() override;

private:
  u32 m_vertex_offset;
  u32 m_base_vertex;
  // iCube (jitless): lazily-built compute pipeline for GPU vertex decode.
  std::unique_ptr<AbstractShader> m_compute_vertex_decode_cs;
};
}  // namespace Metal
