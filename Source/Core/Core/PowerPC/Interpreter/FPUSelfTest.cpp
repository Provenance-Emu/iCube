// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Core/PowerPC/Interpreter/FPUSelfTest.h"

#include <bit>
#include <cmath>
#include <cstdint>
#include <string>

#include <fmt/format.h>

#include "Common/CPUDetect.h"
#include "Common/FPURoundMode.h"
#include "Common/FloatUtils.h"
#include "Core/PowerPC/Interpreter/Interpreter_FPUtils.h"
#include "Core/PowerPC/PowerPC.h"
#include "Core/System.h"

namespace PowerPC
{
namespace
{
#if defined(__aarch64__) || defined(_M_ARM_64)
u64 ReadFPCR()
{
  u64 v;
  __asm__ __volatile__("mrs %0, fpcr" : "=r"(v));
  return v;
}
#else
u64 ReadFPCR()
{
  return 0;
}
#endif

std::string Hex(double d)
{
  return fmt::format("{:016x}", std::bit_cast<u64>(d));
}
std::string Hex(float f)
{
  return fmt::format("{:08x}", std::bit_cast<u32>(f));
}
}  // namespace

std::string RunFPUSelfTest()
{
  auto& ppc = Core::System::GetInstance().GetPPCState();
  const u32 saved_fpscr_hex = ppc.fpscr.Hex;
  std::string out;
  out += fmt::format("host bAFP={} bFlushToZero={} fpcr_before={:016x}\n", cpu_info.bAFP,
                     cpu_info.bFlushToZero, ReadFPCR());

  const double inputs[] = {0.5,
                           1.0 / 3.0,
                           123.456,
                           -0.0,
                           1e-3,
                           7.0,
                           std::bit_cast<double>(u64{0x0000000000000001}),  // subnormal double
                           1e-40,                                            // subnormal as single
                           1e30,
                           0.70710678118654752,
                           3.0};
  // mode 0: IEEE (RN, no flush); mode 1: FZ only; mode 2: Dolphin non-IEEE (FZ|AH via SetSIMDMode)
  for (int mode = 0; mode < 3; ++mode)
  {
    if (mode == 2)
      Common::FPU::SetSIMDMode(Common::FPU::ROUND_NEAR, true);
    else
      Common::FPU::SetSIMDMode(Common::FPU::ROUND_NEAR, false);
#if defined(__aarch64__) || defined(_M_ARM_64)
    if (mode == 1)
    {
      u64 v = ReadFPCR() | (1ull << 24);
      __asm__ __volatile__("msr fpcr, %0" : : "r"(v));
    }
#endif
    ppc.fpscr.Hex = 0;
    ppc.fpscr.NI = (mode == 2) ? 1 : 0;
    ppc.fpscr.RN = Common::FPU::ROUND_NEAR;
    out += fmt::format("mode{} fpcr={:016x}\n", mode, ReadFPCR());
    for (double a : inputs)
    {
      for (double b : {1.0 / 3.0, 7.0, 1e-3})
      {
        const double c = 0.70710678118654752;
        out += fmt::format("m{} a={} b={} mul={} add={} madd={} msub={} fs_mul={} fma_raw={}\n", mode,
                           Hex(a), Hex(b), Hex(NI_mul(ppc, a, Force25Bit(b)).value),
                           Hex(NI_add(ppc, a, b).value), Hex(NI_madd<true>(ppc, a, c, b).value),
                           Hex(NI_msub<true>(ppc, a, c, b).value),
                           Hex(ForceSingle(ppc.fpscr, NI_mul(ppc, a, Force25Bit(b)).value)),
                           Hex(std::fma(a, c, b)));
      }
      out += fmt::format("m{} a={} fs={} f25={} rsqrte={} res={} cvt={} sqrt={}\n", mode, Hex(a),
                         Hex(ForceSingle(ppc.fpscr, a)), Hex(Force25Bit(a)),
                         Hex(Common::ApproximateReciprocalSquareRoot(a)),
                         Hex(Common::ApproximateReciprocal(a)), Hex(static_cast<float>(a)),
                         Hex(std::sqrt(a)));
    }
    // psq-style dequantize of a few fixed-point values at scales 0, 3, 7, 12 (float math).
    for (int scale : {0, 3, 7, 12})
    {
      const float k = 1.0f / static_cast<float>(1u << scale);
      out += fmt::format("m{} deq scale={} s16(1234)={} s8(-77)={} u16(60000)={}\n", mode, scale,
                         Hex(static_cast<float>(int16_t{1234}) * k),
                         Hex(static_cast<float>(int8_t{-77}) * k),
                         Hex(static_cast<float>(uint16_t{60000}) * k));
    }
    // Single-precision chains as the game would do them: normalize (x,y,z) via 1/sqrt.
    {
      const float x = 0.3f, y = -4.1f, z = 2.7f;
      const float len2 = x * x + y * y + z * z;
      const float inv = 1.0f / std::sqrt(len2);
      out += fmt::format("m{} norm len2={} inv={} nx={}\n", mode, Hex(len2), Hex(inv), Hex(x * inv));
    }
  }
  ppc.fpscr.Hex = saved_fpscr_hex;
  Common::FPU::SetSIMDMode(ppc.fpscr.RN, ppc.fpscr.NI != 0);
  return out;
}
}  // namespace PowerPC
