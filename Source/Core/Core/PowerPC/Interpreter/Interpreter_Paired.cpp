// Copyright 2008 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Core/PowerPC/Interpreter/Interpreter.h"

#include <bit>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <iterator>
#include <string>

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
//   * the op runs in BOTH IEEE (NI==0) and non-IEEE (NI==1) mode. NI=1 differs from NI=0 ONLY in
//     ForceSingle()'s subnormal-flush quirk, which fires when the pre-rounding f64 result magnitude is
//     below the smallest normal single (0x3810000000000000 as a double): NI=1 flushes that to signed zero,
//     NI=0 converts it normally. We therefore gate per-RESULT-lane on "the result is NI-independent": its
//     magnitude is >= 0x3810000000000000 so ForceSingle's flush branch never fires AND its converted single
//     is a normal single so ForceSingle's secondary FlushToZero(x) branch is a no-op too. For such results a
//     plain f64->f32 vcvt is bit-identical under both NI modes. Subnormal-single results (the only remaining
//     NI-sensitive case) bail to scalar. This is ADDED on top of the finite-normal result guard, not in
//     place of it — inf/NaN also satisfy >= the threshold, so both checks are required.
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
// NEON paired-single fast-path flags, cached at file scope and refreshed each engine boot via
// Interpreter::RefreshNeonPairedConfig() (called from every CPU engine's Init()). NOTE: these were
// previously function-local `static const`, so they were read ONCE per app process — a toggle then
// silently did nothing until a full app restart, making "NEON Paired-Single Math" appear broken when
// only the game was relaunched. They now re-read per game-boot like every other CIR/IR optimization flag.
bool s_ps_neon_enabled = false;
bool s_ps_neon_validate = false;

bool PsNeonEnabled() { return s_ps_neon_enabled; }
bool PsNeonValidate() { return s_ps_neon_validate; }

// iCube: fast-path observability. CIRPsNeon measured +4.3 % on NFS Underground but -1.2 % on Wind
// Waker and -2.7 % on Chibi-Robo, and a speed number alone cannot say why. A game loses either
// because most ops bail (pay the guard, then run scalar anyway) or because hits themselves cost
// more than they save; these counters tell the two apart. Profiler-gated (MAIN_CIR_PROFILE) like
// the CIR gp_fused_* counters, so a speed leg with the profiler off pays one predicted branch per
// op. A bail is classified only on the bail path. CPU thread only; the report reads them racily,
// which is fine for a perf report.
enum class PsNeonOp : u8
{
  Add,
  Sub,
  Mul,
  Muls0,
  Muls1,
  Madd,
  Msub,
  Nmadd,
  Nmsub,
  Madds0,
  Madds1,
  Count
};
constexpr const char* kPsNeonOpNames[] = {"ps_add",   "ps_sub",    "ps_mul",   "ps_muls0",
                                          "ps_muls1", "ps_madd",   "ps_msub",  "ps_nmadd",
                                          "ps_nmsub", "ps_madds0", "ps_madds1"};
static_assert(std::size(kPsNeonOpNames) == static_cast<size_t>(PsNeonOp::Count));

// Within the input group and within the result group the later reason wins when lanes disagree, so
// a bail filed as "zero" means EVERY offending lane was an exact (signed) zero — the count that
// tells whether admitting zeros to the fast path would recover it.
enum class PsNeonBail : u8
{
  Mode,         // fpscr.RN is not round-to-nearest
  InZero,       // an input lane is +/-0
  InSubnormal,  // an input lane is a subnormal double
  InInfNan,     // an input lane is inf or NaN
  OutZero,      // a result lane is +/-0 (x-x, x+(-x); x*0 already bailed as in_zero)
  OutBelowNi,   // a result lane is nonzero but below the smallest normal single (NI-mode dependent)
  OutInfNan,    // a result lane overflowed or is NaN
  Tie,          // FMA result on the even tie that the scalar single-rounding correction handles
  Count
};
constexpr const char* kPsNeonBailNames[] = {"mode",     "in_zero",   "in_sub",     "in_infnan",
                                            "out_zero", "out_lowNI", "out_infnan", "tie"};
static_assert(std::size(kPsNeonBailNames) == static_cast<size_t>(PsNeonBail::Count));

struct PsNeonStats
{
  u64 hits;
  u64 bails[static_cast<size_t>(PsNeonBail::Count)];
};
bool s_ps_neon_profile = false;
PsNeonStats s_ps_neon_stats[static_cast<size_t>(PsNeonOp::Count)] = {};

inline void PsNeonCountHit(PsNeonOp op)
{
  if (s_ps_neon_profile) [[unlikely]]
    ++s_ps_neon_stats[static_cast<size_t>(op)].hits;
}

inline void PsNeonCountBail(PsNeonOp op, PsNeonBail why)
{
  ++s_ps_neon_stats[static_cast<size_t>(op)].bails[static_cast<size_t>(why)];
}

// The FPSCR-mode gate shared by every accelerated op: flag on, default round-to-nearest. NI is NOT gated
// here: the fast path runs in BOTH NI==0 and NI==1, with the NI-difference (subnormal-single result flush)
// excluded per-RESULT-lane by ResultNiIndependent below. Lane-level finite/normal checks are done per-op.
inline bool PsNeonModeOk(const PowerPC::PowerPCState& ppc_state, PsNeonOp op)
{
  if (!PsNeonEnabled())
    return false;
  if (ppc_state.fpscr.RN == Common::FPU::ROUND_NEAR) [[likely]]
    return true;
  if (s_ps_neon_profile) [[unlikely]]
    PsNeonCountBail(op, PsNeonBail::Mode);
  return false;
}
}  // namespace

// iCube: refresh the NEON paired-single fast-path flags from Config. Called from every CPU engine's Init()
// so toggling the setting + relaunching the game applies it (see the s_ps_neon_* note above). Kept here so
// the Config read stays in this translation unit with the flags it controls.
void Interpreter::RefreshNeonPairedConfig()
{
  s_ps_neon_enabled = Config::Get(Config::MAIN_CIR_PS_NEON);
  s_ps_neon_validate = Config::Get(Config::MAIN_CIR_PS_NEON_VALIDATE);
  s_ps_neon_profile = Config::Get(Config::MAIN_CIR_PROFILE);
  std::memset(s_ps_neon_stats, 0, sizeof(s_ps_neon_stats));
}

std::string Interpreter::BuildPsNeonReport()
{
  std::string out = "  -- PS NEON FAST PATH (CIRPsNeon=";
  out += s_ps_neon_enabled ? "1" : "0";
  out += "; bail columns are % of tries, a bail runs the scalar body) --\n";
  if (!s_ps_neon_profile)
    return out + "     (counted only while the CIR profiler is on)\n";
  if (!s_ps_neon_enabled)
    return out + "     (fast path off: no tries)\n";

  char line[224];
  int n = std::snprintf(line, sizeof(line), "     %-10s %12s %6s", "op", "tries", "hit%");
  for (const char* name : kPsNeonBailNames)
    n += std::snprintf(line + n, sizeof(line) - n, " %10s", name);
  out += line;
  out += "\n";

  PsNeonStats total{};
  const auto append_row = [&out, &line](const char* name, const PsNeonStats& st) {
    u64 tries = st.hits;
    for (const u64 b : st.bails)
      tries += b;
    if (tries == 0)
      return;
    const double denom = static_cast<double>(tries);
    int len = std::snprintf(line, sizeof(line), "     %-10s %12llu %6.1f", name,
                            static_cast<unsigned long long>(tries),
                            100.0 * static_cast<double>(st.hits) / denom);
    for (const u64 b : st.bails)
      len += std::snprintf(line + len, sizeof(line) - len, " %10.2f",
                           100.0 * static_cast<double>(b) / denom);
    out += line;
    out += "\n";
  };
  for (size_t i = 0; i < static_cast<size_t>(PsNeonOp::Count); ++i)
  {
    const PsNeonStats& st = s_ps_neon_stats[i];
    append_row(kPsNeonOpNames[i], st);
    total.hits += st.hits;
    for (size_t b = 0; b < static_cast<size_t>(PsNeonBail::Count); ++b)
      total.bails[b] += st.bails[b];
  }
  append_row("TOTAL", total);
  return out;
}

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

// True if BOTH result lanes are NI-independent: each lane's magnitude (sign stripped) is >= the smallest
// normal single represented as a double (0x3810000000000000). This is ForceSingle's OWN flush comparison
// (Interpreter_FPUtils.h ForceSingle, NI==1 branch) — at or above it the subnormal-flush never fires, and
// the converted single is normal so the secondary FlushToZero(x) branch is a no-op too. Below it NI=1 would
// flush to signed zero while NI=0 would not, so we must bail to scalar. This is an ADDITIONAL lower bound; it
// does NOT subsume BothFiniteNormal (inf/NaN have exp 0x7FF and also pass this >= test), so callers apply
// BOTH guards together. Caller has already established the result is finite-and-normal-f64.
inline bool BothResultNiIndependent(float64x2_t v)
{
  const uint64x2_t bits = vreinterpretq_u64_f64(v);
  const uint64x2_t magnitude =
      vandq_u64(bits, vdupq_n_u64(Common::DOUBLE_EXP | Common::DOUBLE_FRAC));
  // magnitude >= 0x3810000000000000  <=>  NOT (magnitude < smallest_normal_single)
  const uint64x2_t below = vcltq_u64(magnitude, vdupq_n_u64(0x3810000000000000ULL));
  // Both lanes must be at-or-above the threshold (neither lane "below").
  return (vgetq_lane_u64(below, 0) | vgetq_lane_u64(below, 1)) == 0;
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

// Bail classifiers for the profiler (see PsNeonBail). Only ever called on a bail with the profiler
// on. Each returns the worst reason over both lanes (inf/NaN, then subnormal/below-NI, then exact
// zero), or `worst` unchanged if both lanes pass.
inline PsNeonBail ClassifyInputLanes(float64x2_t v, PsNeonBail worst)
{
  const uint64x2_t bits = vreinterpretq_u64_f64(v);
  for (const u64 lane : {vgetq_lane_u64(bits, 0), vgetq_lane_u64(bits, 1)})
  {
    const u64 exp = lane & Common::DOUBLE_EXP;
    if (exp != 0 && exp != Common::DOUBLE_EXP)
      continue;
    const PsNeonBail why = exp == Common::DOUBLE_EXP         ? PsNeonBail::InInfNan :
                           (lane & Common::DOUBLE_FRAC) != 0 ? PsNeonBail::InSubnormal :
                                                               PsNeonBail::InZero;
    if (why > worst)
      worst = why;
  }
  return worst;
}

// Result-side counterpart: mirrors BothFiniteNormal + BothResultNiIndependent. Returns Tie if both
// lanes pass those (the only remaining result bail, FMA-only).
inline PsNeonBail ClassifyResultLanes(float64x2_t v)
{
  const uint64x2_t bits = vreinterpretq_u64_f64(v);
  PsNeonBail worst = PsNeonBail::Tie;
  for (const u64 lane : {vgetq_lane_u64(bits, 0), vgetq_lane_u64(bits, 1)})
  {
    const u64 magnitude = lane & (Common::DOUBLE_EXP | Common::DOUBLE_FRAC);
    PsNeonBail why;
    if ((lane & Common::DOUBLE_EXP) == Common::DOUBLE_EXP)
      why = PsNeonBail::OutInfNan;
    else if (magnitude == 0)
      why = PsNeonBail::OutZero;
    else if (magnitude < 0x3810000000000000ULL)
      why = PsNeonBail::OutBelowNi;
    else
      continue;
    if (worst == PsNeonBail::Tie || why > worst)
      worst = why;
  }
  return worst;
}

inline void PsNeonCountInputBail(PsNeonOp op, float64x2_t v0, float64x2_t v1)
{
  if (s_ps_neon_profile) [[unlikely]]
    PsNeonCountBail(op, ClassifyInputLanes(v1, ClassifyInputLanes(v0, PsNeonBail::InZero)));
}

inline void PsNeonCountResultBail(PsNeonOp op, float64x2_t vr)
{
  if (s_ps_neon_profile) [[unlikely]]
    PsNeonCountBail(op, ClassifyResultLanes(vr));
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
inline bool FmaSingle(PsNeonOp op, float64x2_t va, float64x2_t vc, float64x2_t vb, bool sub,
                      float64x2_t* out)
{
  if (!BothFiniteNormal(va) || !BothFiniteNormal(vc) || !BothFiniteNormal(vb))
  {
    if (s_ps_neon_profile) [[unlikely]]
    {
      PsNeonCountBail(op,
                      ClassifyInputLanes(
                          vb, ClassifyInputLanes(vc, ClassifyInputLanes(va, PsNeonBail::InZero))));
    }
    return false;
  }
  const float64x2_t vc25 = Force25BitNormal(vc);
  const float64x2_t b_signed = sub ? vnegq_f64(vb) : vb;
  // vfmaq_f64(acc, x, y) == x*y + acc, single-rounded — matches std::fma(a, c_round, b_sign).
  const float64x2_t vr = vfmaq_f64(b_signed, va, vc25);
  if (!BothFiniteNormal(vr) || !BothResultNiIndependent(vr) || EitherEvenTie(vr))
  {
    PsNeonCountResultBail(op, vr);
    return false;
  }
  PsNeonCountHit(op);
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
  if (PsNeonModeOk(ppc_state, PsNeonOp::Sub)) [[unlikely]]
  {
    const float64x2_t va = LoadPS(a);
    const float64x2_t vb = LoadPS(b);
    if (BothFiniteNormal(va) && BothFiniteNormal(vb))
    {
      const float64x2_t vr = vsubq_f64(va, vb);
      if (BothFiniteNormal(vr) && BothResultNiIndependent(vr))
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
        PsNeonCountHit(PsNeonOp::Sub);
        return;
      }
      PsNeonCountResultBail(PsNeonOp::Sub, vr);
    }
    else
    {
      PsNeonCountInputBail(PsNeonOp::Sub, va, vb);
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
  if (PsNeonModeOk(ppc_state, PsNeonOp::Add)) [[unlikely]]
  {
    const float64x2_t va = LoadPS(a);
    const float64x2_t vb = LoadPS(b);
    if (BothFiniteNormal(va) && BothFiniteNormal(vb))
    {
      const float64x2_t vr = vaddq_f64(va, vb);
      if (BothFiniteNormal(vr) && BothResultNiIndependent(vr))
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
        PsNeonCountHit(PsNeonOp::Add);
        return;
      }
      PsNeonCountResultBail(PsNeonOp::Add, vr);
    }
    else
    {
      PsNeonCountInputBail(PsNeonOp::Add, va, vb);
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
  if (PsNeonModeOk(ppc_state, PsNeonOp::Mul)) [[unlikely]]
  {
    const float64x2_t va = LoadPS(a);
    const float64x2_t vc = LoadPS(c);
    if (BothFiniteNormal(va) && BothFiniteNormal(vc))
    {
      const float64x2_t vc25 = Force25BitNormal(vc);
      const float64x2_t vr = vmulq_f64(va, vc25);
      if (BothFiniteNormal(vr) && BothResultNiIndependent(vr))
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
        PsNeonCountHit(PsNeonOp::Mul);
        return;
      }
      PsNeonCountResultBail(PsNeonOp::Mul, vr);
    }
    else
    {
      PsNeonCountInputBail(PsNeonOp::Mul, va, vc);
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
  if (PsNeonModeOk(ppc_state, PsNeonOp::Msub)) [[unlikely]]
  {
    float64x2_t vr;
    if (FmaSingle(PsNeonOp::Msub, LoadPS(a), LoadPS(c), LoadPS(b), true, &vr))
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
  if (PsNeonModeOk(ppc_state, PsNeonOp::Madd)) [[unlikely]]
  {
    float64x2_t vr;
    if (FmaSingle(PsNeonOp::Madd, LoadPS(a), LoadPS(c), LoadPS(b), false, &vr))
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
  if (PsNeonModeOk(ppc_state, PsNeonOp::Nmsub)) [[unlikely]]
  {
    float64x2_t vr;
    if (FmaSingle(PsNeonOp::Nmsub, LoadPS(a), LoadPS(c), LoadPS(b), true, &vr))
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
  if (PsNeonModeOk(ppc_state, PsNeonOp::Nmadd)) [[unlikely]]
  {
    float64x2_t vr;
    if (FmaSingle(PsNeonOp::Nmadd, LoadPS(a), LoadPS(c), LoadPS(b), false, &vr))
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
  if (PsNeonModeOk(ppc_state, PsNeonOp::Muls0)) [[unlikely]]
  {
    const float64x2_t va = LoadPS(a);
    const float64x2_t vc = Splat(c.PS0AsDouble());  // broadcast the PS0 multiplier into both lanes
    if (BothFiniteNormal(va) && BothFiniteNormal(vc))
    {
      const float64x2_t vc25 = Force25BitNormal(vc);
      const float64x2_t vr = vmulq_f64(va, vc25);
      if (BothFiniteNormal(vr) && BothResultNiIndependent(vr))
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
        PsNeonCountHit(PsNeonOp::Muls0);
        return;
      }
      PsNeonCountResultBail(PsNeonOp::Muls0, vr);
    }
    else
    {
      PsNeonCountInputBail(PsNeonOp::Muls0, va, vc);
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
  if (PsNeonModeOk(ppc_state, PsNeonOp::Muls1)) [[unlikely]]
  {
    const float64x2_t va = LoadPS(a);
    const float64x2_t vc = Splat(c.PS1AsDouble());  // broadcast the PS1 multiplier into both lanes
    if (BothFiniteNormal(va) && BothFiniteNormal(vc))
    {
      const float64x2_t vc25 = Force25BitNormal(vc);
      const float64x2_t vr = vmulq_f64(va, vc25);
      if (BothFiniteNormal(vr) && BothResultNiIndependent(vr))
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
        PsNeonCountHit(PsNeonOp::Muls1);
        return;
      }
      PsNeonCountResultBail(PsNeonOp::Muls1, vr);
    }
    else
    {
      PsNeonCountInputBail(PsNeonOp::Muls1, va, vc);
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
  if (PsNeonModeOk(ppc_state, PsNeonOp::Madds0)) [[unlikely]]
  {
    float64x2_t vr;
    if (FmaSingle(PsNeonOp::Madds0, LoadPS(a), Splat(c.PS0AsDouble()), LoadPS(b), false,
                  &vr))  // C broadcast from PS0
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
  if (PsNeonModeOk(ppc_state, PsNeonOp::Madds1)) [[unlikely]]
  {
    float64x2_t vr;
    if (FmaSingle(PsNeonOp::Madds1, LoadPS(a), Splat(c.PS1AsDouble()), LoadPS(b), false,
                  &vr))  // C broadcast from PS1
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
