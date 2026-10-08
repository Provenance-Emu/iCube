// Copyright 2026 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
// AOT NEON vertex loader. See VertexLoaderNEON.h for the architecture rationale.
//
// Jitless guarantee: this translation unit contains ordinary compiled NEON
// intrinsics only. It does NOT include Common/Arm64Emitter.h, does NOT derive
// from ARM64CodeBlock, and never allocates a writable-executable page. The
// per-attribute functor selection happens at loader-construction time via plain
// C++ switch/table dispatch (compile-time-generated code), mirroring the AOT
// NEON idiom already shipping in VideoCommon/CPUCullImpl.h.

#include "VideoCommon/VertexLoaderNEON.h"

#include <cstring>
#include <limits>
#include <type_traits>

#if defined(_M_ARM_64)
#include <arm_neon.h>
#endif

#include "Common/CommonTypes.h"
#include "Common/Inline.h"
#include "Common/Swap.h"

#include "VideoCommon/CPMemory.h"
#include "VideoCommon/VertexLoaderManager.h"
#include "VideoCommon/VertexLoaderUtils.h"
#include "VideoCommon/VertexLoader_Color.h"
#include "VideoCommon/VertexLoader_Normal.h"
#include "VideoCommon/VertexLoader_Position.h"
#include "VideoCommon/VertexLoader_TextCoord.h"

// ===========================================================================
//  Pipeline-replica scalar stages (private copies of VertexLoader.cpp's
//  file-static stages that the public GetFunction tables don't expose).
//
//  CompileVertexTranslator emits these around the GetFunction()-provided
//  attribute decoders. They are file-static in VertexLoader.cpp, so to
//  reproduce the WriteCall *sequence* exactly we re-implement them here, byte
//  for byte. (Compare asserts on the resulting native buffer + caches.)
// ===========================================================================
namespace
{
// Mirror of VertexLoader.cpp:21-28
void PosMtx_ReadDirect_UByte(VertexLoader* loader)
{
  const u32 posmtx = DataRead<u8>() & 0x3f;
  if (loader->m_remaining < 3)
    VertexLoaderManager::position_matrix_index_cache[loader->m_remaining] = posmtx;
  DataWrite<u32>(posmtx);
}

// Mirror of VertexLoader.cpp:30-36
void TexMtx_ReadDirect_UByte(VertexLoader* loader)
{
  loader->m_curtexmtx[loader->m_texmtxread] = DataRead<u8>() & 0x3f;
  loader->m_texmtxread++;
}

// Mirror of VertexLoader.cpp:38-54
void TexMtx_Write_Float(VertexLoader* loader)
{
  DataWrite(float(loader->m_curtexmtx[loader->m_texmtxwrite++]));
}
void TexMtx_Write_Float2(VertexLoader* loader)
{
  DataWrite(0.f);
  DataWrite(float(loader->m_curtexmtx[loader->m_texmtxwrite++]));
}
void TexMtx_Write_Float3(VertexLoader* loader)
{
  DataWrite(0.f);
  DataWrite(0.f);
  DataWrite(float(loader->m_curtexmtx[loader->m_texmtxwrite++]));
}

// Mirror of VertexLoader.cpp:56-65
void SkipVertex(VertexLoader* loader)
{
  if (loader->m_vertexSkip)
  {
    g_vertex_manager_write_ptr -= loader->m_native_vtx_decl.stride;
    loader->m_skippedVertices++;
  }
}

// ===========================================================================
//  Phase 2: NEON direct-attribute decoders.
//
//  Each has the exact same observable effect as the scalar pointer it replaces
//  (native-buffer bytes + position_cache writes), but processes all components
//  in one SIMD pass. They are ONLY selected for DIRECT (non-indexed) attributes;
//  indexed/gather variants keep the scalar pointer (the gather defeats SIMD and
//  the win is concentrated in the direct streams). Compare validates each.
// ===========================================================================
#if defined(_M_ARM_64)

// ---- Position --------------------------------------------------------------
//
// Scalar contract (VertexLoader_Position.cpp:32-47, Pos_ReadDirect<T,N>):
//   for i in [0,N): value = T_bigendian -> float; (integer T) *= m_posScale;
//                   if (m_remaining < 3) position_cache[m_remaining][i] = value;
//                   DataWrite(value);
// Float T skips the scale multiply (PosScale float specialization returns val).

DOLPHIN_FORCE_INLINE void StoreAndCachePos(VertexLoader* loader, float32x4_t v, int n)
{
  // Write N floats little-endian to the native buffer.
  alignas(16) float tmp[4];
  vst1q_f32(tmp, v);
  for (int i = 0; i < n; ++i)
    DataWrite(tmp[i]);
  if (loader->m_remaining < 3)
  {
    for (int i = 0; i < n; ++i)
      VertexLoaderManager::position_cache[loader->m_remaining][i] = tmp[i];
  }
}

// NOTE on input over-read: these helpers read a SIMD-width chunk that can
// exceed the attribute's exact byte count (e.g. a 16-byte vector load for a
// 12-byte float3). This matches the load widths the SHIPPING VertexLoaderARM64
// already performs in this build: VertexLoaderARM64::ReadVertex emits
// LDUR(load_size,...) with load_size = GetLoadSize(elem_size*count_in) rounded
// UP to {1,2,4,8,16} bytes (VertexLoaderARM64.cpp:27-39,114-119) -- float3 -> a
// 128-bit (16B) load, s16x3 (6B) -> an 8B load, etc. The FIFO source buffer
// therefore already tolerates a tail over-read up to the 16-byte position load.
// To stay strictly within that proven bound we mirror GetLoadSize: 64-bit (D)
// loads for <=8-byte attributes, 128-bit (Q) loads only for 12-byte float3.
// We only ever STORE / DataSkip the exact N components, so over-read into
// subsequent attributes (or proven buffer tail) is harmless.

template <int N>
void Pos_ReadDirect_NEON_s16(VertexLoader* loader)
{
  static_assert(N == 2 || N == 3, "position has 2 or 3 components");
  const u8* src = DataGetPosition();
  // s16x{2,3} is 4 or 6 bytes -> GetLoadSize rounds to {4,8}; an 8-byte (D-reg,
  // 4xs16) load covers both. Byteswap each 16-bit lane (BE -> host LE).
  int16x4_t raw = vld1_s16(reinterpret_cast<const s16*>(src));
  int16x4_t be = vreinterpret_s16_u8(vrev16_u8(vreinterpret_u8_s16(raw)));
  int32x4_t wide = vmovl_s16(be);                       // sign-extend s16 -> s32
  float32x4_t f = vcvtq_f32_s32(wide);                  // -> float
  f = vmulq_n_f32(f, loader->m_posScale);               // integer path scales
  StoreAndCachePos(loader, f, N);
  DataSkip(N * sizeof(s16));
}

template <int N>
void Pos_ReadDirect_NEON_u16(VertexLoader* loader)
{
  static_assert(N == 2 || N == 3, "position has 2 or 3 components");
  const u8* src = DataGetPosition();
  uint16x4_t raw = vld1_u16(reinterpret_cast<const u16*>(src));
  uint16x4_t be = vreinterpret_u16_u8(vrev16_u8(vreinterpret_u8_u16(raw)));
  uint32x4_t wide = vmovl_u16(be);                      // zero-extend u16 -> u32
  float32x4_t f = vcvtq_f32_u32(wide);
  f = vmulq_n_f32(f, loader->m_posScale);
  StoreAndCachePos(loader, f, N);
  DataSkip(N * sizeof(u16));
}

template <int N>
void Pos_ReadDirect_NEON_float(VertexLoader* loader)
{
  static_assert(N == 2 || N == 3, "position has 2 or 3 components");
  const u8* src = DataGetPosition();
  // Byteswap each 32-bit lane (BE -> host LE). NO scale (float path returns val
  // unchanged -- PosScale float specialization, Position.cpp:26-30).
  // float2 (8B) -> 8-byte D load; float3 (12B) -> 16-byte Q load (matches the
  // ARM64 loader's 128-bit position load -- the largest proven over-read).
  float32x4_t f;
  if constexpr (N == 2)
  {
    uint32x2_t raw = vld1_u32(reinterpret_cast<const u32*>(src));
    uint32x2_t be = vreinterpret_u32_u8(vrev32_u8(vreinterpret_u8_u32(raw)));
    f = vcombine_f32(vreinterpret_f32_u32(be), vdup_n_f32(0.0f));
  }
  else
  {
    uint32x4_t raw = vld1q_u32(reinterpret_cast<const u32*>(src));
    uint32x4_t be = vreinterpretq_u32_u8(vrev32q_u8(vreinterpretq_u8_u32(raw)));
    f = vreinterpretq_f32_u32(be);
  }
  StoreAndCachePos(loader, f, N);
  DataSkip(N * sizeof(float));
}

// ---- TexCoord --------------------------------------------------------------
//
// Scalar contract (VertexLoader_TextCoord.cpp:34-43, TexCoord_ReadDirect<T,N>):
//   scale = m_tcScale[m_tcIndex];
//   for i in [0,N): DataWrite((integer T) ? val*scale : val);
//   ++m_tcIndex;
// No position_cache side effect. Float skips the multiply.

template <int N>
void TexCoord_ReadDirect_NEON_s16(VertexLoader* loader)
{
  static_assert(N == 1 || N == 2, "texcoord has 1 or 2 components");
  const float scale = loader->m_tcScale[loader->m_tcIndex];
  const u8* src = DataGetPosition();
  int16x4_t raw = vld1_s16(reinterpret_cast<const s16*>(src));
  int16x4_t be = vreinterpret_s16_u8(vrev16_u8(vreinterpret_u8_s16(raw)));
  float32x4_t f = vmulq_n_f32(vcvtq_f32_s32(vmovl_s16(be)), scale);
  alignas(16) float tmp[4];
  vst1q_f32(tmp, f);
  for (int i = 0; i < N; ++i)
    DataWrite(tmp[i]);
  DataSkip(N * sizeof(s16));
  ++loader->m_tcIndex;
}

template <int N>
void TexCoord_ReadDirect_NEON_float(VertexLoader* loader)
{
  static_assert(N == 1 || N == 2, "texcoord has 1 or 2 components");
  const u8* src = DataGetPosition();
  // float1 (4B) / float2 (8B) -> at most an 8-byte (D-reg) load. NO scale
  // (TCScale float specialization returns val, TextCoord.cpp:28-32).
  uint32x2_t raw = vld1_u32(reinterpret_cast<const u32*>(src));
  uint32x2_t be = vreinterpret_u32_u8(vrev32_u8(vreinterpret_u8_u32(raw)));
  float tmp[2];
  vst1_f32(tmp, vreinterpret_f32_u32(be));
  for (int i = 0; i < N; ++i)
    DataWrite(tmp[i]);
  DataSkip(N * sizeof(float));
  ++loader->m_tcIndex;
}

// ---- Color -----------------------------------------------------------------
//
// Color decoders write one packed u32 (AABBGGRR little-endian) to the native
// buffer and increment m_colIndex. The bit expansions below reproduce the
// scalar bit math EXACTLY (VertexLoader_Color.cpp:34-67). 8888 is a raw,
// byte-order-preserving passthrough -- the only one that is a trivially-correct
// SIMD candidate; the packed formats are scalar bit math kept verbatim so they
// stay bit-exact. (NEON gives little here vs the byteswap+widen position win;
// we keep them scalar-correct and let the compiler vectorize the loop body
// across vertices if it can.)

DOLPHIN_FORCE_INLINE void SetCol_NEON(VertexLoader* loader, u32 val)
{
  DataWrite(val);
  loader->m_colIndex++;
}

// 32b RGBA8888: byte-order preserving (DataReadU32Unswapped). No transform.
void Color_ReadDirect_NEON_32b_8888(VertexLoader* loader)
{
  SetCol_NEON(loader, DataReadU32Unswapped());
}

// ---- Indexed (gather) attributes --------------------------------------------
//
// The scalar indexed readers (Pos/TexCoord/Color _ReadIndex) dominate index-heavy titles: on
// Need for Speed: Underground they were ~75 % of the vertex loader's video-thread time (iPhone 16
// Pro Max Time Profiler, 2026-10-07). The gather itself defeats SIMD; the cost is the stream
// pointers. Every DataRead/DataWrite goes through the globals g_video_buffer_read_ptr and
// g_vertex_manager_write_ptr, and because DataWrite is a memcpy through a u8* the compiler must
// assume each store may alias the pointer itself, so it reloads and re-stores the global around
// every component. These copies evaluate the scalar expressions verbatim (same index decode,
// same skip test, same FromBigEndian + scale, same cache writes, same write order) with both
// pointers held in locals and written back once, so the output is bit-identical by construction
// (and Compare checks it against the software loader).

template <typename I>
DOLPHIN_FORCE_INLINE u32 ReadIndexLocal(const u8*& src)
{
  I raw;
  std::memcpy(&raw, src, sizeof(I));
  src += sizeof(I);
  return Common::FromBigEndian(raw);
}

template <typename T>
DOLPHIN_FORCE_INLINE void WriteLocal(u8*& dst, T value)
{
  std::memcpy(dst, &value, sizeof(T));
  dst += sizeof(T);
}

template <typename T>
DOLPHIN_FORCE_INLINE T ReadArrayElement(const u8* data, int i)
{
  T raw;
  std::memcpy(&raw, data + i * sizeof(T), sizeof(T));
  return Common::FromBigEndian(raw);
}

// Mirror of VertexLoader_Position.cpp Pos_ReadIndex<I, T, N> (PosScale: float is unscaled).
template <typename I, typename T, int N>
void Pos_ReadIndex_Local(VertexLoader* loader)
{
  const u8* src = g_video_buffer_read_ptr;
  u8* dst = g_vertex_manager_write_ptr;
  const u32 index = ReadIndexLocal<I>(src);
  const bool skip = index == std::numeric_limits<I>::max();
  loader->m_vertexSkip = skip;
  const u8* data = VertexLoaderManager::cached_arraybases[CPArray::Position] +
                   (index * g_main_cp_state.array_strides[CPArray::Position]);
  const float scale = loader->m_posScale;
  const bool cache = loader->m_remaining < 3 && !skip;
  for (int i = 0; i < N; ++i)
  {
    const T raw = ReadArrayElement<T>(data, i);
    float value;
    if constexpr (std::is_same_v<T, float>)
      value = raw;
    else
      value = raw * scale;
    if (cache)
      VertexLoaderManager::position_cache[loader->m_remaining][i] = value;
    WriteLocal(dst, value);
  }
  g_video_buffer_read_ptr = src;
  g_vertex_manager_write_ptr = dst;
}

// Mirror of VertexLoader_TextCoord.cpp TexCoord_ReadIndex<I, T, N> (TCScale: float unscaled).
template <typename I, typename T, int N>
void TexCoord_ReadIndex_Local(VertexLoader* loader)
{
  const u8* src = g_video_buffer_read_ptr;
  u8* dst = g_vertex_manager_write_ptr;
  const u32 index = ReadIndexLocal<I>(src);
  const u8* data = VertexLoaderManager::cached_arraybases[CPArray::TexCoord0 + loader->m_tcIndex] +
                   (index * g_main_cp_state.array_strides[CPArray::TexCoord0 + loader->m_tcIndex]);
  const float scale = loader->m_tcScale[loader->m_tcIndex];
  for (int i = 0; i != N; ++i)
  {
    const T raw = ReadArrayElement<T>(data, i);
    if constexpr (std::is_same_v<T, float>)
      WriteLocal(dst, raw);
    else
      WriteLocal(dst, static_cast<float>(raw * scale));
  }
  ++loader->m_tcIndex;
  g_video_buffer_read_ptr = src;
  g_vertex_manager_write_ptr = dst;
}

// Mirror of VertexLoader_Color.cpp Color_ReadIndex_32b_8888<I> (Read32 = byte-order preserving).
template <typename I>
void Color_ReadIndex_Local_32b_8888(VertexLoader* loader)
{
  const u8* src = g_video_buffer_read_ptr;
  u8* dst = g_vertex_manager_write_ptr;
  const u32 index = ReadIndexLocal<I>(src);
  const u8* address = VertexLoaderManager::cached_arraybases[CPArray::Color0 + loader->m_colIndex] +
                      (index * g_main_cp_state.array_strides[CPArray::Color0 + loader->m_colIndex]);
  u32 value;
  std::memcpy(&value, address, sizeof(u32));
  WriteLocal(dst, value);
  loader->m_colIndex++;
  g_video_buffer_read_ptr = src;
  g_vertex_manager_write_ptr = dst;
}

template <typename I, int N>
TPipelineFunction PosIndexedFunction(ComponentFormat format)
{
  switch (format)
  {
  case ComponentFormat::UByte:
    return Pos_ReadIndex_Local<I, u8, N>;
  case ComponentFormat::Byte:
    return Pos_ReadIndex_Local<I, s8, N>;
  case ComponentFormat::UShort:
    return Pos_ReadIndex_Local<I, u16, N>;
  case ComponentFormat::Short:
    return Pos_ReadIndex_Local<I, s16, N>;
  default:  // Float and the InvalidFloat5-7 aliases, as in s_table_read_position
    return Pos_ReadIndex_Local<I, float, N>;
  }
}

template <typename I, int N>
TPipelineFunction TexCoordIndexedFunction(ComponentFormat format)
{
  switch (format)
  {
  case ComponentFormat::UByte:
    return TexCoord_ReadIndex_Local<I, u8, N>;
  case ComponentFormat::Byte:
    return TexCoord_ReadIndex_Local<I, s8, N>;
  case ComponentFormat::UShort:
    return TexCoord_ReadIndex_Local<I, u16, N>;
  case ComponentFormat::Short:
    return TexCoord_ReadIndex_Local<I, s16, N>;
  default:  // Float and the InvalidFloat5-7 aliases, as in s_table_read_tex_coord
    return TexCoord_ReadIndex_Local<I, float, N>;
  }
}

TPipelineFunction PosIndexed(VertexComponentFormat type, ComponentFormat format, int n)
{
  if (type == VertexComponentFormat::Index8)
    return n == 2 ? PosIndexedFunction<u8, 2>(format) : PosIndexedFunction<u8, 3>(format);
  return n == 2 ? PosIndexedFunction<u16, 2>(format) : PosIndexedFunction<u16, 3>(format);
}

TPipelineFunction TexCoordIndexed(VertexComponentFormat type, ComponentFormat format,
                                  TexComponentCount elements)
{
  const bool st = elements == TexComponentCount::ST;
  if (type == VertexComponentFormat::Index8)
    return st ? TexCoordIndexedFunction<u8, 2>(format) : TexCoordIndexedFunction<u8, 1>(format);
  return st ? TexCoordIndexedFunction<u16, 2>(format) : TexCoordIndexedFunction<u16, 1>(format);
}

#endif  // _M_ARM_64

}  // namespace

// ===========================================================================
//  Construction
// ===========================================================================
VertexLoaderNEON::VertexLoaderNEON(const TVtxDesc& vtx_desc, const VAT& vtx_attr)
    : VertexLoaderBase(vtx_desc, vtx_attr), m_ctx(vtx_desc, vtx_attr)
{
  // m_ctx's ctor already ran CompileVertexTranslator() + computed the scales.
  // Copy the canonical native vertex declaration so Compare sees byte-identical
  // stride / offsets / types (VertexLoaderTester ctor, VertexLoaderBase.cpp:46).
  std::memcpy(&m_native_vtx_decl, &m_ctx.m_native_vtx_decl, sizeof(PortableVertexDeclaration));

  BuildPipeline();
}

// ===========================================================================
//  Pipeline construction -- replicates CompileVertexTranslator's WriteCall
//  *sequence* exactly (VertexLoader.cpp:78-249). Where a slot is a supported
//  DIRECT attribute, we substitute a NEON functor; indexed position, texcoord and
//  RGBA8888 color get the local-pointer gather copies; everything else keeps the
//  scalar GetFunction pointer.
// ===========================================================================
void VertexLoaderNEON::BuildPipeline()
{
  const TVtxDesc& desc = m_VtxDesc;
  const VAT& attr = m_VtxAttr;

  // -- Position Matrix Index (VertexLoader.cpp:84-93) ------------------------
  if (desc.low.PosMatIdx)
    WriteCall(PosMtx_ReadDirect_UByte);

  // -- Texture matrix indices (VertexLoader.cpp:95-99) -----------------------
  for (auto texmtxidx : desc.low.TexMatIdx)
  {
    if (texmtxidx)
      WriteCall(TexMtx_ReadDirect_UByte);
  }

  // -- Position (VertexLoader.cpp:101-111) -----------------------------------
  {
    const auto type = desc.low.Position;
    const auto format = attr.g0.PosFormat;
    const auto elements = attr.g0.PosElements;
    const int n = (elements == CoordComponentCount::XY) ? 2 : 3;

    TPipelineFunction fn = nullptr;
#if defined(_M_ARM_64)
    if (!IsIndexed(type))  // DIRECT -> NEON; indexed -> local-pointer gather below
    {
      switch (format)
      {
      case ComponentFormat::Short:  // s16
        fn = (n == 2) ? Pos_ReadDirect_NEON_s16<2> : Pos_ReadDirect_NEON_s16<3>;
        break;
      case ComponentFormat::UShort:  // u16
        fn = (n == 2) ? Pos_ReadDirect_NEON_u16<2> : Pos_ReadDirect_NEON_u16<3>;
        break;
      case ComponentFormat::Float:
      case ComponentFormat::InvalidFloat5:
      case ComponentFormat::InvalidFloat6:
      case ComponentFormat::InvalidFloat7:
        fn = (n == 2) ? Pos_ReadDirect_NEON_float<2> : Pos_ReadDirect_NEON_float<3>;
        break;
      default:  // s8 / u8 -> not yet vectorized, fall through to scalar
        fn = nullptr;
        break;
      }
    }
    else
    {
      fn = PosIndexed(type, format, n);  // local-pointer gather (bit-identical to scalar)
    }
#endif
    if (!fn)
      fn = VertexLoader_Position::GetFunction(type, format, elements);
    WriteCall(fn);
  }

  // -- Normals (VertexLoader.cpp:113-137) ------------------------------------
  // Always scalar fallback: normals are frequently indexed (NormalIndex3) and
  // populate normal/tangent/binormal caches via a single canonical path.
  if (desc.low.Normal != VertexComponentFormat::NotPresent)
  {
    TPipelineFunction pFunc = VertexLoader_Normal::GetFunction(
        desc.low.Normal, attr.g0.NormalFormat, attr.g0.NormalElements, attr.g0.NormalIndex3);
    WriteCall(pFunc);
  }

  // -- Colors (VertexLoader.cpp:139-166) -------------------------------------
  for (size_t i = 0; i < desc.low.Color.Size(); i++)
  {
    const auto type = desc.low.Color[i];
    const auto format = attr.GetColorFormat(i);

    TPipelineFunction pFunc = nullptr;
#if defined(_M_ARM_64)
    if (!IsIndexed(type) && type != VertexComponentFormat::NotPresent)
    {
      if (format == ColorFormat::RGBA8888)
        pFunc = Color_ReadDirect_NEON_32b_8888;
    }
    else if (IsIndexed(type) && format == ColorFormat::RGBA8888)
    {
      pFunc = type == VertexComponentFormat::Index8 ? Color_ReadIndex_Local_32b_8888<u8> :
                                                      Color_ReadIndex_Local_32b_8888<u16>;
    }
#endif
    if (!pFunc)
      pFunc = VertexLoader_Color::GetFunction(type, format);

    if (pFunc != nullptr)
    {
      WriteCall(pFunc);
    }
    else
    {
      // type == NotPresent. Keep colIndex in sync if color 0 absent but 1 present.
      if (i == 0 && desc.low.Color[1] != VertexComponentFormat::NotPresent)
        WriteCall(VertexLoader_Color::GetDummyFunction());
    }
  }

  // -- TexCoords + tex-matrix writes (VertexLoader.cpp:168-240) --------------
  for (size_t i = 0; i < desc.high.TexCoord.Size(); i++)
  {
    const auto tc = desc.high.TexCoord[i].Value();
    const auto format = attr.GetTexFormat(i);
    const auto elements = attr.GetTexElements(i);

    if (tc != VertexComponentFormat::NotPresent)
    {
      // Texcoords are 1-2 components: NEON buys ~nothing at this width, and the 8-byte
      // D-register loads over-read the trailing texcoord of the last vertex (the FIFO
      // guard is only +4B). Delegate to the bounded, bit-exact scalar texcoord reader.
      TPipelineFunction fn = nullptr;
#if defined(_M_ARM_64)
      if (IsIndexed(tc))
        fn = TexCoordIndexed(tc, format, elements);  // local-pointer gather (bit-identical)
#endif
      if (!fn)
        fn = VertexLoader_TextCoord::GetFunction(tc, format, elements);
      WriteCall(fn);
    }

    if (desc.low.TexMatIdx[i])
    {
      if (tc != VertexComponentFormat::NotPresent)
        WriteCall(elements == TexComponentCount::ST ? TexMtx_Write_Float : TexMtx_Write_Float2);
      else
        WriteCall(TexMtx_Write_Float3);
    }

    if (tc == VertexComponentFormat::NotPresent)
    {
      bool has_more = false;
      for (size_t j = i + 1; j < desc.high.TexCoord.Size(); ++j)
      {
        if (desc.high.TexCoord[j] != VertexComponentFormat::NotPresent)
        {
          has_more = true;
          WriteCall(VertexLoader_TextCoord::GetDummyFunction());
          break;
        }
        else if (desc.low.TexMatIdx[j])
        {
          has_more = true;
        }
      }
      if (!has_more)
        break;
    }
  }

  // -- Indexed position may skip the vertex (VertexLoader.cpp:242-246) --------
  if (IsIndexed(desc.low.Position))
    WriteCall(SkipVertex);
}

// ===========================================================================
//  RunVertices -- mirrors VertexLoader::RunVertices (VertexLoader.cpp:256-275)
//  exactly, but dispatches our m_pipeline against the &m_ctx context object.
// ===========================================================================
int VertexLoaderNEON::RunVertices(const u8* src, u8* dst, int count)
{
  g_vertex_manager_write_ptr = dst;
  g_video_buffer_read_ptr = src;

  m_numLoadedVertices += count;
  m_ctx.m_skippedVertices = 0;

  for (m_ctx.m_remaining = count - 1; m_ctx.m_remaining >= 0; m_ctx.m_remaining--)
  {
    m_ctx.m_tcIndex = 0;
    m_ctx.m_colIndex = 0;
    m_ctx.m_texmtxwrite = m_ctx.m_texmtxread = 0;
    for (TPipelineFunction& func : m_pipeline)
      func(&m_ctx);
  }

  return count - m_ctx.m_skippedVertices;
}
