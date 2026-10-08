// Host fuzz: NEON PsNeon fast path (helpers extracted verbatim from Interpreter_Paired.cpp by run.sh)
// vs the real scalar NI_* / Force25Bit / ForceSingle, bit for bit, both NI modes, both
// bFlushToZero values. Build and run through run.sh, not directly.
#include <cstdio>
#include <cstring>
#include <iterator>
#include <random>
#include "Core/PowerPC/Interpreter/Interpreter_FPUtils.h"
CPUInfo::CPUInfo() {}
CPUInfo cpu_info;
// Out-of-line in PowerPC.cpp; copied verbatim.
double PowerPC::PairedSingle::PS0AsDouble() const { return std::bit_cast<double>(ps0); }
double PowerPC::PairedSingle::PS1AsDouble() const { return std::bit_cast<double>(ps1); }
#include "psneon_extract.inc"

using PowerPC::PairedSingle;
static PowerPC::PowerPCState* st;
static u64 fails = 0, accepted = 0, accepted_zero = 0, tested = 0;

static bool HasZero(std::initializer_list<u64> v)
{
  for (u64 x : v)
    if ((x & ~Common::DOUBLE_SIGN) == 0)
      return true;
  return false;
}

enum Kind { ADD, SUB, MUL, MULS0, MULS1, MADD, MSUB, NMADD, NMSUB, MADDS0, MADDS1, NK };
static const char* kn[] = {"add","sub","mul","muls0","muls1","madd","msub","nmadd","nmsub","madds0","madds1"};

// Scalar reference, exactly as the op bodies compute it.
static void Scalar(Kind k, const PairedSingle& a, const PairedSingle& b, const PairedSingle& c, float* r)
{
  auto& s = *st;
  const double a0 = a.PS0AsDouble(), a1 = a.PS1AsDouble(), b0 = b.PS0AsDouble(), b1 = b.PS1AsDouble();
  const double c0 = c.PS0AsDouble(), c1 = c.PS1AsDouble();
  switch (k)
  {
  case ADD: r[0] = ForceSingle(s.fpscr, NI_add(s, a0, b0).value); r[1] = ForceSingle(s.fpscr, NI_add(s, a1, b1).value); break;
  case SUB: r[0] = ForceSingle(s.fpscr, NI_sub(s, a0, b0).value); r[1] = ForceSingle(s.fpscr, NI_sub(s, a1, b1).value); break;
  case MUL: r[0] = ForceSingle(s.fpscr, NI_mul(s, a0, Force25Bit(c0)).value); r[1] = ForceSingle(s.fpscr, NI_mul(s, a1, Force25Bit(c1)).value); break;
  case MULS0: r[0] = ForceSingle(s.fpscr, NI_mul(s, a0, Force25Bit(c0)).value); r[1] = ForceSingle(s.fpscr, NI_mul(s, a1, Force25Bit(c0)).value); break;
  case MULS1: r[0] = ForceSingle(s.fpscr, NI_mul(s, a0, Force25Bit(c1)).value); r[1] = ForceSingle(s.fpscr, NI_mul(s, a1, Force25Bit(c1)).value); break;
  case MADD: r[0] = ForceSingle(s.fpscr, NI_madd<true>(s, a0, c0, b0).value); r[1] = ForceSingle(s.fpscr, NI_madd<true>(s, a1, c1, b1).value); break;
  case MSUB: r[0] = ForceSingle(s.fpscr, NI_msub<true>(s, a0, c0, b0).value); r[1] = ForceSingle(s.fpscr, NI_msub<true>(s, a1, c1, b1).value); break;
  case NMADD: case NMSUB:
  {
    for (int i = 0; i < 2; ++i)
    {
      const double aa = i ? a1 : a0, bb = i ? b1 : b0, cc = i ? c1 : c0;
      const float t = ForceSingle(s.fpscr, (k == NMADD ? NI_madd<true>(s, aa, cc, bb) : NI_msub<true>(s, aa, cc, bb)).value);
      r[i] = std::isnan(t) ? t : -t;
    }
    break;
  }
  case MADDS0: r[0] = ForceSingle(s.fpscr, NI_madd<true>(s, a0, c0, b0).value); r[1] = ForceSingle(s.fpscr, NI_madd<true>(s, a1, c0, b1).value); break;
  case MADDS1: r[0] = ForceSingle(s.fpscr, NI_madd<true>(s, a0, c1, b0).value); r[1] = ForceSingle(s.fpscr, NI_madd<true>(s, a1, c1, b1).value); break;
  default: break;
  }
}

// NEON path, exactly as the op bodies do it. Returns false on bail.
static bool Neon(Kind k, const PairedSingle& a, const PairedSingle& b, const PairedSingle& c, float* r)
{
  float64x2_t vr;
  const float64x2_t va = LoadPS(a);
  switch (k)
  {
  case ADD: case SUB:
  {
    const float64x2_t vb = LoadPS(b);
    if (!BothInputsOk(va) || !BothInputsOk(vb)) return false;
    vr = k == ADD ? vaddq_f64(va, vb) : vsubq_f64(va, vb);
    if (!BothResultsOk(vr)) return false;
    break;
  }
  case MUL: case MULS0: case MULS1:
  {
    const float64x2_t vc = k == MUL ? LoadPS(c) : Splat(k == MULS0 ? c.PS0AsDouble() : c.PS1AsDouble());
    if (!BothInputsOk(va) || !BothInputsOk(vc)) return false;
    vr = vmulq_f64(va, Force25BitNormal(vc));
    if (!BothResultsOk(vr)) return false;
    break;
  }
  default:
  {
    const bool sub = k == MSUB || k == NMSUB;
    const float64x2_t vc = (k == MADDS0) ? Splat(c.PS0AsDouble()) : (k == MADDS1) ? Splat(c.PS1AsDouble()) : LoadPS(c);
    const PsNeonOp op = PsNeonOp::Madd;
    if (!FmaSingle(op, va, vc, LoadPS(b), sub, &vr)) return false;
  }
  }
  StoreLanes(vr, &r[0], &r[1]);
  if (k == NMADD || k == NMSUB) { r[0] = -r[0]; r[1] = -r[1]; }
  return true;
}

static std::mt19937_64 rng(12345);
static u64 RandVal()
{
  const u64 pick = rng() % 16;
  const u64 sign = (rng() & 1) ? Common::DOUBLE_SIGN : 0;
  switch (pick)
  {
  case 0: case 1: case 2: return sign;  // +/-0
  case 3: return std::bit_cast<u64>(static_cast<double>(static_cast<float>((rng() % 9) - 4))); // small ints
  case 4: { float f; u32 x = static_cast<u32>(rng()); std::memcpy(&f, &x, 4); return std::bit_cast<u64>(static_cast<double>(f)); } // any single incl. inf/nan/subnormal
  case 5: return sign | (rng() & Common::DOUBLE_FRAC);  // double subnormal
  case 6: return sign | 0x3810000000000000ULL | (rng() & 0xFFFFFULL);  // near smallest normal single
  case 7: return sign | (0x3800000000000000ULL + (rng() % 0x20000000000000ULL)); // straddles single-subnormal range
  case 8: return rng(); // any double
  default:
  {
    const float f = static_cast<float>(std::ldexp(static_cast<double>(rng() % 100000) / 1000.0, static_cast<int>(rng() % 40) - 20));
    return std::bit_cast<u64>(static_cast<double>((rng() & 1) ? -f : f));
  }
  }
}

int main()
{
  st = static_cast<PowerPC::PowerPCState*>(std::calloc(1, sizeof(PowerPC::PowerPCState)));
  s_ps_neon_enabled = true;
  const u64 N = 4000000;
  for (int ftz = 0; ftz < 2; ++ftz)
    for (int ni = 0; ni < 2; ++ni)
    {
      cpu_info.bFlushToZero = ftz;
      for (u64 n = 0; n < N; ++n)
      {
        PairedSingle a, b, c;
        a.SetBoth(RandVal(), RandVal()); b.SetBoth(RandVal(), RandVal()); c.SetBoth(RandVal(), RandVal());
        // Force cancellations / exact zero results some of the time.
        switch (rng() % 6)
        {
        case 0: b = a; break;                                   // a - a, a + a
        case 1: b.SetBoth(a.PS0AsU64() ^ Common::DOUBLE_SIGN, a.PS1AsU64() ^ Common::DOUBLE_SIGN); break;  // a + (-a)
        case 2:  // b = -(a * c_round) exactly-ish for fma cancellation
          b.SetBoth(std::bit_cast<u64>(-(a.PS0AsDouble() * Force25Bit(c.PS0AsDouble()))), std::bit_cast<u64>(-(a.PS1AsDouble() * Force25Bit(c.PS1AsDouble()))));
          break;
        default: break;
        }
        const Kind k = static_cast<Kind>(n % NK);
        std::memset(&st->fpscr, 0, sizeof(st->fpscr));
        st->fpscr.NI = ni;
        float nr[2];
        ++tested;
        if (!Neon(k, a, b, c, nr)) continue;
        ++accepted;
        const bool z = HasZero({a.PS0AsU64(), a.PS1AsU64(), b.PS0AsU64(), b.PS1AsU64(), c.PS0AsU64(), c.PS1AsU64()});
        accepted_zero += z;
        const u32 before = st->fpscr.Hex;
        float sr[2];
        Scalar(k, a, b, c, sr);
        const bool same = std::bit_cast<u32>(nr[0]) == std::bit_cast<u32>(sr[0]) && std::bit_cast<u32>(nr[1]) == std::bit_cast<u32>(sr[1]) && st->fpscr.Hex == before;
        if (!same && fails++ < 20)
          std::printf("MISMATCH %s ni=%d ftz=%d a=%016llx/%016llx b=%016llx/%016llx c=%016llx/%016llx neon=%08x/%08x scalar=%08x/%08x fpscr %08x->%08x\n", kn[k], ni, ftz,
                      (unsigned long long)a.PS0AsU64(), (unsigned long long)a.PS1AsU64(), (unsigned long long)b.PS0AsU64(), (unsigned long long)b.PS1AsU64(),
                      (unsigned long long)c.PS0AsU64(), (unsigned long long)c.PS1AsU64(), std::bit_cast<u32>(nr[0]), std::bit_cast<u32>(nr[1]), std::bit_cast<u32>(sr[0]), std::bit_cast<u32>(sr[1]), before, st->fpscr.Hex);
      }
    }
  std::printf("tested=%llu accepted=%llu accepted_with_zero_input=%llu mismatches=%llu\n", (unsigned long long)tested, (unsigned long long)accepted, (unsigned long long)accepted_zero, (unsigned long long)fails);
  return fails != 0;
}
