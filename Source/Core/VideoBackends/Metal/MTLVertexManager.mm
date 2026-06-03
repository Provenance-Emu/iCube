// Copyright 2022 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "VideoBackends/Metal/MTLVertexManager.h"

#include <cstring>
#include <memory>

#include "Core/System.h"

#include "VideoBackends/Metal/MTLGfx.h"
#include "VideoBackends/Metal/MTLPipeline.h"
#include "VideoBackends/Metal/MTLStateTracker.h"

#include "VideoCommon/AbstractGfx.h"
#include "VideoCommon/AbstractShader.h"
#include "VideoCommon/GeometryShaderManager.h"
#include "VideoCommon/PixelShaderManager.h"
#include "VideoCommon/Statistics.h"
#include "VideoCommon/VertexLoaderBase.h"
#include "VideoCommon/VertexShaderManager.h"

Metal::VertexManager::VertexManager()
{
}

Metal::VertexManager::~VertexManager() = default;

void Metal::VertexManager::UploadUtilityUniforms(const void* uniforms, u32 uniforms_size)
{
  g_state_tracker->SetUtilityUniform(uniforms, uniforms_size);
}

bool Metal::VertexManager::UploadTexelBuffer(const void* data, u32 data_size,
                                             TexelBufferFormat format, u32* out_offset)
{
  *out_offset = 0;
  StateTracker::Map map = g_state_tracker->Allocate(StateTracker::UploadBuffer::Texels, data_size,
                                                    StateTracker::AlignMask::Other);
  memcpy(map.cpu_buffer, data, data_size);
  g_state_tracker->SetTexelBuffer(map.gpu_buffer, map.gpu_offset, 0);
  return true;
}

bool Metal::VertexManager::UploadTexelBuffer(const void* data, u32 data_size,
                                             TexelBufferFormat format, u32* out_offset,
                                             const void* palette_data, u32 palette_size,
                                             TexelBufferFormat palette_format,
                                             u32* out_palette_offset)
{
  *out_offset = 0;
  *out_palette_offset = 0;

  const u32 aligned_data_size = g_state_tracker->Align(data_size, StateTracker::AlignMask::Other);
  const u32 total_size = aligned_data_size + palette_size;
  StateTracker::Map map = g_state_tracker->Allocate(StateTracker::UploadBuffer::Texels, total_size,
                                                    StateTracker::AlignMask::Other);
  memcpy(map.cpu_buffer, data, data_size);
  memcpy(static_cast<char*>(map.cpu_buffer) + aligned_data_size, palette_data, palette_size);
  g_state_tracker->SetTexelBuffer(map.gpu_buffer, map.gpu_offset,
                                  map.gpu_offset + aligned_data_size);
  return true;
}

void Metal::VertexManager::ResetBuffer(u32 vertex_stride)
{
  const u32 max_vertex_size = 65535 * vertex_stride;
  const u32 vertex_alloc = max_vertex_size + vertex_stride - 1;  // for alignment
  auto vertex = g_state_tracker->Preallocate(StateTracker::UploadBuffer::Vertex, vertex_alloc);
  auto index =
      g_state_tracker->Preallocate(StateTracker::UploadBuffer::Index, MAXIBUFFERSIZE * sizeof(u16));

  // Align the base vertex
  m_base_vertex = (vertex.second + vertex_stride - 1) / vertex_stride;
  m_vertex_offset = m_base_vertex * vertex_stride - vertex.second;
  m_cur_buffer_pointer = m_base_buffer_pointer = static_cast<u8*>(vertex.first) + m_vertex_offset;
  m_end_buffer_pointer = m_base_buffer_pointer + max_vertex_size;
  m_index_generator.Start(static_cast<u16*>(index.first));
}

void Metal::VertexManager::CommitBuffer(u32 num_vertices, u32 vertex_stride, u32 num_indices,
                                        u32* out_base_vertex, u32* out_base_index)
{
  const u32 vsize = num_vertices * vertex_stride + m_vertex_offset;
  const u32 isize = num_indices * sizeof(u16);
  StateTracker::Map vmap = g_state_tracker->CommitPreallocation(
      StateTracker::UploadBuffer::Vertex, vsize, StateTracker::AlignMask::None);
  StateTracker::Map imap = g_state_tracker->CommitPreallocation(
      StateTracker::UploadBuffer::Index, isize, StateTracker::AlignMask::None);

  ADDSTAT(g_stats.this_frame.bytes_vertex_streamed, vsize);
  ADDSTAT(g_stats.this_frame.bytes_index_streamed, isize);

  DEBUG_ASSERT(vmap.gpu_offset + m_vertex_offset == m_base_vertex * vertex_stride);
  g_state_tracker->SetVerticesAndIndices(vmap.gpu_buffer, imap.gpu_buffer);
  *out_base_vertex = m_base_vertex;
  *out_base_index = imap.gpu_offset / sizeof(u16);
}

void Metal::VertexManager::UploadUniforms()
{
  auto& system = Core::System::GetInstance();
  auto& vertex_shader_manager = system.GetVertexShaderManager();
  auto& geometry_shader_manager = system.GetGeometryShaderManager();
  auto& pixel_shader_manager = system.GetPixelShaderManager();
  g_state_tracker->InvalidateUniforms(vertex_shader_manager.dirty, geometry_shader_manager.dirty,
                                      pixel_shader_manager.dirty);
  vertex_shader_manager.dirty = false;
  geometry_shader_manager.dirty = false;
  pixel_shader_manager.dirty = false;
}

// iCube (jitless) GPU-compute vertex decode.
//
// Handles the simplest fully-direct format (position Direct/Float/XYZ, nothing else) which
// VertexLoaderBase::GetComputeDecodeInfo() validates. For that case the native vertex is just a
// big-endian -> little-endian float3 copy of the raw stream, so the kernel is trivial and provably
// matches the CPU loader byte-for-byte. The per-vertex CPU side effects (position cache) are
// reproduced by the caller (VertexLoaderManager) re-running the CPU loader over the trailing three
// vertices. Returns false for everything else (other formats, or when manual buffer upload is on,
// since then the draw reads a separate gpubuffer the kernel does not write).
namespace
{
// Layout must match the MSL kernel's `Constants` below.
struct VertexDecodeConstants
{
  u32 vertex_count;
  u32 src_stride;
  u32 dst_stride;
  u32 position_offset;
};

const char* const VERTEX_DECODE_MSL = R"(
  #include <metal_stdlib>
  using namespace metal;
  struct Constants {
    uint vertex_count;
    uint src_stride;
    uint dst_stride;
    uint position_offset;
  };
  // Big-endian float read from a byte stream.
  static inline float read_be_float(device const uchar* p) {
    uint v = (uint(p[0]) << 24) | (uint(p[1]) << 16) | (uint(p[2]) << 8) | uint(p[3]);
    return as_type<float>(v);
  }
  kernel void main0(constant Constants&     c   [[buffer(0)]],
                    device const uchar*     src [[buffer(1)]],
                    device uchar*           dst [[buffer(2)]],
                    uint gid [[thread_position_in_grid]])
  {
    if (gid >= c.vertex_count) return;
    device const uchar* in_v  = src + gid * c.src_stride;            // position is at stream offset 0
    device uchar*       out_p = dst + gid * c.dst_stride + c.position_offset;
    // Three native little-endian floats, byteswapped from the big-endian source.
    float3 pos = float3(read_be_float(in_v + 0), read_be_float(in_v + 4), read_be_float(in_v + 8));
    device float* out_f = reinterpret_cast<device float*>(out_p);
    out_f[0] = pos.x;
    out_f[1] = pos.y;
    out_f[2] = pos.z;
  }
)";
}  // namespace

bool Metal::VertexManager::TryComputeDecodeVertices(VertexLoaderBase* loader, const u8* src, u8* dst,
                                                    int count)
{
  // The compute write targets the streaming Vertex cpubuffer, which the following draw only reads
  // directly when manual buffer upload is off (iOS unified memory). Otherwise bail to the CPU path.
  if (g_state_tracker->IsManualBufferUpload())
    return false;

  const VertexLoaderBase::ComputeDecodeInfo info = loader->GetComputeDecodeInfo();
  if (!info.supported)
    return false;

  // Probe call (count == 0): the caller only wants to know whether we can handle this format.
  if (count <= 0 || src == nullptr || dst == nullptr)
    return count == 0;  // count==0 is the format probe; a real call with no data is a no-op failure

  // Lazily build and cache the decode pipeline.
  if (!m_compute_vertex_decode_cs)
  {
    auto* gfx = static_cast<Metal::Gfx*>(g_gfx.get());
    if (!gfx)
      return false;
    auto cs = gfx->CreateShaderFromMSL(ShaderStage::Compute, VERTEX_DECODE_MSL, "",
                                       "vertex_decode_pos3f");
    if (!cs)
      return false;
    m_compute_vertex_decode_cs = std::move(cs);
  }

  @autoreleasepool
  {
    // Upload the raw vertex stream into a GPU-readable buffer (the texel streaming buffer, which on
    // iOS is shared storage and thus directly readable by the compute kernel).
    const u32 src_size = info.src_stride * static_cast<u32>(count);
    StateTracker::Map src_map = g_state_tracker->Allocate(
        StateTracker::UploadBuffer::Texels, src_size, StateTracker::AlignMask::Other);
    std::memcpy(src_map.cpu_buffer, src, src_size);

    // Map the destination native pointer (inside the Vertex cpubuffer) back to a buffer offset.
    auto* base = static_cast<u8*>(g_state_tracker->GetVertexUploadBufferContents());
    id<MTLBuffer> vtx_buffer = g_state_tracker->GetVertexUploadBuffer();
    if (!base || !vtx_buffer || dst < base)
      return false;
    const u32 out_offset = static_cast<u32>(dst - base);

    VertexDecodeConstants constants;
    constants.vertex_count = static_cast<u32>(count);
    constants.src_stride = info.src_stride;
    constants.dst_stride = info.dst_stride;
    constants.position_offset = info.position_offset;

    g_state_tracker->DispatchVertexDecode(
        static_cast<const ComputePipeline*>(m_compute_vertex_decode_cs.get()), src_map.gpu_buffer,
        static_cast<u32>(src_map.gpu_offset), out_offset, &constants, sizeof(constants),
        static_cast<u32>(count), 64);
  }
  return true;
}
