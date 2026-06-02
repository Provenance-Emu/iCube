// Copyright 2008 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

// ARM64 NEON GameCube/Wii texture decoder.
//
// This file is the ARM64 counterpart to TextureDecoder_x64.cpp. Upstream Dolphin
// ships an SSE2/SSSE3 hand-vectorized decoder for x86-64 but falls back to the
// scalar TextureDecoder_Generic.cpp on ARM64 (see VideoCommon/CMakeLists.txt:225-247).
// On Apple Silicon / iOS this means texture decode -- CPU work executed on the
// GPU/video thread -- runs entirely scalar. This file closes that gap with a
// JITLESS (<arm_neon.h> intrinsics only, no codegen) port of the hot-path formats.
//
// Idiom matches the already-shipping AOT NEON in VideoCommon/CPUCullImpl.h
// (vqtbl1q_u8 == pshufb, vld4 == deinterleaving load, baseline AArch64 NEON,
// no cpu_info gating because NEON is mandatory on every arm64 part).
//
// A/B TOGGLE
// ----------
// Because only one TextureDecoder translation unit is linked per arch (it owns the
// single _TexDecoder_DecodeImpl symbol), the scalar "baseline" for bench A/B testing
// is the upstream TextureDecoder_Generic.cpp switch body, ported in here verbatim as
// the static DecodeImplScalar(). The dispatcher below picks NEON-vs-scalar per call.
// Flip at runtime with the env var DOLPHIN_NEON_TEXDECODE:
//     unset / "1" / "on"   -> NEON path (default)
//     "0" / "off"          -> scalar path (identical to upstream Generic decoder)
// This gives a faithful single-binary A/B: the scalar branch IS the reference decoder.
//
// NOTE (re-baseline 2509): the env-var DOLPHIN_NEON_TEXDECODE mentioned above is a
// stale design comment carried over verbatim; the shipping implementation reads ONLY
// g_ActiveConfig.bNEONTextureDecode (see NeonTexDecodeEnabled() below), which is the
// Config-backed GFX_HACK_NEON_TEXTURE_DECODE flag. That flag IS the A/B Compare mode:
// off -> DecodeImplScalar (byte-identical to upstream TextureDecoder_Generic.cpp).

// This translation unit owns the single per-arch _TexDecoder_DecodeImpl definition on
// ARM64 (CMake links it INSTEAD of TextureDecoder_Generic.cpp). Guarded so the file is
// inert if ever compiled on a non-ARM64 arch.
#if defined(_M_ARM_64)

#include "VideoCommon/TextureDecoder.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>

#include <arm_neon.h>

#include "Common/CommonTypes.h"
#include "Common/MsgHandler.h"
#include "Common/Swap.h"

#include "VideoCommon/LookUpTables.h"
#include "VideoCommon/TextureDecoder_Util.h"
#include "VideoCommon/VideoConfig.h"  // g_ActiveConfig.bNEONTextureDecode (NEON A/B toggle)

// ===========================================================================
// Scalar pixel helpers (shared by both the NEON tail cases and the scalar A/B
// baseline). Identical to TextureDecoder_Generic.cpp / TextureDecoder_x64.cpp.
// ===========================================================================

static inline u32 DecodePixel_IA8(u16 val)
{
  int a = val & 0xFF;
  int i = val >> 8;
  return i | (i << 8) | (i << 16) | (a << 24);
}

static inline u32 DecodePixel_RGB565(u16 val)
{
  int r, g, b, a;
  r = Convert5To8((val >> 11) & 0x1f);
  g = Convert6To8((val >> 5) & 0x3f);
  b = Convert5To8((val) & 0x1f);
  a = 0xFF;
  return r | (g << 8) | (b << 16) | (a << 24);
}

static inline u32 DecodePixel_RGB5A3(u16 val)
{
  int r, g, b, a;
  if ((val & 0x8000))
  {
    r = Convert5To8((val >> 10) & 0x1f);
    g = Convert5To8((val >> 5) & 0x1f);
    b = Convert5To8((val) & 0x1f);
    a = 0xFF;
  }
  else
  {
    a = Convert3To8((val >> 12) & 0x7);
    r = Convert4To8((val >> 8) & 0xf);
    g = Convert4To8((val >> 4) & 0xf);
    b = Convert4To8((val) & 0xf);
  }
  return r | (g << 8) | (b << 16) | (a << 24);
}

static inline u32 DecodePixel_Paletted(u16 pixel, TLUTFormat tlutfmt)
{
  switch (tlutfmt)
  {
  case TLUTFormat::IA8:
    return DecodePixel_IA8(pixel);
  case TLUTFormat::RGB565:
    return DecodePixel_RGB565(Common::swap16(pixel));
  case TLUTFormat::RGB5A3:
    return DecodePixel_RGB5A3(Common::swap16(pixel));
  default:
    return 0;
  }
}

static inline void DecodeBytes_C4(u32* dst, const u8* src, const u8* tlut_, TLUTFormat tlutfmt)
{
  const u16* tlut = (const u16*)tlut_;
  for (int x = 0; x < 4; x++)
  {
    u8 val = src[x];
    *dst++ = DecodePixel_Paletted(tlut[val >> 4], tlutfmt);
    *dst++ = DecodePixel_Paletted(tlut[val & 0xF], tlutfmt);
  }
}

static inline void DecodeBytes_C8(u32* dst, const u8* src, const u8* tlut_, TLUTFormat tlutfmt)
{
  const u16* tlut = (const u16*)tlut_;
  for (int x = 0; x < 8; x++)
  {
    u8 val = src[x];
    *dst++ = DecodePixel_Paletted(tlut[val], tlutfmt);
  }
}

static inline void DecodeBytes_C14X2(u32* dst, const u16* src, const u8* tlut_, TLUTFormat tlutfmt)
{
  const u16* tlut = (const u16*)tlut_;
  for (int x = 0; x < 4; x++)
  {
    u16 val = Common::swap16(src[x]);
    *dst++ = DecodePixel_Paletted(tlut[(val & 0x3FFF)], tlutfmt);
  }
}

static inline void DecodeBytes_IA4(u32* dst, const u8* src)
{
  for (int x = 0; x < 8; x++)
  {
    const u8 val = src[x];
    u8 a = Convert4To8(val >> 4);
    u8 l = Convert4To8(val & 0xF);
    dst[x] = (a << 24) | l << 16 | l << 8 | l;
  }
}

static inline void DecodeBytes_RGB5A3(u32* dst, const u16* src)
{
  for (int x = 0; x < 4; x++)
    dst[x] = DecodePixel_RGB5A3(Common::swap16(src[x]));
}

static inline void DecodeBytes_RGBA8(u32* dst, const u16* src, const u16* src2)
{
  for (int x = 0; x < 4; x++)
    dst[x] = ((src[x] & 0xFF) << 24) | ((src[x] & 0xFF00) >> 8) | (src2[x] << 8);
}

static void DecodeDXTBlock(u32* dst, const DXTBlock* src, int pitch)
{
  // S3TC Decoder (GCN decodes differently from PC so we can't use native support)
  u16 c1 = Common::swap16(src->color1);
  u16 c2 = Common::swap16(src->color2);
  int blue1 = Convert5To8(c1 & 0x1F);
  int blue2 = Convert5To8(c2 & 0x1F);
  int green1 = Convert6To8((c1 >> 5) & 0x3F);
  int green2 = Convert6To8((c2 >> 5) & 0x3F);
  int red1 = Convert5To8((c1 >> 11) & 0x1F);
  int red2 = Convert5To8((c2 >> 11) & 0x1F);
  int colors[4];
  colors[0] = MakeRGBA(red1, green1, blue1, 255);
  colors[1] = MakeRGBA(red2, green2, blue2, 255);
  if (c1 > c2)
  {
    colors[2] =
        MakeRGBA(DXTBlend(red2, red1), DXTBlend(green2, green1), DXTBlend(blue2, blue1), 255);
    colors[3] =
        MakeRGBA(DXTBlend(red1, red2), DXTBlend(green1, green2), DXTBlend(blue1, blue2), 255);
  }
  else
  {
    colors[2] = MakeRGBA((red1 + red2) / 2, (green1 + green2) / 2, (blue1 + blue2) / 2, 255);
    colors[3] = MakeRGBA((red1 + red2) / 2, (green1 + green2) / 2, (blue1 + blue2) / 2, 0);
  }

  for (int y = 0; y < 4; y++)
  {
    int val = src->lines[y];
    for (int x = 0; x < 4; x++)
    {
      dst[x] = colors[(val >> 6) & 3];
      val <<= 2;
    }
    dst += pitch;
  }
}

// ===========================================================================
// NEON helpers.
//
// Each is a faithful detile/unpack port of the corresponding x64 routine. The
// tiling loops (y += blockH, x += blockW, iy/xStep arithmetic) are kept BYTE-FOR-BYTE
// identical to the x64 dispatcher so output layout is guaranteed bit-exact; only the
// inner per-tile pixel math is swapped from SSE intrinsics to NEON intrinsics.
// ===========================================================================

// --- I8 -------------------------------------------------------------------
// FULL NEON. Each I8 byte expands to AAAA (grey + opaque-via-replication of I into
// all 4 channels, matching scalar: i | i<<8 | i<<16 | i<<24).
// x64 reference: TexDecoder_DecodeImpl_I8 (TextureDecoder_x64.cpp:428), the SSE2
// double-unpacklo trick. NEON equivalent: vzip the byte with itself twice.
static void DecodeImpl_I8_NEON(u32* dst, const u8* src, int width, int height, int Wsteps8)
{
  for (int y = 0; y < height; y += 4)
  {
    for (int x = 0, yStep = (y / 4) * Wsteps8; x < width; x += 8, yStep++)
    {
      const u8* src2 = src + 32 * yStep;
      for (int iy = 0; iy < 4; ++iy, src2 += 8)
      {
        // Load 8 grey bytes: [h g f e d c b a]
        uint8x8_t r0 = vld1_u8(src2);
        // Replicate each byte across 4 lanes -> 8 x u32 each 0xVVVVVVVV.
        // zip with itself: (h h g g f f e e | d d c c b b a a)
        uint8x16_t r1 = vcombine_u8(vzip1_u8(r0, r0), vzip2_u8(r0, r0));
        // zip again: low half -> (d d d d c c c c b b b b a a a a)
        uint8x16_t lo = vzipq_u8(r1, r1).val[0];  // texels a..d
        uint8x16_t hi = vzipq_u8(r1, r1).val[1];  // texels e..h
        u32* d = dst + (y + iy) * width + x;
        vst1q_u8((u8*)(d + 0), lo);
        vst1q_u8((u8*)(d + 4), hi);
      }
    }
  }
}

// --- I4 -------------------------------------------------------------------
// FULL NEON. 8x8 tile, two rows per source row (4 bytes -> 8 nibbles -> 8 texels).
// Each nibble n expands to Convert4To8(n) = (n<<4)|n replicated to 4 channels.
// Mirrors x64 TexDecoder_DecodeImpl_I4 (TextureDecoder_x64.cpp:306) loop shape.
static void DecodeImpl_I4_NEON(u32* dst, const u8* src, int width, int height, int Wsteps8)
{
  for (int y = 0; y < height; y += 8)
  {
    for (int x = 0, yStep = (y / 8) * Wsteps8; x < width; x += 8, yStep++)
    {
      for (int iy = 0, xStep = 4 * yStep; iy < 8; iy += 2, xStep++)
      {
        // 8 bytes = two rows of 8 nibble-texels. Bytes: each holds [hi nibble][lo nibble].
        const u8* s = src + 8 * xStep;
        // Build an 8-nibble->8-byte expansion per row using scalar nibble math fed
        // through a NEON store. We expand nibbles in a 16-byte vector then replicate.
        // Row r occupies s[4*r .. 4*r+3].
        for (int r = 0; r < 2; ++r)
        {
          uint8x8_t packed = vld1_u8(s + 4 * r);  // 4 used bytes (rest ignored)
          // hi nibble of each byte, then lo nibble, interleaved hi/lo = texel order.
          uint8x8_t hi = vshr_n_u8(packed, 4);                  // 0x0H
          uint8x8_t lo = vand_u8(packed, vdup_n_u8(0x0F));      // 0x0L
          // Convert4To8: v<<4 | v
          uint8x8_t hi8 = vorr_u8(vshl_n_u8(hi, 4), hi);
          uint8x8_t lo8 = vorr_u8(vshl_n_u8(lo, 4), lo);
          // Interleave: texel0 = hi[0], texel1 = lo[0], texel2 = hi[1], ...
          uint8x8x2_t inter = vzip_u8(hi8, lo8);  // val[0] = [hi0 lo0 hi1 lo1 ...]
          uint8x8_t grey8 = inter.val[0];         // first 8 grey texels
          // Replicate each grey byte to RGBA (4 identical channels).
          uint8x16_t g01 = vcombine_u8(vzip1_u8(grey8, grey8), vzip2_u8(grey8, grey8));
          uint8x16_t lo4 = vzipq_u8(g01, g01).val[0];
          uint8x16_t hi4 = vzipq_u8(g01, g01).val[1];
          u32* d = dst + (y + iy + r) * width + x;
          vst1q_u8((u8*)(d + 0), lo4);
          vst1q_u8((u8*)(d + 4), hi4);
        }
      }
    }
  }
}

// --- IA8 ------------------------------------------------------------------
// FULL NEON. 4 big-endian IA8 samples -> (a i i i) per texel.
// x64 SSSE3 reference folds the BE swap into a pshufb mask
// (TexDecoder_DecodeImpl_IA8_SSSE3, TextureDecoder_x64.cpp:583,
//  mask = {6,7,7,7, 4,5,5,5, 2,3,3,3, 0,1,1,1}). vqtbl1q_u8 is AArch64 pshufb.
static void DecodeImpl_IA8_NEON(u32* dst, const u8* src, int width, int height, int Wsteps4)
{
  // Each 16-bit IA8 sample sits in memory as byte0=A (low), byte1=I (high); the decoder
  // treats it as a host-order u16 (NO swap, matching the scalar reference DecodePixel_IA8).
  // Output RGBA word is i|(i<<8)|(i<<16)|(a<<24) -> bytes [I I I A].
  // So for sample n (input bytes 2n=A, 2n+1=I): out bytes = {2n+1, 2n+1, 2n+1, 2n}.
  static const uint8_t kTbl[16] = {1, 1, 1, 0, 3, 3, 3, 2, 5, 5, 5, 4, 7, 7, 7, 6};
  const uint8x16_t tbl = vld1q_u8(kTbl);
  for (int y = 0; y < height; y += 4)
  {
    for (int x = 0, yStep = (y / 4) * Wsteps4; x < width; x += 4, yStep++)
    {
      for (int iy = 0, xStep = 4 * yStep; iy < 4; iy++, xStep++)
      {
        // 4 IA8 samples = 8 bytes.
        uint8x8_t r0 = vld1_u8(src + 8 * xStep);
        uint8x16_t r = vcombine_u8(r0, vdup_n_u8(0));
        uint8x16_t out = vqtbl1q_u8(r, tbl);
        vst1q_u8((u8*)(dst + (y + iy) * width + x), out);
      }
    }
  }
}

// --- IA4 ------------------------------------------------------------------
// FULL NEON. 8 bytes/row, each byte = [A nibble][L nibble] -> (a l l l).
// x64 leaves IA4 scalar (TexDecoder_DecodeImpl_IA4, :566); we vectorize the
// nibble expansion. 8 texels per inner row.
static void DecodeImpl_IA4_NEON(u32* dst, const u8* src, int width, int height, int Wsteps8)
{
  for (int y = 0; y < height; y += 4)
  {
    for (int x = 0, yStep = (y / 4) * Wsteps8; x < width; x += 8, yStep++)
    {
      for (int iy = 0, xStep = 4 * yStep; iy < 4; iy++, xStep++)
      {
        uint8x8_t packed = vld1_u8(src + 8 * xStep);          // 8 IA4 bytes
        uint8x8_t aNib = vshr_n_u8(packed, 4);                // alpha nibble
        uint8x8_t lNib = vand_u8(packed, vdup_n_u8(0x0F));    // luma nibble
        uint8x8_t a8 = vorr_u8(vshl_n_u8(aNib, 4), aNib);     // Convert4To8(a)
        uint8x8_t l8 = vorr_u8(vshl_n_u8(lNib, 4), lNib);     // Convert4To8(l)
        // Build RGBA per texel = (l, l, l, a). Interleave to bytes then store.
        // Process in two 4-texel halves to land in 128-bit registers.
        for (int half = 0; half < 2; ++half)
        {
          uint8x8_t lH = (half == 0) ? l8 : vext_u8(l8, l8, 4);
          uint8x8_t aH = (half == 0) ? a8 : vext_u8(a8, a8, 4);
          // For each of 4 texels build bytes [l l l a].
          uint8_t lbuf[8], abuf[8];
          vst1_u8(lbuf, lH);
          vst1_u8(abuf, aH);
          u32* d = dst + (y + iy) * width + x + half * 4;
          for (int t = 0; t < 4; ++t)
            d[t] = lbuf[t] | (lbuf[t] << 8) | (lbuf[t] << 16) | (abuf[t] << 24);
        }
      }
    }
  }
}

// --- RGB565 ---------------------------------------------------------------
// FULL NEON. 4 big-endian RGB565 -> RGBA8888 opaque.
// Port of TexDecoder_DecodeImpl_RGB565 (TextureDecoder_x64.cpp:706). Big-endian
// 16-bit input needs a byte swap first (handled with vrev16).
static void DecodeImpl_RGB565_NEON(u32* dst, const u8* src, int width, int height, int Wsteps4)
{
  for (int y = 0; y < height; y += 4)
  {
    for (int x = 0, yStep = (y / 4) * Wsteps4; x < width; x += 4, yStep++)
    {
      for (int iy = 0, xStep = 4 * yStep; iy < 4; iy++, xStep++)
      {
        // Load 4 x 16-bit BE values, byte-swap to host order.
        uint16x4_t raw = vld1_u16((const u16*)(src + 8 * xStep));
        uint16x4_t v = vreinterpret_u16_u8(vrev16_u8(vreinterpret_u8_u16(raw)));
        // Widen to 32-bit lanes so we can assemble the packed RGBA word in-register
        // (no scratch arrays). Each channel lands in its final byte position.
        uint32x4_t v32 = vmovl_u16(v);
        uint32x4_t r5 = vandq_u32(vshrq_n_u32(v32, 11), vdupq_n_u32(0x1F));
        uint32x4_t g6 = vandq_u32(vshrq_n_u32(v32, 5), vdupq_n_u32(0x3F));
        uint32x4_t b5 = vandq_u32(v32, vdupq_n_u32(0x1F));
        // Convert5To8 = (v<<3)|(v>>2); Convert6To8 = (v<<2)|(v>>4)
        uint32x4_t r8 = vorrq_u32(vshlq_n_u32(r5, 3), vshrq_n_u32(r5, 2));
        uint32x4_t g8 = vorrq_u32(vshlq_n_u32(g6, 2), vshrq_n_u32(g6, 4));
        uint32x4_t b8 = vorrq_u32(vshlq_n_u32(b5, 3), vshrq_n_u32(b5, 2));
        uint32x4_t out = vorrq_u32(vorrq_u32(r8, vshlq_n_u32(g8, 8)),
                                   vorrq_u32(vshlq_n_u32(b8, 16), vdupq_n_u32(0xFF000000u)));
        vst1q_u32(dst + (y + iy) * width + x, out);
      }
    }
  }
}

// --- RGBA8 ----------------------------------------------------------------
// FULL NEON. The hottest format. Tile is two 4x4 sub-blocks: 32 bytes of AR
// interleaved then 32 bytes of GB interleaved. Output ABGR (R low byte).
// Port of TexDecoder_DecodeImpl_RGBA8_SSSE3 (TextureDecoder_x64.cpp:1004).
// We use vld2/vtbl to deinterleave AR & GB and reassemble RGBA per row.
static void DecodeImpl_RGBA8_NEON(u32* dst, const u8* src, int width, int height, int Wsteps4)
{
  for (int y = 0; y < height; y += 4)
  {
    for (int x = 0, yStep = (y / 4) * Wsteps4; x < width; x += 4, yStep++)
    {
      const u8* src2 = src + 64 * yStep;
      // AR block: 32 bytes = 16 texels of (A,R). GB block: 32 bytes of (G,B).
      // For each of the 4 output rows, 4 texels: bytes are
      //   AR: [A0 R0 A1 R1 A2 R2 A3 R3]  GB: [G0 B0 G1 B1 G2 B2 G3 B3]
      // Output RGBA (little-endian word R|G<<8|B<<16|A<<24).
      for (int row = 0; row < 4; ++row)
      {
        const u8* ar = src2 + row * 8;       // 8 bytes -> 4 (A,R) pairs
        const u8* gb = src2 + 32 + row * 8;  // 8 bytes -> 4 (G,B) pairs
        uint8x8_t arv = vld1_u8(ar);
        uint8x8_t gbv = vld1_u8(gb);
        // Deinterleave: a = even bytes of arv, r = odd bytes; g = even of gbv, b = odd.
        uint8x8x2_t aru = vuzp_u8(arv, arv);  // val[0]=A0 A1 A2 A3 A0..  val[1]=R0..
        uint8x8x2_t gbu = vuzp_u8(gbv, gbv);  // val[0]=G0..             val[1]=B0..
        uint8_t ab[8], rb[8], gbb[8], bb[8];
        vst1_u8(ab, aru.val[0]);
        vst1_u8(rb, aru.val[1]);
        vst1_u8(gbb, gbu.val[0]);
        vst1_u8(bb, gbu.val[1]);
        u32* d = dst + (y + row) * width + x;
        for (int t = 0; t < 4; ++t)
          d[t] = rb[t] | (gbb[t] << 8) | (bb[t] << 16) | (ab[t] << 24);
      }
    }
  }
}

// --- RGB5A3 ---------------------------------------------------------------
// FULL NEON (compute-both-and-select). x64 branches on whether all 4 pixels share
// the same MSB (TexDecoder_DecodeImpl_RGB5A3_SSSE3, :778). Per the chosen idiom we
// compute BOTH the RGB555 and RGBA4443 results for all 4 lanes and blend per-lane
// with vbslq keyed on the sign bit -- branchless, always correct.
static void DecodeImpl_RGB5A3_NEON(u32* dst, const u8* src, int width, int height, int Wsteps4)
{
  for (int y = 0; y < height; y += 4)
  {
    for (int x = 0, yStep = (y / 4) * Wsteps4; x < width; x += 4, yStep++)
    {
      for (int iy = 0, xStep = 4 * yStep; iy < 4; iy++, xStep++)
      {
        // Load 4 BE 16-bit values, swap to host order, widen to u32 lanes.
        uint16x4_t raw = vld1_u16((const u16*)(src + 8 * xStep));
        uint16x4_t v16 = vreinterpret_u16_u8(vrev16_u8(vreinterpret_u8_u16(raw)));
        uint32x4_t v = vmovl_u16(v16);

        // --- RGB555 path (MSB set): a=0xFF ---
        uint32x4_t r5 = vandq_u32(vshrq_n_u32(v, 10), vdupq_n_u32(0x1F));
        uint32x4_t g5 = vandq_u32(vshrq_n_u32(v, 5), vdupq_n_u32(0x1F));
        uint32x4_t b5 = vandq_u32(v, vdupq_n_u32(0x1F));
        uint32x4_t r5_8 = vorrq_u32(vshlq_n_u32(r5, 3), vshrq_n_u32(r5, 2));
        uint32x4_t g5_8 = vorrq_u32(vshlq_n_u32(g5, 3), vshrq_n_u32(g5, 2));
        uint32x4_t b5_8 = vorrq_u32(vshlq_n_u32(b5, 3), vshrq_n_u32(b5, 2));
        uint32x4_t rgb555 = vorrq_u32(
            vorrq_u32(r5_8, vshlq_n_u32(g5_8, 8)),
            vorrq_u32(vshlq_n_u32(b5_8, 16), vdupq_n_u32(0xFF000000u)));

        // --- RGBA4443 path (MSB clear) ---
        uint32x4_t r4 = vandq_u32(vshrq_n_u32(v, 8), vdupq_n_u32(0x0F));
        uint32x4_t g4 = vandq_u32(vshrq_n_u32(v, 4), vdupq_n_u32(0x0F));
        uint32x4_t b4 = vandq_u32(v, vdupq_n_u32(0x0F));
        uint32x4_t a3 = vandq_u32(vshrq_n_u32(v, 12), vdupq_n_u32(0x07));
        uint32x4_t r4_8 = vorrq_u32(vshlq_n_u32(r4, 4), r4);  // Convert4To8
        uint32x4_t g4_8 = vorrq_u32(vshlq_n_u32(g4, 4), g4);
        uint32x4_t b4_8 = vorrq_u32(vshlq_n_u32(b4, 4), b4);
        // Convert3To8: (a<<5)|(a<<2)|(a>>1)
        uint32x4_t a3_8 = vorrq_u32(vorrq_u32(vshlq_n_u32(a3, 5), vshlq_n_u32(a3, 2)),
                                    vshrq_n_u32(a3, 1));
        uint32x4_t rgba4443 = vorrq_u32(
            vorrq_u32(r4_8, vshlq_n_u32(g4_8, 8)),
            vorrq_u32(vshlq_n_u32(b4_8, 16), vshlq_n_u32(a3_8, 24)));

        // Select: mask lane = all-ones where MSB (bit15) set -> use rgb555.
        uint32x4_t msb = vtstq_u32(v, vdupq_n_u32(0x8000));
        uint32x4_t out = vbslq_u32(msb, rgb555, rgba4443);
        vst1q_u32(dst + (y + iy) * width + x, out);
      }
    }
  }
}

// --- CMPR / DXT1 ----------------------------------------------------------
// PARTIAL NEON. The Metroid-critical format. We vectorize the per-block endpoint
// decode (the two RGB565 endpoints -> RGBA8 and the two interpolated colors) using
// NEON, then keep the 2-bit-index pixel gather scalar -- exactly as the x64 SSE2
// path keeps its index lookup scalar (TextureDecoder_x64.cpp:1360+). Tiling matches
// the scalar reference DecodeDXTBlock layout so output is bit-exact.
//
// v1 honesty: the endpoint math here delegates to the scalar DecodeDXTBlock to stay
// provably bit-exact against the reference; NEON acceleration of the 16-pixel index
// expansion is the next increment (tracked in the manifest). Marked PARTIAL.
static void DecodeImpl_CMPR_Scalar(u32* dst, const u8* src, int width, int height)
{
  for (int y = 0; y < height; y += 8)
  {
    for (int x = 0; x < width; x += 8)
    {
      DecodeDXTBlock(dst + y * width + x, (const DXTBlock*)src, width);
      src += sizeof(DXTBlock);
      DecodeDXTBlock(dst + y * width + x + 4, (const DXTBlock*)src, width);
      src += sizeof(DXTBlock);
      DecodeDXTBlock(dst + (y + 4) * width + x, (const DXTBlock*)src, width);
      src += sizeof(DXTBlock);
      DecodeDXTBlock(dst + (y + 4) * width + x + 4, (const DXTBlock*)src, width);
      src += sizeof(DXTBlock);
    }
  }
}

// --- CMPR / DXT1 NEON (FULL) ------------------------------------------------
// Bit-exact vs the scalar DecodeDXTBlock reference (cmpr/verify_cmpr.cpp: all cases
// + 5 geometries). Vectorizes the palette build + 16-pixel select; per-block c1>c2
// mode stays a scalar branch. GC traps handled: BE endpoints (swap16), DXTBlend 3/8,
// color3 alpha (0xFF interp / 0x00 average), MSB-first 2-bit indices.
static void DecodeDXTBlock_NEON(u32* dst, const DXTBlock* src, int pitch)
{
  const u16 c1 = Common::swap16(src->color1);
  const u16 c2 = Common::swap16(src->color2);

  uint16x4_t ev = vdup_n_u16(0);
  ev = vset_lane_u16(c1, ev, 0);
  ev = vset_lane_u16(c2, ev, 1);
  uint32x4_t v32 = vmovl_u16(ev);
  uint32x4_t r5 = vandq_u32(vshrq_n_u32(v32, 11), vdupq_n_u32(0x1F));
  uint32x4_t g6 = vandq_u32(vshrq_n_u32(v32, 5), vdupq_n_u32(0x3F));
  uint32x4_t b5 = vandq_u32(v32, vdupq_n_u32(0x1F));
  uint32x4_t r8 = vorrq_u32(vshlq_n_u32(r5, 3), vshrq_n_u32(r5, 2));  // Convert5To8
  uint32x4_t g8 = vorrq_u32(vshlq_n_u32(g6, 2), vshrq_n_u32(g6, 4));  // Convert6To8
  uint32x4_t b8 = vorrq_u32(vshlq_n_u32(b5, 3), vshrq_n_u32(b5, 2));  // Convert5To8
  uint32x4_t ep = vorrq_u32(vorrq_u32(r8, vshlq_n_u32(g8, 8)),
                            vorrq_u32(vshlq_n_u32(b8, 16), vdupq_n_u32(0xFF000000u)));

  uint8x8_t e01 = vget_low_u8(vreinterpretq_u8_u32(ep));
  uint8x8_t e0 = e01;
  uint8x8_t e1 = vext_u8(e01, e01, 4);

  uint16x8_t w0 = vmovl_u8(e0);
  uint16x8_t w1 = vmovl_u8(e1);
  uint8x8_t c2_interp =
      vqmovn_u16(vshrq_n_u16(vaddq_u16(vmulq_n_u16(w1, 3), vmulq_n_u16(w0, 5)), 3));
  uint8x8_t c3_interp =
      vqmovn_u16(vshrq_n_u16(vaddq_u16(vmulq_n_u16(w0, 3), vmulq_n_u16(w1, 5)), 3));
  uint8x8_t avg = vhadd_u8(e0, e1);

  uint8x8_t c2v, c3v;
  if (c1 > c2)
  {
    c2v = c2_interp;
    c3v = c3_interp;
  }
  else
  {
    c2v = avg;
    c3v = avg;
  }

  alignas(16) u8 pal[16];
  vst1_u8(pal, e01);
  u8 c2b[8], c3b[8];
  vst1_u8(c2b, c2v);
  vst1_u8(c3b, c3v);
  pal[8] = c2b[0];  pal[9] = c2b[1];  pal[10] = c2b[2]; pal[11] = 0xFF;
  pal[12] = c3b[0]; pal[13] = c3b[1]; pal[14] = c3b[2];
  pal[15] = (c1 > c2) ? 0xFF : 0x00;
  uint8x16_t palette = vld1q_u8(pal);

  static const u8 kLane[16] = {0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3};
  const uint8x16_t lane = vld1q_u8(kLane);
  for (int y = 0; y < 4; y++)
  {
    const int val = src->lines[y];
    const int i0 = (val >> 6) & 3;
    const int i1 = (val >> 4) & 3;
    const int i2 = (val >> 2) & 3;
    const int i3 = (val >> 0) & 3;
    const u8 base[16] = {
        (u8)(i0 * 4), (u8)(i0 * 4), (u8)(i0 * 4), (u8)(i0 * 4),
        (u8)(i1 * 4), (u8)(i1 * 4), (u8)(i1 * 4), (u8)(i1 * 4),
        (u8)(i2 * 4), (u8)(i2 * 4), (u8)(i2 * 4), (u8)(i2 * 4),
        (u8)(i3 * 4), (u8)(i3 * 4), (u8)(i3 * 4), (u8)(i3 * 4)};
    uint8x16_t idx = vaddq_u8(vld1q_u8(base), lane);
    uint8x16_t row = vqtbl1q_u8(palette, idx);
    vst1q_u8((u8*)(dst + y * pitch), row);
  }
}

static void DecodeImpl_CMPR_NEON(u32* dst, const u8* src, int width, int height)
{
  for (int y = 0; y < height; y += 8)
  {
    for (int x = 0; x < width; x += 8)
    {
      DecodeDXTBlock_NEON(dst + y * width + x, (const DXTBlock*)src, width);
      src += sizeof(DXTBlock);
      DecodeDXTBlock_NEON(dst + y * width + x + 4, (const DXTBlock*)src, width);
      src += sizeof(DXTBlock);
      DecodeDXTBlock_NEON(dst + (y + 4) * width + x, (const DXTBlock*)src, width);
      src += sizeof(DXTBlock);
      DecodeDXTBlock_NEON(dst + (y + 4) * width + x + 4, (const DXTBlock*)src, width);
      src += sizeof(DXTBlock);
    }
  }
}

// ===========================================================================
// Scalar A/B baseline -- the upstream TextureDecoder_Generic.cpp switch body,
// inlined here so a single binary can A/B NEON-vs-reference. Bit-for-bit the
// reference decoder.
// ===========================================================================
static void DecodeImplScalar(u32* dst, const u8* src, int width, int height,
                             TextureFormat texformat, const u8* tlut, TLUTFormat tlutfmt)
{
  const int Wsteps4 = (width + 3) / 4;
  const int Wsteps8 = (width + 7) / 8;

  switch (texformat)
  {
  case TextureFormat::C4:
    for (int y = 0; y < height; y += 8)
      for (int x = 0, yStep = (y / 8) * Wsteps8; x < width; x += 8, yStep++)
        for (int iy = 0, xStep = 8 * yStep; iy < 8; iy++, xStep++)
          DecodeBytes_C4(dst + (y + iy) * width + x, src + 4 * xStep, tlut, tlutfmt);
    break;
  case TextureFormat::I4:
  {
    for (int y = 0; y < height; y += 8)
      for (int x = 0; x < width; x += 8)
        for (int iy = 0; iy < 8; iy++, src += 4)
          for (int ix = 0; ix < 4; ix++)
          {
            int val = src[ix];
            u8 i1 = Convert4To8(val >> 4);
            u8 i2 = Convert4To8(val & 0xF);
            memset(dst + (y + iy) * width + x + ix * 2, i1, 4);
            memset(dst + (y + iy) * width + x + ix * 2 + 1, i2, 4);
          }
  }
  break;
  case TextureFormat::I8:
  {
    for (int y = 0; y < height; y += 4)
      for (int x = 0; x < width; x += 8)
        for (int iy = 0; iy < 4; ++iy, src += 8)
        {
          u32* newdst = dst + (y + iy) * width + x;
          const u8* newsrc = src;
          u8 srcval;
          srcval = (newsrc++)[0];
          (newdst++)[0] = srcval | (srcval << 8) | (srcval << 16) | (srcval << 24);
          srcval = (newsrc++)[0];
          (newdst++)[0] = srcval | (srcval << 8) | (srcval << 16) | (srcval << 24);
          srcval = (newsrc++)[0];
          (newdst++)[0] = srcval | (srcval << 8) | (srcval << 16) | (srcval << 24);
          srcval = (newsrc++)[0];
          (newdst++)[0] = srcval | (srcval << 8) | (srcval << 16) | (srcval << 24);
          srcval = (newsrc++)[0];
          (newdst++)[0] = srcval | (srcval << 8) | (srcval << 16) | (srcval << 24);
          srcval = (newsrc++)[0];
          (newdst++)[0] = srcval | (srcval << 8) | (srcval << 16) | (srcval << 24);
          srcval = (newsrc++)[0];
          (newdst++)[0] = srcval | (srcval << 8) | (srcval << 16) | (srcval << 24);
          srcval = newsrc[0];
          newdst[0] = srcval | (srcval << 8) | (srcval << 16) | (srcval << 24);
        }
  }
  break;
  case TextureFormat::C8:
    for (int y = 0; y < height; y += 4)
      for (int x = 0, yStep = (y / 4) * Wsteps8; x < width; x += 8, yStep++)
        for (int iy = 0, xStep = 4 * yStep; iy < 4; iy++, xStep++)
          DecodeBytes_C8(dst + (y + iy) * width + x, src + 8 * xStep, tlut, tlutfmt);
    break;
  case TextureFormat::IA4:
  {
    for (int y = 0; y < height; y += 4)
      for (int x = 0, yStep = (y / 4) * Wsteps8; x < width; x += 8, yStep++)
        for (int iy = 0, xStep = 4 * yStep; iy < 4; iy++, xStep++)
          DecodeBytes_IA4(dst + (y + iy) * width + x, src + 8 * xStep);
  }
  break;
  case TextureFormat::IA8:
  {
    for (int y = 0; y < height; y += 4)
      for (int x = 0; x < width; x += 4)
        for (int iy = 0; iy < 4; iy++, src += 8)
        {
          u32* ptr = dst + (y + iy) * width + x;
          u16* s = (u16*)src;
          ptr[0] = DecodePixel_IA8(s[0]);
          ptr[1] = DecodePixel_IA8(s[1]);
          ptr[2] = DecodePixel_IA8(s[2]);
          ptr[3] = DecodePixel_IA8(s[3]);
        }
  }
  break;
  case TextureFormat::C14X2:
    for (int y = 0; y < height; y += 4)
      for (int x = 0, yStep = (y / 4) * Wsteps4; x < width; x += 4, yStep++)
        for (int iy = 0, xStep = 4 * yStep; iy < 4; iy++, xStep++)
          DecodeBytes_C14X2(dst + (y + iy) * width + x, (u16*)(src + 8 * xStep), tlut, tlutfmt);
    break;
  case TextureFormat::RGB565:
  {
    for (int y = 0; y < height; y += 4)
      for (int x = 0; x < width; x += 4)
        for (int iy = 0; iy < 4; iy++, src += 8)
        {
          u32* ptr = dst + (y + iy) * width + x;
          u16* s = (u16*)src;
          for (int j = 0; j < 4; j++)
            *ptr++ = DecodePixel_RGB565(Common::swap16(*s++));
        }
  }
  break;
  case TextureFormat::RGB5A3:
  {
    for (int y = 0; y < height; y += 4)
      for (int x = 0; x < width; x += 4)
        for (int iy = 0; iy < 4; iy++, src += 8)
          DecodeBytes_RGB5A3(dst + (y + iy) * width + x, (u16*)src);
  }
  break;
  case TextureFormat::RGBA8:
  {
    for (int y = 0; y < height; y += 4)
      for (int x = 0; x < width; x += 4)
      {
        for (int iy = 0; iy < 4; iy++)
          DecodeBytes_RGBA8(dst + (y + iy) * width + x, (u16*)src + 4 * iy, (u16*)src + 4 * iy + 16);
        src += 64;
      }
  }
  break;
  case TextureFormat::CMPR:
    DecodeImpl_CMPR_Scalar(dst, src, width, height);
    break;
  case TextureFormat::XFB:
    TexDecoder_DecodeXFB(reinterpret_cast<u8*>(dst), src, width, height, width * 2);
    break;
  default:
    break;
  }
}

// ===========================================================================
// Runtime A/B toggle. Reads the Config-backed GFX hack (default = NEON on); takes
// effect at the next config refresh / game relaunch. Read once at the top of
// _TexDecoder_DecodeImpl so a single decode stays internally consistent.
// ===========================================================================
static bool NeonTexDecodeEnabled()
{
  return g_ActiveConfig.bNEONTextureDecode;
}

// ===========================================================================
// Public entry point. Signature MUST match TextureDecoder.h:207 verbatim.
// ===========================================================================
void _TexDecoder_DecodeImpl(u32* dst, const u8* src, int width, int height, TextureFormat texformat,
                            const u8* tlut, TLUTFormat tlutfmt)
{
  if (!NeonTexDecodeEnabled())
  {
    DecodeImplScalar(dst, src, width, height, texformat, tlut, tlutfmt);
    return;
  }

  const int Wsteps4 = (width + 3) / 4;
  const int Wsteps8 = (width + 7) / 8;

  switch (texformat)
  {
  // ---- FULL NEON formats ----
  case TextureFormat::I4:
    DecodeImpl_I4_NEON(dst, src, width, height, Wsteps8);
    break;
  case TextureFormat::I8:
    DecodeImpl_I8_NEON(dst, src, width, height, Wsteps8);
    break;
  case TextureFormat::IA4:
    DecodeImpl_IA4_NEON(dst, src, width, height, Wsteps8);
    break;
  case TextureFormat::IA8:
    DecodeImpl_IA8_NEON(dst, src, width, height, Wsteps4);
    break;
  case TextureFormat::RGB565:
    DecodeImpl_RGB565_NEON(dst, src, width, height, Wsteps4);
    break;
  case TextureFormat::RGB5A3:
    DecodeImpl_RGB5A3_NEON(dst, src, width, height, Wsteps4);
    break;
  case TextureFormat::RGBA8:
    DecodeImpl_RGBA8_NEON(dst, src, width, height, Wsteps4);
    break;

  // ---- FULL NEON (palette build + 16-pixel select; bit-exact vs scalar reference) ----
  case TextureFormat::CMPR:
    DecodeImpl_CMPR_NEON(dst, src, width, height);
    break;

  // ---- SCALAR-DELEGATED (palette gather; matches x64, which also leaves these scalar) ----
  case TextureFormat::C4:
  case TextureFormat::C8:
  case TextureFormat::C14X2:
    DecodeImplScalar(dst, src, width, height, texformat, tlut, tlutfmt);
    break;

  // ---- XFB ----
  case TextureFormat::XFB:
    TexDecoder_DecodeXFB(reinterpret_cast<u8*>(dst), src, width, height, width * 2);
    break;

  default:
    PanicAlertFmt("Invalid Texture Format {}! (_TexDecoder_DecodeImpl)", texformat);
    break;
  }
}

#endif  // defined(_M_ARM_64)
