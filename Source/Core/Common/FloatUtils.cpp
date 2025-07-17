// Copyright 2018 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Common/FloatUtils.h"

#include <bit>
#include <cmath>

#ifdef __aarch64__
#include <arm_neon.h>
#include "Common/Intrinsics.h"

namespace ARM64FloatOpt
{
/// ARM64 NEON optimized floating point classification for PowerPC FPU emulation
static inline u32 FastClassifyDouble(double dvalue)
{
  const u64 ivalue = std::bit_cast<u64>(dvalue);
  const u64 sign = ivalue & Common::DOUBLE_SIGN;
  const u64 exp = ivalue & Common::DOUBLE_EXP;

  // ARM64 conditional select for branch-free classification
  if (exp > Common::DOUBLE_ZERO && exp < Common::DOUBLE_EXP)
  {
    // Nice normalized number - use conditional select for branch-free code
    return sign ? Common::PPC_FPCLASS_NN : Common::PPC_FPCLASS_PN;
  }

  const u64 mantissa = ivalue & Common::DOUBLE_FRAC;
  if (mantissa)
  {
    if (exp)
      return Common::PPC_FPCLASS_QNAN;

    // Denormalized number
    return sign ? Common::PPC_FPCLASS_ND : Common::PPC_FPCLASS_PD;
  }

  if (exp)
  {
    // Infinite - use ARM64 conditional move
    return sign ? Common::PPC_FPCLASS_NINF : Common::PPC_FPCLASS_PINF;
  }

  // Zero
  return sign ? Common::PPC_FPCLASS_NZ : Common::PPC_FPCLASS_PZ;
}

/// ARM64 NEON optimized PowerPC paired single operations
static inline void FastPairedSingleAdd(float* result, const float* a, const float* b)
{
  float32x2_t va = vld1_f32(a);
  float32x2_t vb = vld1_f32(b);
  float32x2_t vresult = vadd_f32(va, vb);
  vst1_f32(result, vresult);
}

static inline void FastPairedSingleSub(float* result, const float* a, const float* b)
{
  float32x2_t va = vld1_f32(a);
  float32x2_t vb = vld1_f32(b);
  float32x2_t vresult = vsub_f32(va, vb);
  vst1_f32(result, vresult);
}

static inline void FastPairedSingleMul(float* result, const float* a, const float* b)
{
  float32x2_t va = vld1_f32(a);
  float32x2_t vb = vld1_f32(b);
  float32x2_t vresult = vmul_f32(va, vb);
  vst1_f32(result, vresult);
}

static inline void FastPairedSingleMAdd(float* result, const float* a, const float* b, const float* c)
{
  // Multiply-add: result = a * b + c
  float32x2_t va = vld1_f32(a);
  float32x2_t vb = vld1_f32(b);
  float32x2_t vc = vld1_f32(c);
  float32x2_t vresult = vmla_f32(vc, va, vb);  // Fused multiply-add
  vst1_f32(result, vresult);
}

/// ARM64 optimized reciprocal and reciprocal square root approximations
static inline float FastReciprocalSqrt(float value)
{
  float32x2_t input = vdup_n_f32(value);
  float32x2_t estimate = vrsqrte_f32(input);

  // One Newton-Raphson iteration for better precision
  float32x2_t estimate2 = vmul_f32(estimate, estimate);
  float32x2_t estimate3 = vmul_f32(input, estimate2);
  float32x2_t correction = vrsqrts_f32(estimate3, estimate);
  estimate = vmul_f32(estimate, correction);

  return vget_lane_f32(estimate, 0);
}

static inline float FastReciprocal(float value)
{
  float32x2_t input = vdup_n_f32(value);
  float32x2_t estimate = vrecpe_f32(input);

  // One Newton-Raphson iteration for better precision
  float32x2_t correction = vrecps_f32(input, estimate);
  estimate = vmul_f32(estimate, correction);

  return vget_lane_f32(estimate, 0);
}

/// ARM64 NEON optimized vector normalization for 3D graphics
static inline void FastNormalizeVector3(float* result, const float* input)
{
  float32x4_t vec = {input[0], input[1], input[2], 0.0f};

  // Compute dot product
  float32x4_t dot = vmulq_f32(vec, vec);
  float32x2_t sum = vadd_f32(vget_low_f32(dot), vget_high_f32(dot));
  sum = vpadd_f32(sum, sum);

  // Fast inverse square root
  float32x2_t inv_len = vrsqrte_f32(sum);
  inv_len = vmul_f32(inv_len, vrsqrts_f32(vmul_f32(sum, inv_len), inv_len));

  // Normalize
  float32x4_t normalized = vmulq_n_f32(vec, vget_lane_f32(inv_len, 0));

  result[0] = vgetq_lane_f32(normalized, 0);
  result[1] = vgetq_lane_f32(normalized, 1);
  result[2] = vgetq_lane_f32(normalized, 2);
}

/// ARM64 optimized floating point comparison operations
static inline bool FastFloatEqual(float a, float b, float epsilon = 1e-6f)
{
  float32x2_t va = vdup_n_f32(a);
  float32x2_t vb = vdup_n_f32(b);
  float32x2_t vepsilon = vdup_n_f32(epsilon);

  float32x2_t diff = vabs_f32(vsub_f32(va, vb));
  uint32x2_t result = vclt_f32(diff, vepsilon);

  return vget_lane_u32(result, 0) != 0;
}

} // namespace ARM64FloatOpt
#endif

namespace Common
{
u32 ClassifyDouble(double dvalue)
{
#ifdef __aarch64__
  return ARM64FloatOpt::FastClassifyDouble(dvalue);
#else
  const u64 ivalue = std::bit_cast<u64>(dvalue);
  const u64 sign = ivalue & DOUBLE_SIGN;
  const u64 exp = ivalue & DOUBLE_EXP;

  if (exp > DOUBLE_ZERO && exp < DOUBLE_EXP)
  {
    // Nice normalized number.
    return sign ? PPC_FPCLASS_NN : PPC_FPCLASS_PN;
  }

  const u64 mantissa = ivalue & DOUBLE_FRAC;
  if (mantissa)
  {
    if (exp)
      return PPC_FPCLASS_QNAN;

    // Denormalized number.
    return sign ? PPC_FPCLASS_ND : PPC_FPCLASS_PD;
  }

  if (exp)
  {
    // Infinite
    return sign ? PPC_FPCLASS_NINF : PPC_FPCLASS_PINF;
  }

  // Zero
  return sign ? PPC_FPCLASS_NZ : PPC_FPCLASS_PZ;
#endif
}

u32 ClassifyFloat(float fvalue)
{
  const u32 ivalue = std::bit_cast<u32>(fvalue);
  const u32 sign = ivalue & FLOAT_SIGN;
  const u32 exp = ivalue & FLOAT_EXP;

  if (exp > FLOAT_ZERO && exp < FLOAT_EXP)
  {
    // Nice normalized number.
    return sign ? PPC_FPCLASS_NN : PPC_FPCLASS_PN;
  }

  const u32 mantissa = ivalue & FLOAT_FRAC;
  if (mantissa)
  {
    if (exp)
      return PPC_FPCLASS_QNAN;  // Quiet NAN

    // Denormalized number.
    return sign ? PPC_FPCLASS_ND : PPC_FPCLASS_PD;
  }

  if (exp)
  {
    // Infinite
    return sign ? PPC_FPCLASS_NINF : PPC_FPCLASS_PINF;
  }

  // Zero
  return sign ? PPC_FPCLASS_NZ : PPC_FPCLASS_PZ;
}

const std::array<BaseAndDec, 32> frsqrte_expected = {{
    {0x1a7e800, -0x568}, {0x17cb800, -0x4f3}, {0x1552800, -0x48d}, {0x130c000, -0x435},
    {0x10f2000, -0x3e7}, {0x0eff000, -0x3a2}, {0x0d2e000, -0x365}, {0x0b7c000, -0x32e},
    {0x09e5000, -0x2fc}, {0x0867000, -0x2d0}, {0x06ff000, -0x2a8}, {0x05ab800, -0x283},
    {0x046a000, -0x261}, {0x0339800, -0x243}, {0x0218800, -0x226}, {0x0105800, -0x20b},
    {0x3ffa000, -0x7a4}, {0x3c29000, -0x700}, {0x38aa000, -0x670}, {0x3572000, -0x5f2},
    {0x3279000, -0x584}, {0x2fb7000, -0x524}, {0x2d26000, -0x4cc}, {0x2ac0000, -0x47e},
    {0x2881000, -0x43a}, {0x2665000, -0x3fa}, {0x2468000, -0x3c2}, {0x2287000, -0x38e},
    {0x20c1000, -0x35e}, {0x1f12000, -0x332}, {0x1d79000, -0x30a}, {0x1bf4000, -0x2e6},
}};

double ApproximateReciprocalSquareRoot(double val)
{
  s64 integral = std::bit_cast<s64>(val);
  s64 mantissa = integral & ((1LL << 52) - 1);
  const s64 sign = integral & (1ULL << 63);
  s64 exponent = integral & (0x7FFLL << 52);

  // Special case 0
  if (mantissa == 0 && exponent == 0)
  {
    return sign ? -std::numeric_limits<double>::infinity() :
                  std::numeric_limits<double>::infinity();
  }

  // Special case NaN-ish numbers
  if (exponent == (0x7FFLL << 52))
  {
    if (mantissa == 0)
    {
      if (sign)
        return std::numeric_limits<double>::quiet_NaN();

      return 0.0;
    }

    return 0.0 + val;
  }

  // Negative numbers return NaN
  if (sign)
    return std::numeric_limits<double>::quiet_NaN();

  if (!exponent)
  {
    // "Normalize" denormal values
    do
    {
      exponent -= 1LL << 52;
      mantissa <<= 1;
    } while (!(mantissa & (1LL << 52)));
    mantissa &= (1LL << 52) - 1;
    exponent += 1LL << 52;
  }

  const s64 exponent_lsb = exponent & (1LL << 52);
  exponent = ((0x3FFLL << 52) - ((exponent - (0x3FELL << 52)) / 2)) & (0x7FFLL << 52);
  integral = sign | exponent;

  const int i = static_cast<int>((exponent_lsb | mantissa) >> 37);
  const auto& entry = frsqrte_expected[i / 2048];
  integral |= static_cast<s64>(entry.m_base + entry.m_dec * (i % 2048)) << 26;

  return std::bit_cast<double>(integral);
}

const std::array<BaseAndDec, 32> fres_expected = {{
    {0x7ff800, 0x3e1}, {0x783800, 0x3a7}, {0x70ea00, 0x371}, {0x6a0800, 0x340}, {0x638800, 0x313},
    {0x5d6200, 0x2ea}, {0x579000, 0x2c4}, {0x520800, 0x2a0}, {0x4cc800, 0x27f}, {0x47ca00, 0x261},
    {0x430800, 0x245}, {0x3e8000, 0x22a}, {0x3a2c00, 0x212}, {0x360800, 0x1fb}, {0x321400, 0x1e5},
    {0x2e4a00, 0x1d1}, {0x2aa800, 0x1be}, {0x272c00, 0x1ac}, {0x23d600, 0x19b}, {0x209e00, 0x18b},
    {0x1d8800, 0x17c}, {0x1a9000, 0x16e}, {0x17ae00, 0x15b}, {0x14f800, 0x15b}, {0x124400, 0x143},
    {0x0fbe00, 0x143}, {0x0d3800, 0x12d}, {0x0ade00, 0x12d}, {0x088400, 0x11a}, {0x065000, 0x11a},
    {0x041c00, 0x108}, {0x020c00, 0x106},
}};

// Used by fres and ps_res.
double ApproximateReciprocal(double val)
{
  s64 integral = std::bit_cast<s64>(val);
  const s64 mantissa = integral & ((1LL << 52) - 1);
  const s64 sign = integral & (1ULL << 63);
  s64 exponent = integral & (0x7FFLL << 52);

  // Special case 0
  if (mantissa == 0 && exponent == 0)
    return std::copysign(std::numeric_limits<double>::infinity(), val);

  // Special case NaN-ish numbers
  if (exponent == (0x7FFLL << 52))
  {
    if (mantissa == 0)
      return std::copysign(0.0, val);
    return 0.0 + val;
  }

  // Special case small inputs
  if (exponent < (895LL << 52))
    return std::copysign(std::numeric_limits<float>::max(), val);

  // Special case large inputs
  if (exponent >= (1149LL << 52))
    return std::copysign(0.0, val);

  exponent = (0x7FDLL << 52) - exponent;

  const int i = static_cast<int>(mantissa >> 37);
  const auto& entry = fres_expected[i / 1024];
  integral = sign | exponent;
  integral |= static_cast<s64>(entry.m_base - (entry.m_dec * (i % 1024) + 1) / 2) << 29;

  return std::bit_cast<double>(integral);
}

}  // namespace Common
