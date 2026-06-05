// Copyright 2008 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Core/PowerPC/Interpreter/Interpreter.h"

#include <bit>
#include <cmath>

#include "Common/Assert.h"
#include "Common/CommonTypes.h"
#include "Common/FloatUtils.h"
#include "Core/Config/MainSettings.h"
#include "Core/PowerPC/Interpreter/Interpreter_FPUtils.h"
#include "Core/PowerPC/PowerPC.h"

// ============================================================================
// iCube: NEON (ARM64) paired-single ARITHMETIC fast-path.
//
// The scalar interpreter below emulates each ps_* op as TWO independent scalar f64 lanes. On ARM64 both
// lanes live in one float64x2 register, so vmulq_f64/vaddq_f64/vfmaq_f64 do both lanes in a single op. This
// closes the gap with JitArm64 (which already vectorizes these) for the jitless CachedInterpreter / IR
// engine that iCube's App-Store core relies on.
//
// CORRECTNESS CONTRACT: the fast path is taken ONLY when it can be proven to produce results bit-identical
// to the existing scalar code; otherwise the op runs its UNCHANGED scalar body. The proof rests on:
//   * default round-to-nearest (fpscr.RN == ROUND_NEAR) — the FMA single-round tie correction below is
//     RNE-only, and a non-default mode would also change vcvt rounding.
//   * fpscr.NI == 0 — when NI is set, ForceSingle() applies a non-IEEE subnormal-flush quirk that a plain
//     f64->f32 vcvt does not reproduce.
//   * every INPUT lane (a, and b and/or c as the op uses) is finite-and-normal, which excludes Force25Bit's
//     subnormal-normalization branch and every NI_* NaN/inf/SNaN side-effect path (so the scalar NI_* calls
//     would not have mutated FPSCR — making the reference run side-effect-free).
//   * every RESULT lane (the pre-ForceSingle f64) is finite-and-normal, excluding overflow-to-inf, NaN
//     production (e.g. inf*0), and subnormal results that ForceSingle's NI==0 path leaves alone but whose
//     conversion edge we don't want to reason about.
//   * for the FMA family additionally: neither result lane sits exactly on an even tie (the only case where
//     NI_madd_msub's single-precision once-rounding correction can nudge the f64 by +/-1 ULP vs a plain
//     fma). If a tie is detected we bail to scalar.
//
// The predicate is evaluated for BOTH lanes together; if it fails for EITHER lane the WHOLE op runs scalar.
// We never mix a NEON lane with a scalar lane — that would risk reordering NI_* FPSCR exception writes
// (scalar does ps0 before ps1). The NEON code only ever produces the two `float` lane results; the FPRF/CR1
// tail is the IDENTICAL scalar tail (SetBoth + UpdateFPRFSingle), so FPRF/CR1/dead-FPRF-hint semantics are
// untouched.
//
// PORTABILITY: NEON is ARM64-only. Everything NEON is under the arch guard; on other targets (and whenever
// the flag is off) the ops run the unchanged scalar code, so every build still compiles.
// ============================================================================

namespace
{
// Read the flag once (function-local statics: thread-safe init, read-once; toggling needs an emulation
// restart — same effective semantics as the psq fast-path, which reads at CachedInterpreter::Init). We read
// Config directly here rather than via a PowerPC.cpp accessor so this stays inside Interpreter_Paired.cpp.
bool PsNeonEnabled()
{
  static const bool enabled = Config::Get(Config::MAIN_CIR_PS_NEON);
  return enabled;
}

bool PsNeonValidate()
{
  static const bool validate = Config::Get(Config::MAIN_CIR_PS_NEON_VALIDATE);
  return validate;
}

// The FPSCR-mode gate shared by every accelerated op: flag on, default round-to-nearest, IEEE (NI==0) mode.
// Lane-level finite/normal checks are done per-op after this passes.
inline bool PsNeonModeOk(const PowerPC::PowerPCState& ppc_state)
{
  return PsNeonEnabled() && ppc_state.fpscr.NI == 0 &&
         ppc_state.fpscr.RN == Common::FPU::ROUND_NEAR;
}
}  // namespace

#if defined(_M_ARM_64) || defined(__aarch64__)
#include <arm_neon.h>

namespace
{
// A double bit-pattern is finite-and-normal iff its biased exponent is neither all-zero (zero/subnormal) nor
// all-one (inf/NaN). i.e. 0 < exp < 0x7FF, tested as (exp_field - 1) < (0x7FF - 1) unsigned.
inline bool BothFiniteNormal(float64x2_t v)
{
  const uint64x2_t bits = vreinterpretq_u64_f64(v);
  const uint64x2_t exp = vandq_u64(bits, vdupq_n_u64(Common::DOUBLE_EXP));
  const uint64x2_t exp_shifted = vshrq_n_u64(exp, 52);
  // exp_field - 1 < 0x7FE  <=>  1 <= exp_field <= 0x7FE  (normal range)
  const uint64x2_t minus_one = vsubq_u64(exp_shifted, vdupq_n_u64(1));
  const uint64x2_t in_range = vcltq_u64(minus_one, vdupq_n_u64(0x7FE));
  // Both lanes must be in range.
  return (vgetq_lane_u64(in_range, 0) & vgetq_lane_u64(in_range, 1)) != 0;
}

// SIMD Force25Bit for the finite-NORMAL case only (subnormal lanes are excluded by the predicate, so we only
// need the `else` branch of the scalar Force25Bit: integral = (integral & 0x...F8000000) + (integral &
// 0x8000000)). Caller guarantees both lanes are finite-and-normal.
inline float64x2_t Force25BitNormal(float64x2_t v)
{
  const uint64x2_t bits = vreinterpretq_u64_f64(v);
  const uint64x2_t kept = vandq_u64(bits, vdupq_n_u64(0xFFFFFFFFF8000000ULL));
  const uint64x2_t round = vandq_u64(bits, vdupq_n_u64(0x0000000008000000ULL));
  return vreinterpretq_f64_u64(vaddq_u64(kept, round));
}

// True if EITHER result lane lands exactly on the FMA even-tie (the only case where NI_madd_msub's
// single-precision once-rounding correction could differ by +/-1 ULP from a plain fma). Bail to scalar.
inline bool EitherEvenTie(float64x2_t v)
{
  const uint64x2_t bits = vreinterpretq_u64_f64(v);
  const uint64x2_t masked = vandq_u64(bits, vdupq_n_u64(0x000000001FFFFFFFULL));
  const uint64x2_t is_tie = vceqq_u64(masked, vdupq_n_u64(0x0000000010000000ULL));
  return (vgetq_lane_u64(is_tie, 0) | vgetq_lane_u64(is_tie, 1)) != 0;
}

// Load a PairedSingle's two f64 lanes (PS0 in lane 0, PS1 in lane 1) from their u64 bit-patterns.
inline float64x2_t LoadPS(const PowerPC::PairedSingle& p)
{
  uint64x2_t bits = vdupq_n_u64(0);
  bits = vsetq_lane_u64(p.PS0AsU64(), bits, 0);
  bits = vsetq_lane_u64(p.PS1AsU64(), bits, 1);
  return vreinterpretq_f64_u64(bits);
}

// Broadcast a single PairedSingle lane (already a double) into both float64x2 lanes.
inline float64x2_t Splat(double d)
{
  return vdupq_n_f64(d);
}

// Compute the single-precision FMA family result (a*c +/- b) into a float64x2, returning false (bail to
// scalar) if any input lane is non-normal, the result is non-normal, or the result lands on an even tie that
// the scalar single-round correction could nudge. On success `out` holds the pre-ForceSingle f64 result,
// bit-identical to NI_madd_msub<sub,true>(...).value for these inputs (vfmaq_f64 == std::fma, c is rounded
// via Force25Bit first, no tie correction needed because we excluded ties).
inline bool FmaSingle(float64x2_t va, float64x2_t vc, float64x2_t vb, bool sub, float64x2_t* out)
{
  if (!BothFiniteNormal(va) || !BothFiniteNormal(vc) || !BothFiniteNormal(vb))
    return false;
  const float64x2_t vc25 = Force25BitNormal(vc);
  const float64x2_t b_signed = sub ? vnegq_f64(vb) : vb;
  // vfmaq_f64(acc, x, y) == x*y + acc, single-rounded — matches std::fma(a, c_round, b_sign).
  const float64x2_t vr = vfmaq_f64(b_signed, va, vc25);
  if (!BothFiniteNormal(vr) || EitherEvenTie(vr))
    return false;
  *out = vr;
  return true;
}

// Convert a finite-normal float64x2 result to the two single-precision floats the scalar ForceSingle(NI==0)
// path would produce. With NI==0 and a finite-normal f64 input, ForceSingle reduces to static_cast<float>
// (round-to-nearest), which is exactly vcvt_f32_f64 under the default FPCR — so this matches scalar bit for
// bit. We keep both lanes as floats so the stored FPR bits equal scalar's (double)(float)result.
inline void StoreLanes(float64x2_t result, float* ps0, float* ps1)
{
  const float32x2_t singles = vcvt_f32_f64(result);
  *ps0 = vget_lane_f32(singles, 0);
  *ps1 = vget_lane_f32(singles, 1);
}
}  // namespace
#endif  // ARM64

// These "binary instructions" do not alter FPSCR.
void Interpreter::ps_sel(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];
  const auto& c = ppc_state.ps[inst.FC];

  ppc_state.ps[inst.FD].SetBoth(a.PS0AsDouble() >= -0.0 ? c.PS0AsDouble() : b.PS0AsDouble(),
                                a.PS1AsDouble() >= -0.0 ? c.PS1AsDouble() : b.PS1AsDouble());

  if (inst.Rc)
    ppc_state.UpdateCR1();
}

void Interpreter::ps_neg(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  const auto& b = ppc_state.ps[inst.FB];

  ppc_state.ps[inst.FD].SetBoth(b.PS0AsU64() ^ (UINT64_C(1) << 63),
                                b.PS1AsU64() ^ (UINT64_C(1) << 63));

  if (inst.Rc)
    ppc_state.UpdateCR1();
}

void Interpreter::ps_mr(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  ppc_state.ps[inst.FD] = ppc_state.ps[inst.FB];

  if (inst.Rc)
    ppc_state.UpdateCR1();
}

void Interpreter::ps_nabs(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  const auto& b = ppc_state.ps[inst.FB];

  ppc_state.ps[inst.FD].SetBoth(b.PS0AsU64() | (UINT64_C(1) << 63),
                                b.PS1AsU64() | (UINT64_C(1) << 63));

  if (inst.Rc)
    ppc_state.UpdateCR1();
}

void Interpreter::ps_abs(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  const auto& b = ppc_state.ps[inst.FB];

  ppc_state.ps[inst.FD].SetBoth(b.PS0AsU64() & ~(UINT64_C(1) << 63),
                                b.PS1AsU64() & ~(UINT64_C(1) << 63));

  if (inst.Rc)
    ppc_state.UpdateCR1();
}

// These are just moves, double is OK.
void Interpreter::ps_merge00(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];

  ppc_state.ps[inst.FD].SetBoth(a.PS0AsDouble(), b.PS0AsDouble());

  if (inst.Rc)
    ppc_state.UpdateCR1();
}

void Interpreter::ps_merge01(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];

  ppc_state.ps[inst.FD].SetBoth(a.PS0AsDouble(), b.PS1AsDouble());

  if (inst.Rc)
    ppc_state.UpdateCR1();
}

void Interpreter::ps_merge10(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];

  ppc_state.ps[inst.FD].SetBoth(a.PS1AsDouble(), b.PS0AsDouble());

  if (inst.Rc)
    ppc_state.UpdateCR1();
}

void Interpreter::ps_merge11(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];

  ppc_state.ps[inst.FD].SetBoth(a.PS1AsDouble(), b.PS1AsDouble());

  if (inst.Rc)
    ppc_state.UpdateCR1();
}

// From here on, the real deal.
void Interpreter::ps_div(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];

  const float ps0 =
      ForceSingle(ppc_state.fpscr, NI_div(ppc_state, a.PS0AsDouble(), b.PS0AsDouble()).value);
  const float ps1 =
      ForceSingle(ppc_state.fpscr, NI_div(ppc_state, a.PS1AsDouble(), b.PS1AsDouble()).value);

  ppc_state.ps[inst.FD].SetBoth(ps0, ps1);
  ppc_state.UpdateFPRFSingle(ps0);

  if (inst.Rc)
    ppc_state.UpdateCR1();
}

void Interpreter::ps_res(Interpreter& interpreter, UGeckoInstruction inst)
{
  // this code is based on the real hardware tests
  auto& ppc_state = interpreter.m_ppc_state;
  const double a = ppc_state.ps[inst.FB].PS0AsDouble();
  const double b = ppc_state.ps[inst.FB].PS1AsDouble();

  if (a == 0.0 || b == 0.0)
  {
    SetFPException(ppc_state, FPSCR_ZX);
    ppc_state.fpscr.ClearFIFR();
  }

  if (std::isnan(a) || std::isinf(a) || std::isnan(b) || std::isinf(b))
    ppc_state.fpscr.ClearFIFR();

  if (Common::IsSNAN(a) || Common::IsSNAN(b))
    SetFPException(ppc_state, FPSCR_VXSNAN);

  const double ps0 = Common::ApproximateReciprocal(a);
  const double ps1 = Common::ApproximateReciprocal(b);

  ppc_state.ps[inst.FD].SetBoth(ps0, ps1);
  ppc_state.UpdateFPRFSingle(float(ps0));

  if (inst.Rc)
    ppc_state.UpdateCR1();
}

void Interpreter::ps_rsqrte(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  const double ps0 = ppc_state.ps[inst.FB].PS0AsDouble();
  const double ps1 = ppc_state.ps[inst.FB].PS1AsDouble();

  if (ps0 == 0.0 || ps1 == 0.0)
  {
    SetFPException(ppc_state, FPSCR_ZX);
    ppc_state.fpscr.ClearFIFR();
  }

  if (ps0 < 0.0 || ps1 < 0.0)
  {
    SetFPException(ppc_state, FPSCR_VXSQRT);
    ppc_state.fpscr.ClearFIFR();
  }

  if (std::isnan(ps0) || std::isinf(ps0) || std::isnan(ps1) || std::isinf(ps1))
    ppc_state.fpscr.ClearFIFR();

  if (Common::IsSNAN(ps0) || Common::IsSNAN(ps1))
    SetFPException(ppc_state, FPSCR_VXSNAN);

  const float dst_ps0 = ForceSingle(ppc_state.fpscr, Common::ApproximateReciprocalSquareRoot(ps0));
  const float dst_ps1 = ForceSingle(ppc_state.fpscr, Common::ApproximateReciprocalSquareRoot(ps1));

  ppc_state.ps[inst.FD].SetBoth(dst_ps0, dst_ps1);
  ppc_state.UpdateFPRFSingle(dst_ps0);

  if (inst.Rc)
    ppc_state.UpdateCR1();
}

void Interpreter::ps_sub(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];

#if defined(_M_ARM_64) || defined(__aarch64__)
  if (PsNeonModeOk(ppc_state)) [[unlikely]]
  {
    const float64x2_t va = LoadPS(a);
    const float64x2_t vb = LoadPS(b);
    if (BothFiniteNormal(va) && BothFiniteNormal(vb))
    {
      const float64x2_t vr = vsubq_f64(va, vb);
      if (BothFiniteNormal(vr))
      {
        float ps0, ps1;
        StoreLanes(vr, &ps0, &ps1);

        if (PsNeonValidate()) [[unlikely]]
        {
          const float r0 =
              ForceSingle(ppc_state.fpscr, NI_sub(ppc_state, a.PS0AsDouble(), b.PS0AsDouble()).value);
          const float r1 =
              ForceSingle(ppc_state.fpscr, NI_sub(ppc_state, a.PS1AsDouble(), b.PS1AsDouble()).value);
          ASSERT_MSG(POWERPC,
                     std::bit_cast<u32>(ps0) == std::bit_cast<u32>(r0) &&
                         std::bit_cast<u32>(ps1) == std::bit_cast<u32>(r1),
                     "ps_sub NEON diverged from scalar");
        }

        ppc_state.ps[inst.FD].SetBoth(ps0, ps1);
        ppc_state.UpdateFPRFSingle(ps0);
        if (inst.Rc)
          ppc_state.UpdateCR1();
        return;
      }
    }
  }
#endif

  const float ps0 =
      ForceSingle(ppc_state.fpscr, NI_sub(ppc_state, a.PS0AsDouble(), b.PS0AsDouble()).value);
  const float ps1 =
      ForceSingle(ppc_state.fpscr, NI_sub(ppc_state, a.PS1AsDouble(), b.PS1AsDouble()).value);

  ppc_state.ps[inst.FD].SetBoth(ps0, ps1);
  ppc_state.UpdateFPRFSingle(ps0);

  if (inst.Rc)
    ppc_state.UpdateCR1();
}

void Interpreter::ps_add(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];

#if defined(_M_ARM_64) || defined(__aarch64__)
  if (PsNeonModeOk(ppc_state)) [[unlikely]]
  {
    const float64x2_t va = LoadPS(a);
    const float64x2_t vb = LoadPS(b);
    if (BothFiniteNormal(va) && BothFiniteNormal(vb))
    {
      const float64x2_t vr = vaddq_f64(va, vb);
      if (BothFiniteNormal(vr))
      {
        float ps0, ps1;
        StoreLanes(vr, &ps0, &ps1);

        if (PsNeonValidate()) [[unlikely]]
        {
          const float r0 =
              ForceSingle(ppc_state.fpscr, NI_add(ppc_state, a.PS0AsDouble(), b.PS0AsDouble()).value);
          const float r1 =
              ForceSingle(ppc_state.fpscr, NI_add(ppc_state, a.PS1AsDouble(), b.PS1AsDouble()).value);
          ASSERT_MSG(POWERPC,
                     std::bit_cast<u32>(ps0) == std::bit_cast<u32>(r0) &&
                         std::bit_cast<u32>(ps1) == std::bit_cast<u32>(r1),
                     "ps_add NEON diverged from scalar");
        }

        ppc_state.ps[inst.FD].SetBoth(ps0, ps1);
        ppc_state.UpdateFPRFSingle(ps0);
        if (inst.Rc)
          ppc_state.UpdateCR1();
        return;
      }
    }
  }
#endif

  const float ps0 =
      ForceSingle(ppc_state.fpscr, NI_add(ppc_state, a.PS0AsDouble(), b.PS0AsDouble()).value);
  const float ps1 =
      ForceSingle(ppc_state.fpscr, NI_add(ppc_state, a.PS1AsDouble(), b.PS1AsDouble()).value);

  ppc_state.ps[inst.FD].SetBoth(ps0, ps1);
  ppc_state.UpdateFPRFSingle(ps0);

  if (inst.Rc)
    ppc_state.UpdateCR1();
}

void Interpreter::ps_mul(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  const auto& a = ppc_state.ps[inst.FA];
  const auto& c = ppc_state.ps[inst.FC];

#if defined(_M_ARM_64) || defined(__aarch64__)
  if (PsNeonModeOk(ppc_state)) [[unlikely]]
  {
    const float64x2_t va = LoadPS(a);
    const float64x2_t vc = LoadPS(c);
    if (BothFiniteNormal(va) && BothFiniteNormal(vc))
    {
      const float64x2_t vc25 = Force25BitNormal(vc);
      const float64x2_t vr = vmulq_f64(va, vc25);
      if (BothFiniteNormal(vr))
      {
        float ps0, ps1;
        StoreLanes(vr, &ps0, &ps1);

        if (PsNeonValidate()) [[unlikely]]
        {
          const double rc0 = Force25Bit(c.PS0AsDouble());
          const double rc1 = Force25Bit(c.PS1AsDouble());
          const float r0 = ForceSingle(ppc_state.fpscr, NI_mul(ppc_state, a.PS0AsDouble(), rc0).value);
          const float r1 = ForceSingle(ppc_state.fpscr, NI_mul(ppc_state, a.PS1AsDouble(), rc1).value);
          ASSERT_MSG(POWERPC,
                     std::bit_cast<u32>(ps0) == std::bit_cast<u32>(r0) &&
                         std::bit_cast<u32>(ps1) == std::bit_cast<u32>(r1),
                     "ps_mul NEON diverged from scalar");
        }

        ppc_state.ps[inst.FD].SetBoth(ps0, ps1);
        ppc_state.UpdateFPRFSingle(ps0);
        if (inst.Rc)
          ppc_state.UpdateCR1();
        return;
      }
    }
  }
#endif

  const double c0 = Force25Bit(c.PS0AsDouble());
  const double c1 = Force25Bit(c.PS1AsDouble());

  const float ps0 = ForceSingle(ppc_state.fpscr, NI_mul(ppc_state, a.PS0AsDouble(), c0).value);
  const float ps1 = ForceSingle(ppc_state.fpscr, NI_mul(ppc_state, a.PS1AsDouble(), c1).value);

  ppc_state.ps[inst.FD].SetBoth(ps0, ps1);
  ppc_state.UpdateFPRFSingle(ps0);

  if (inst.Rc)
    ppc_state.UpdateCR1();
}

void Interpreter::ps_msub(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];
  const auto& c = ppc_state.ps[inst.FC];

#if defined(_M_ARM_64) || defined(__aarch64__)
  if (PsNeonModeOk(ppc_state)) [[unlikely]]
  {
    float64x2_t vr;
    if (FmaSingle(LoadPS(a), LoadPS(c), LoadPS(b), true, &vr))
    {
      float ps0, ps1;
      StoreLanes(vr, &ps0, &ps1);

      if (PsNeonValidate()) [[unlikely]]
      {
        const float r0 = ForceSingle(
            ppc_state.fpscr,
            NI_msub<true>(ppc_state, a.PS0AsDouble(), c.PS0AsDouble(), b.PS0AsDouble()).value);
        const float r1 = ForceSingle(
            ppc_state.fpscr,
            NI_msub<true>(ppc_state, a.PS1AsDouble(), c.PS1AsDouble(), b.PS1AsDouble()).value);
        ASSERT_MSG(POWERPC,
                   std::bit_cast<u32>(ps0) == std::bit_cast<u32>(r0) &&
                       std::bit_cast<u32>(ps1) == std::bit_cast<u32>(r1),
                   "ps_msub NEON diverged from scalar");
      }

      ppc_state.ps[inst.FD].SetBoth(ps0, ps1);
      ppc_state.UpdateFPRFSingle(ps0);
      if (inst.Rc)
        ppc_state.UpdateCR1();
      return;
    }
  }
#endif

  const float ps0 = ForceSingle(
      ppc_state.fpscr,
      NI_msub<true>(ppc_state, a.PS0AsDouble(), c.PS0AsDouble(), b.PS0AsDouble()).value);
  const float ps1 = ForceSingle(
      ppc_state.fpscr,
      NI_msub<true>(ppc_state, a.PS1AsDouble(), c.PS1AsDouble(), b.PS1AsDouble()).value);

  ppc_state.ps[inst.FD].SetBoth(ps0, ps1);
  ppc_state.UpdateFPRFSingle(ps0);

  if (inst.Rc)
    ppc_state.UpdateCR1();
}

void Interpreter::ps_madd(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];
  const auto& c = ppc_state.ps[inst.FC];

#if defined(_M_ARM_64) || defined(__aarch64__)
  if (PsNeonModeOk(ppc_state)) [[unlikely]]
  {
    float64x2_t vr;
    if (FmaSingle(LoadPS(a), LoadPS(c), LoadPS(b), false, &vr))
    {
      float ps0, ps1;
      StoreLanes(vr, &ps0, &ps1);

      if (PsNeonValidate()) [[unlikely]]
      {
        const float r0 = ForceSingle(
            ppc_state.fpscr,
            NI_madd<true>(ppc_state, a.PS0AsDouble(), c.PS0AsDouble(), b.PS0AsDouble()).value);
        const float r1 = ForceSingle(
            ppc_state.fpscr,
            NI_madd<true>(ppc_state, a.PS1AsDouble(), c.PS1AsDouble(), b.PS1AsDouble()).value);
        ASSERT_MSG(POWERPC,
                   std::bit_cast<u32>(ps0) == std::bit_cast<u32>(r0) &&
                       std::bit_cast<u32>(ps1) == std::bit_cast<u32>(r1),
                   "ps_madd NEON diverged from scalar");
      }

      ppc_state.ps[inst.FD].SetBoth(ps0, ps1);
      ppc_state.UpdateFPRFSingle(ps0);
      if (inst.Rc)
        ppc_state.UpdateCR1();
      return;
    }
  }
#endif

  const float ps0 = ForceSingle(
      ppc_state.fpscr,
      NI_madd<true>(ppc_state, a.PS0AsDouble(), c.PS0AsDouble(), b.PS0AsDouble()).value);
  const float ps1 = ForceSingle(
      ppc_state.fpscr,
      NI_madd<true>(ppc_state, a.PS1AsDouble(), c.PS1AsDouble(), b.PS1AsDouble()).value);

  ppc_state.ps[inst.FD].SetBoth(ps0, ps1);
  ppc_state.UpdateFPRFSingle(ps0);

  if (inst.Rc)
    ppc_state.UpdateCR1();
}

void Interpreter::ps_nmsub(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];
  const auto& c = ppc_state.ps[inst.FC];

#if defined(_M_ARM_64) || defined(__aarch64__)
  if (PsNeonModeOk(ppc_state)) [[unlikely]]
  {
    float64x2_t vr;
    if (FmaSingle(LoadPS(a), LoadPS(c), LoadPS(b), true, &vr))
    {
      // Result is finite-normal (never NaN), so the scalar `isnan(tmp) ? tmp : -tmp` is always the negate.
      float tmp0, tmp1;
      StoreLanes(vr, &tmp0, &tmp1);
      const float ps0 = -tmp0;
      const float ps1 = -tmp1;

      if (PsNeonValidate()) [[unlikely]]
      {
        const float st0 = ForceSingle(
            ppc_state.fpscr,
            NI_msub<true>(ppc_state, a.PS0AsDouble(), c.PS0AsDouble(), b.PS0AsDouble()).value);
        const float st1 = ForceSingle(
            ppc_state.fpscr,
            NI_msub<true>(ppc_state, a.PS1AsDouble(), c.PS1AsDouble(), b.PS1AsDouble()).value);
        const float r0 = std::isnan(st0) ? st0 : -st0;
        const float r1 = std::isnan(st1) ? st1 : -st1;
        ASSERT_MSG(POWERPC,
                   std::bit_cast<u32>(ps0) == std::bit_cast<u32>(r0) &&
                       std::bit_cast<u32>(ps1) == std::bit_cast<u32>(r1),
                   "ps_nmsub NEON diverged from scalar");
      }

      ppc_state.ps[inst.FD].SetBoth(ps0, ps1);
      ppc_state.UpdateFPRFSingle(ps0);
      if (inst.Rc)
        ppc_state.UpdateCR1();
      return;
    }
  }
#endif

  const float tmp0 = ForceSingle(
      ppc_state.fpscr,
      NI_msub<true>(ppc_state, a.PS0AsDouble(), c.PS0AsDouble(), b.PS0AsDouble()).value);
  const float tmp1 = ForceSingle(
      ppc_state.fpscr,
      NI_msub<true>(ppc_state, a.PS1AsDouble(), c.PS1AsDouble(), b.PS1AsDouble()).value);

  const float ps0 = std::isnan(tmp0) ? tmp0 : -tmp0;
  const float ps1 = std::isnan(tmp1) ? tmp1 : -tmp1;

  ppc_state.ps[inst.FD].SetBoth(ps0, ps1);
  ppc_state.UpdateFPRFSingle(ps0);

  if (inst.Rc)
    ppc_state.UpdateCR1();
}

void Interpreter::ps_nmadd(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];
  const auto& c = ppc_state.ps[inst.FC];

#if defined(_M_ARM_64) || defined(__aarch64__)
  if (PsNeonModeOk(ppc_state)) [[unlikely]]
  {
    float64x2_t vr;
    if (FmaSingle(LoadPS(a), LoadPS(c), LoadPS(b), false, &vr))
    {
      // Result is finite-normal (never NaN), so the scalar `isnan(tmp) ? tmp : -tmp` is always the negate.
      float tmp0, tmp1;
      StoreLanes(vr, &tmp0, &tmp1);
      const float ps0 = -tmp0;
      const float ps1 = -tmp1;

      if (PsNeonValidate()) [[unlikely]]
      {
        const float st0 = ForceSingle(
            ppc_state.fpscr,
            NI_madd<true>(ppc_state, a.PS0AsDouble(), c.PS0AsDouble(), b.PS0AsDouble()).value);
        const float st1 = ForceSingle(
            ppc_state.fpscr,
            NI_madd<true>(ppc_state, a.PS1AsDouble(), c.PS1AsDouble(), b.PS1AsDouble()).value);
        const float r0 = std::isnan(st0) ? st0 : -st0;
        const float r1 = std::isnan(st1) ? st1 : -st1;
        ASSERT_MSG(POWERPC,
                   std::bit_cast<u32>(ps0) == std::bit_cast<u32>(r0) &&
                       std::bit_cast<u32>(ps1) == std::bit_cast<u32>(r1),
                   "ps_nmadd NEON diverged from scalar");
      }

      ppc_state.ps[inst.FD].SetBoth(ps0, ps1);
      ppc_state.UpdateFPRFSingle(ps0);
      if (inst.Rc)
        ppc_state.UpdateCR1();
      return;
    }
  }
#endif

  const float tmp0 = ForceSingle(
      ppc_state.fpscr,
      NI_madd<true>(ppc_state, a.PS0AsDouble(), c.PS0AsDouble(), b.PS0AsDouble()).value);
  const float tmp1 = ForceSingle(
      ppc_state.fpscr,
      NI_madd<true>(ppc_state, a.PS1AsDouble(), c.PS1AsDouble(), b.PS1AsDouble()).value);

  const float ps0 = std::isnan(tmp0) ? tmp0 : -tmp0;
  const float ps1 = std::isnan(tmp1) ? tmp1 : -tmp1;

  ppc_state.ps[inst.FD].SetBoth(ps0, ps1);
  ppc_state.UpdateFPRFSingle(ps0);

  if (inst.Rc)
    ppc_state.UpdateCR1();
}

void Interpreter::ps_sum0(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];
  const auto& c = ppc_state.ps[inst.FC];

  const float ps0 =
      ForceSingle(ppc_state.fpscr, NI_add(ppc_state, a.PS0AsDouble(), b.PS1AsDouble()).value);
  const float ps1 = ForceSingle(ppc_state.fpscr, c.PS1AsDouble());

  ppc_state.ps[inst.FD].SetBoth(ps0, ps1);
  ppc_state.UpdateFPRFSingle(ps0);

  if (inst.Rc)
    ppc_state.UpdateCR1();
}

void Interpreter::ps_sum1(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];
  const auto& c = ppc_state.ps[inst.FC];

  const float ps0 = ForceSingle(ppc_state.fpscr, c.PS0AsDouble());
  const float ps1 =
      ForceSingle(ppc_state.fpscr, NI_add(ppc_state, a.PS0AsDouble(), b.PS1AsDouble()).value);

  ppc_state.ps[inst.FD].SetBoth(ps0, ps1);
  ppc_state.UpdateFPRFSingle(ps1);

  if (inst.Rc)
    ppc_state.UpdateCR1();
}

void Interpreter::ps_muls0(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  const auto& a = ppc_state.ps[inst.FA];
  const auto& c = ppc_state.ps[inst.FC];

#if defined(_M_ARM_64) || defined(__aarch64__)
  if (PsNeonModeOk(ppc_state)) [[unlikely]]
  {
    const float64x2_t va = LoadPS(a);
    const float64x2_t vc = Splat(c.PS0AsDouble());  // broadcast the PS0 multiplier into both lanes
    if (BothFiniteNormal(va) && BothFiniteNormal(vc))
    {
      const float64x2_t vc25 = Force25BitNormal(vc);
      const float64x2_t vr = vmulq_f64(va, vc25);
      if (BothFiniteNormal(vr))
      {
        float ps0, ps1;
        StoreLanes(vr, &ps0, &ps1);

        if (PsNeonValidate()) [[unlikely]]
        {
          const double rc0 = Force25Bit(c.PS0AsDouble());
          const float r0 = ForceSingle(ppc_state.fpscr, NI_mul(ppc_state, a.PS0AsDouble(), rc0).value);
          const float r1 = ForceSingle(ppc_state.fpscr, NI_mul(ppc_state, a.PS1AsDouble(), rc0).value);
          ASSERT_MSG(POWERPC,
                     std::bit_cast<u32>(ps0) == std::bit_cast<u32>(r0) &&
                         std::bit_cast<u32>(ps1) == std::bit_cast<u32>(r1),
                     "ps_muls0 NEON diverged from scalar");
        }

        ppc_state.ps[inst.FD].SetBoth(ps0, ps1);
        ppc_state.UpdateFPRFSingle(ps0);
        if (inst.Rc)
          ppc_state.UpdateCR1();
        return;
      }
    }
  }
#endif

  const double c0 = Force25Bit(c.PS0AsDouble());
  const float ps0 = ForceSingle(ppc_state.fpscr, NI_mul(ppc_state, a.PS0AsDouble(), c0).value);
  const float ps1 = ForceSingle(ppc_state.fpscr, NI_mul(ppc_state, a.PS1AsDouble(), c0).value);

  ppc_state.ps[inst.FD].SetBoth(ps0, ps1);
  ppc_state.UpdateFPRFSingle(ps0);

  if (inst.Rc)
    ppc_state.UpdateCR1();
}

void Interpreter::ps_muls1(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  const auto& a = ppc_state.ps[inst.FA];
  const auto& c = ppc_state.ps[inst.FC];

#if defined(_M_ARM_64) || defined(__aarch64__)
  if (PsNeonModeOk(ppc_state)) [[unlikely]]
  {
    const float64x2_t va = LoadPS(a);
    const float64x2_t vc = Splat(c.PS1AsDouble());  // broadcast the PS1 multiplier into both lanes
    if (BothFiniteNormal(va) && BothFiniteNormal(vc))
    {
      const float64x2_t vc25 = Force25BitNormal(vc);
      const float64x2_t vr = vmulq_f64(va, vc25);
      if (BothFiniteNormal(vr))
      {
        float ps0, ps1;
        StoreLanes(vr, &ps0, &ps1);

        if (PsNeonValidate()) [[unlikely]]
        {
          const double rc1 = Force25Bit(c.PS1AsDouble());
          const float r0 = ForceSingle(ppc_state.fpscr, NI_mul(ppc_state, a.PS0AsDouble(), rc1).value);
          const float r1 = ForceSingle(ppc_state.fpscr, NI_mul(ppc_state, a.PS1AsDouble(), rc1).value);
          ASSERT_MSG(POWERPC,
                     std::bit_cast<u32>(ps0) == std::bit_cast<u32>(r0) &&
                         std::bit_cast<u32>(ps1) == std::bit_cast<u32>(r1),
                     "ps_muls1 NEON diverged from scalar");
        }

        ppc_state.ps[inst.FD].SetBoth(ps0, ps1);
        ppc_state.UpdateFPRFSingle(ps0);
        if (inst.Rc)
          ppc_state.UpdateCR1();
        return;
      }
    }
  }
#endif

  const double c1 = Force25Bit(c.PS1AsDouble());
  const float ps0 = ForceSingle(ppc_state.fpscr, NI_mul(ppc_state, a.PS0AsDouble(), c1).value);
  const float ps1 = ForceSingle(ppc_state.fpscr, NI_mul(ppc_state, a.PS1AsDouble(), c1).value);

  ppc_state.ps[inst.FD].SetBoth(ps0, ps1);
  ppc_state.UpdateFPRFSingle(ps0);

  if (inst.Rc)
    ppc_state.UpdateCR1();
}

void Interpreter::ps_madds0(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];
  const auto& c = ppc_state.ps[inst.FC];

#if defined(_M_ARM_64) || defined(__aarch64__)
  if (PsNeonModeOk(ppc_state)) [[unlikely]]
  {
    float64x2_t vr;
    if (FmaSingle(LoadPS(a), Splat(c.PS0AsDouble()), LoadPS(b), false, &vr))  // C broadcast from PS0
    {
      float ps0, ps1;
      StoreLanes(vr, &ps0, &ps1);

      if (PsNeonValidate()) [[unlikely]]
      {
        const float r0 = ForceSingle(
            ppc_state.fpscr,
            NI_madd<true>(ppc_state, a.PS0AsDouble(), c.PS0AsDouble(), b.PS0AsDouble()).value);
        const float r1 = ForceSingle(
            ppc_state.fpscr,
            NI_madd<true>(ppc_state, a.PS1AsDouble(), c.PS0AsDouble(), b.PS1AsDouble()).value);
        ASSERT_MSG(POWERPC,
                   std::bit_cast<u32>(ps0) == std::bit_cast<u32>(r0) &&
                       std::bit_cast<u32>(ps1) == std::bit_cast<u32>(r1),
                   "ps_madds0 NEON diverged from scalar");
      }

      ppc_state.ps[inst.FD].SetBoth(ps0, ps1);
      ppc_state.UpdateFPRFSingle(ps0);
      if (inst.Rc)
        ppc_state.UpdateCR1();
      return;
    }
  }
#endif

  const float ps0 = ForceSingle(
      ppc_state.fpscr,
      NI_madd<true>(ppc_state, a.PS0AsDouble(), c.PS0AsDouble(), b.PS0AsDouble()).value);
  const float ps1 = ForceSingle(
      ppc_state.fpscr,
      NI_madd<true>(ppc_state, a.PS1AsDouble(), c.PS0AsDouble(), b.PS1AsDouble()).value);

  ppc_state.ps[inst.FD].SetBoth(ps0, ps1);
  ppc_state.UpdateFPRFSingle(ps0);

  if (inst.Rc)
    ppc_state.UpdateCR1();
}

void Interpreter::ps_madds1(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];
  const auto& c = ppc_state.ps[inst.FC];

#if defined(_M_ARM_64) || defined(__aarch64__)
  if (PsNeonModeOk(ppc_state)) [[unlikely]]
  {
    float64x2_t vr;
    if (FmaSingle(LoadPS(a), Splat(c.PS1AsDouble()), LoadPS(b), false, &vr))  // C broadcast from PS1
    {
      float ps0, ps1;
      StoreLanes(vr, &ps0, &ps1);

      if (PsNeonValidate()) [[unlikely]]
      {
        const float r0 = ForceSingle(
            ppc_state.fpscr,
            NI_madd<true>(ppc_state, a.PS0AsDouble(), c.PS1AsDouble(), b.PS0AsDouble()).value);
        const float r1 = ForceSingle(
            ppc_state.fpscr,
            NI_madd<true>(ppc_state, a.PS1AsDouble(), c.PS1AsDouble(), b.PS1AsDouble()).value);
        ASSERT_MSG(POWERPC,
                   std::bit_cast<u32>(ps0) == std::bit_cast<u32>(r0) &&
                       std::bit_cast<u32>(ps1) == std::bit_cast<u32>(r1),
                   "ps_madds1 NEON diverged from scalar");
      }

      ppc_state.ps[inst.FD].SetBoth(ps0, ps1);
      ppc_state.UpdateFPRFSingle(ps0);
      if (inst.Rc)
        ppc_state.UpdateCR1();
      return;
    }
  }
#endif

  const float ps0 = ForceSingle(
      ppc_state.fpscr,
      NI_madd<true>(ppc_state, a.PS0AsDouble(), c.PS1AsDouble(), b.PS0AsDouble()).value);
  const float ps1 = ForceSingle(
      ppc_state.fpscr,
      NI_madd<true>(ppc_state, a.PS1AsDouble(), c.PS1AsDouble(), b.PS1AsDouble()).value);

  ppc_state.ps[inst.FD].SetBoth(ps0, ps1);
  ppc_state.UpdateFPRFSingle(ps0);

  if (inst.Rc)
    ppc_state.UpdateCR1();
}

void Interpreter::ps_cmpu0(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];

  Helper_FloatCompareUnordered(ppc_state, inst, a.PS0AsDouble(), b.PS0AsDouble());
}

void Interpreter::ps_cmpo0(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];

  Helper_FloatCompareOrdered(ppc_state, inst, a.PS0AsDouble(), b.PS0AsDouble());
}

void Interpreter::ps_cmpu1(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];

  Helper_FloatCompareUnordered(ppc_state, inst, a.PS1AsDouble(), b.PS1AsDouble());
}

void Interpreter::ps_cmpo1(Interpreter& interpreter, UGeckoInstruction inst)
{
  auto& ppc_state = interpreter.m_ppc_state;
  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];

  Helper_FloatCompareOrdered(ppc_state, inst, a.PS1AsDouble(), b.PS1AsDouble());
}
