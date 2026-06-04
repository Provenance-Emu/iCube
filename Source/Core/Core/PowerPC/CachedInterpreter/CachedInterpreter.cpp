// Copyright 2014 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Core/PowerPC/CachedInterpreter/CachedInterpreter.h"

#include <algorithm>
#include <array>
#include <bit>
#include <cstdio>
#include <cstring>
#include <span>
#include <sstream>
#include <utility>
#include <vector>

#include <fmt/format.h>
#include <fmt/ostream.h>

#include "Common/Assert.h"
#include "Common/CommonTypes.h"
#include "Common/GekkoDisassembler.h"
#include "Common/Config/Config.h"
#include "Common/Logging/Log.h"
#include "Common/Swap.h"
#include "Core/Config/MainSettings.h"
#include "Core/ConfigManager.h"
#include "Core/Core.h"
#include "Core/CoreTiming.h"
#include "Core/HLE/HLE.h"
#include "Core/HW/CPU.h"
#include "Core/HW/Memmap.h"
#include "Core/Host.h"
#include "Core/PowerPC/Gekko.h"
#include "Core/PowerPC/Interpreter/Interpreter.h"
#include "Core/PowerPC/Jit64Common/Jit64Constants.h"
#include "Core/PowerPC/PPCAnalyst.h"
#include "Core/PowerPC/PowerPC.h"
#include "Core/System.h"

CachedInterpreter::CachedInterpreter(Core::System& system) : JitBase(system), m_block_cache(*this)
{
}

CachedInterpreter::~CachedInterpreter() = default;

// iCube WIN#1: PIC (position-independent-code) direct-pointer load/store region resolution. Resolves
// an effective address to a host RAM base pointer + offset, bypassing the per-access MMU/region
// lookup. Integer single-access D-form/X-form only; FP and anything not resolvable here falls back to
// the generic interpreter handler (see Cold_LoadStoreFallback). Ported verbatim from the
// feature/icube-testflight good branch.
namespace
{
struct CI_RegionInfo
{
  u8* base;
  u32 mask;
  u32 sub;
  bool is_fake;
};

static inline CI_RegionInfo CI_GetRegionInfo(u32 ea, bool dr, u8* mem1_base, u32 mem1_mask,
                                             u8* exram_base, u32 exram_mask, u8* fakevmem_base,
                                             u32 fakevmem_mask)
{
  CI_RegionInfo info{nullptr, 0, 0, false};
  if (ea >= Memory::MEM1_BASE_ADDR && ea - Memory::MEM1_BASE_ADDR <= mem1_mask)
  {
    info.base = mem1_base;
    info.mask = mem1_mask;
    info.sub = Memory::MEM1_BASE_ADDR;
    return info;
  }
  if (ea >= Memory::MEM2_BASE_ADDR && ea - Memory::MEM2_BASE_ADDR <= exram_mask)
  {
    info.base = exram_base;
    info.mask = exram_mask;
    info.sub = Memory::MEM2_BASE_ADDR;
    return info;
  }
  if (fakevmem_base && ((ea & 0xFE000000u) == 0x7E000000u))
  {
    info.base = fakevmem_base;
    info.mask = fakevmem_mask;
    info.sub = 0;
    info.is_fake = true;
    return info;
  }
  if (!dr && ea >= 0xC0000000u && ea - 0xC0000000u <= mem1_mask)
  {
    info.base = mem1_base;
    info.mask = mem1_mask;
    info.sub = 0xC0000000u;
    return info;
  }
  if (!dr && ea >= 0xD0000000u && ea - 0xD0000000u <= exram_mask)
  {
    info.base = exram_base;
    info.mask = exram_mask;
    info.sub = 0xD0000000u;
    return info;
  }
  return info;
}

static inline u32 CI_RegionOffset(const CI_RegionInfo& r, u32 ea)
{
  return r.is_fake ? (ea & r.mask) : ((ea - r.sub) & r.mask);
}

// iCube WIN#2: CR0/XER side-effect helpers for the micro-op handlers. Byte-exact mirrors of the
// rebaseline interpreter's Interpreter::Helper_UpdateCR0 / Helper_IntCompare SO behavior /
// Helper_Carry / Helper_HasAddOverflowed — ported verbatim from the good branch so a fused op's
// CR/XER write is indistinguishable from the generic interpreter op it replaces. CRITICAL: do not
// paraphrase; these reproduce the exact SO/GT-on-zero and carry-chain semantics.
static inline void CI_UpdateCR0(PowerPC::PowerPCState& ppc_state, u32 value)
{
  const s64 sign_extended = s64{s32(value)};
  u64 cr_val = u64(sign_extended);

  if (value == 0)
  {
    // Preserve GT semantics when setting SO on zero -> non-zero transition.
    cr_val |= 1ULL << 63;
  }

  cr_val = (cr_val & ~(1ULL << PowerPC::CR_EMU_SO_BIT)) |
           (u64{ppc_state.GetXER_SO()} << PowerPC::CR_EMU_SO_BIT);

  ppc_state.cr.fields[0] = cr_val;
}

// Write a CR field (CRFD), mirroring Helper_IntCompare SO behavior.
static inline void CI_WriteCRField(PowerPC::PowerPCState& ppc_state, u32 crfd, u32 cr_field)
{
  if (ppc_state.GetXER_SO())
    cr_field |= PowerPC::CR_SO;
  ppc_state.cr.SetField(crfd, cr_field);
}

// Carry/overflow helpers matching Interpreter semantics.
static inline bool CI_Helper_Carry(u32 value1, u32 value2)
{
  return value2 > (~value1);
}

static inline bool CI_HasAddOverflowed(u32 x, u32 y, u32 result)
{
  // If x and y have the same sign, but the result is different then an overflow has occurred.
  return (((x ^ result) & (y ^ result)) >> 31) != 0;
}
}  // anonymous namespace

// iCube WIN#1: route integer D-form/X-form load/stores through the PIC direct-pointer fast path
// (MAIN_CIR_PIC_LOADSTORE). Read once in Init. The !jo.memcheck and !FL_USE_FPU gates are ALWAYS
// enforced at the emission site regardless of this flag; the flag only opts the fast path in/out for
// on-device A/B. Default ON (see MainSettings.cpp). UNVALIDATED on-device — needs bit-exact dual-run.
static bool s_pic_loadstore = false;

// iCube WIN#3: the per-block PowerPC performance-monitor (PMC) update is now gated at the call
// sites on PowerPC::PerformanceMonitorActive(ppc_state) (MMCR0/MMCR1 non-zero). This replaces the
// old default-off MAIN_CIR_SKIP_PERF_MONITOR skip flag: it skips the update for the common case
// (game never configured the PMC) while staying bit-accurate for titles that do, so no opt-in flag
// is needed. The MAIN_CIR_SKIP_PERF_MONITOR config entry is left defined (harmless, now unread).

// iCube: when true, the emission site routes whitelisted hot integer-ALU ops to a specialized,
// directly-dispatched callback (see InterpretSpecialized) instead of the generic Interpret
// trampoline. Read once in Init (cheap per-op bool check at compile time). Default OFF.
static bool s_specialized_ops = false;
// iCube: when true, each specialized callback re-derives and asserts the dispatch bookkeeping
// against the generic Interpret<write_pc> contract before committing the real handler.
static bool s_specialized_ops_validate = false;

// iCube: software-prefetch hints (MAIN_CACHED_INTERPRETER_PREFETCH). When OFF (the default on this
// Apple-only fork) NO __builtin_prefetch is ever emitted, so the CIR hot loop and the PIC load/store
// path are byte-for-byte identical to the current no-hints state. INVERTED DEFAULT vs the upstream
// fork: the iFly fork measured "remove prefetch on Apple Silicon = +33%" — the manual hints fight the
// Apple Silicon hardware prefetcher, so the fast state is NO hints. This flag exists only so the hints
// can be re-added on-device for A/B confirmation (flip ON => hints emitted => expected SLOWER on Apple).
// Read once in Init.
static bool s_prefetch_enabled = false;

// iCube WIN#2: when true, DoJit fuses runs of pure-register integer/immediate ops into a single
// ExecuteMicroOps callback and folds the addis/ori CONST32 idiom. Read once in Init. Default OFF: with
// the flag off NO ExecuteMicroOps callback is ever emitted and the DoJit fusion block is skipped
// entirely, so the callback stream is byte-identical to upstream. RISKIEST CIR win — UNVALIDATED.
static bool s_microop_fusion = false;

// iCube WIN#2 validate: when true, the fusion packer emits an ExecuteMicroOpsValidate callback (which
// carries the ORIGINAL consumed instructions too) instead of the lean ExecuteMicroOps. At run time the
// validate callback first runs the real generic Interpreter:: handlers on the live state, snapshots the
// architectural result, restores, runs the fused MicroOp dispatch, and asserts the two match. Read once
// in Init at codegen time. Default OFF. See ExecuteMicroOpsValidate / MAIN_CIR_MICROOP_FUSION_VALIDATE.
static bool s_microop_fusion_validate = false;

// iCube: when true, blocks ending at a STATIC direct branch emit a LinkBlock trampoline (instead of
// EndBlock) and jo.enableBlocklink is turned on so the upstream JitBaseBlockCache machinery records
// links and patches/unpatches them through CachedInterpreterBlockCache::WriteLinkBlock. Read once in
// Init. Default OFF (plain EndBlock, identical to stock 2509). See LinkBlock / WriteLinkBlock.
static bool s_block_linking = false;
// iCube: when true, LinkBlock re-resolves the dispatcher's would-be next block and asserts the
// patched link is non-stale, points at the right block, and that feature_flags + downcount agree
// before following it. Slow (map lookup per linked exit); correctness passes only. Default OFF.
static bool s_block_linking_validate = false;
// iCube: singleton instance pointer used ONLY by LinkBlock's validate path (a static callback has no
// `this`, but needs the block cache to re-resolve the dispatcher target). Set in Init while validate
// is on; never dereferenced on the fast path. The CIR is one-per-System, so this is unambiguous.
static CachedInterpreter* s_validate_instance = nullptr;

// iCube: whitelist of hot ops eligible for specialized dispatch. Defined once as X-macros so the
// emission site, the ExecuteOneBlock dispatch switch, the op-id enum, and the eligibility check all
// stay in lockstep — adding an op is a single line in the right list.
//
// The list is split by VALIDATE REGIME (Tier-1 ALU vs Tier-3 load/store), because the two need
// different correctness checks (see InterpretSpecialized): ALU is safe to double-run, load/stores
// are NOT (a store would double-write memory, a load would double-read MMIO). Both lists feed every
// derived construct (enum, emit, dispatch, IsSpecializedOp) through CIR_SPECIALIZED_OP_LIST below, so
// the X-macro stays the single source of truth regardless of regime.
//
// CIR_SPECIALIZED_ALU_OPS — Tier-1 pure-register integer ALU. Membership (ALL must hold; verified
// against the 2509 Interpreter_Integer.cpp bodies):
//   - NOT FL_LOADSTORE and NOT FL_USE_FPU => emission always routes via Interpret<write_pc> (never
//     InterpretAndCheckExceptions), never via CheckFPU.
//   - Side effects confined to the register file (GPR/CR/XER); never raises an exception, never
//     touches the MMU, never sets m_end_block, never calls CheckExceptions. => safe to double-run.
#define CIR_SPECIALIZED_ALU_OPS(X)                                                                 \
  X(addi)    /* D-form: gpr[RD] = (RA?gpr[RA]:0) + SIMM_16; pure GPR write */                       \
  X(addis)   /* D-form: gpr[RD] = (RA?gpr[RA]:0) + (SIMM_16<<16); pure GPR write */                 \
  X(ori)     /* D-form: gpr[RA] = gpr[RS] | UIMM; pure GPR write */                                 \
  X(oris)    /* D-form: gpr[RA] = gpr[RS] | (UIMM<<16); pure GPR write */                           \
  X(orx)     /* X-form: gpr[RA] = gpr[RS] | gpr[RB]; +CR0 if Rc; no XER, no exceptions */           \
  X(rlwinmx) /* M-form: gpr[RA] = rotl(gpr[RS],SH) & mask; +CR0 if Rc; no XER, no exceptions */ \
  X(addx)    /* X-form: gpr[RD] = gpr[RA] + gpr[RB]; +CR0 if Rc, +XER_OV if OE; no exceptions */ \
  X(subfx)   /* X-form: gpr[RD] = ~gpr[RA] + gpr[RB] + 1; +CR0 if Rc, +XER_OV if OE */ \
  X(andx)    /* X-form: gpr[RA] = gpr[RS] & gpr[RB]; +CR0 if Rc; no XER, no exceptions */ \
  X(andi_rc) /* D-form: gpr[RA] = gpr[RS] & UIMM; always +CR0; no XER, no exceptions */ \
  X(xorx)    /* X-form: gpr[RA] = gpr[RS] ^ gpr[RB]; +CR0 if Rc; no XER, no exceptions */ \
  X(slwx)    /* X-form: gpr[RA] = gpr[RS] << (gpr[RB]&0x3f); +CR0 if Rc; no exceptions */ \
  X(srwx)    /* X-form: gpr[RA] = gpr[RS] >> (gpr[RB]&0x3f); +CR0 if Rc; no exceptions */ \
  X(cmp)     /* X-form: CR[CRFD] = cmp(s32 RA, s32 RB); CR-only, reads XER_SO; no GPR write */ \
  X(rlwimix) /* M-form: gpr[RA] = (gpr[RA]&~m)|(rotl(RS,SH)&m); +CR0 if Rc; no exceptions */

// CIR_SPECIALIZED_LS_OPS — Tier-3 D-form integer load/store. Membership (ALL must hold; verified
// against PPCTables.cpp + Interpreter_LoadStore.cpp):
//   - FL_LOADSTORE, NOT FL_USE_FPU, NOT FL_FLOAT_*, primary-opcode D-form (canEndBlock == false, so
//     write_pc is ALWAYS false for these).
//   - Eligible ONLY because jo.memcheck is OFF on the App-Store jitless config: with memcheck off the
//     DoJit guard `(jo.memcheck && FL_LOADSTORE)` is false and ShouldHandleFPExceptionForInstruction
//     is false (integer LS), so the GENERIC path ALSO routes them through the plain Interpret<false>
//     trampoline — NOT InterpretAndCheckExceptions. Specialized-vs-generic is therefore identical BY
//     CONSTRUCTION (same GetInterpreterOp handler, same trampoline contract): a DSI raised inside the
//     MMU access sits in ppc_state.Exceptions identically either way, since neither path calls
//     CheckExceptions (it is serviced at the next block boundary). NOT safe to double-run (stores
//     write memory, loads can read MMIO) => single-run validation only. Excludes lmw/stmw (System,
//     11 cycles), string ops, lwarx/stwcx (reservation), eciwx/ecowx, and all FP load/stores.
#define CIR_SPECIALIZED_LS_OPS(X)                                                                  \
  X(lwz)  /* D-form: gpr[RD] = Read_U32(EA); RA-base */                                            \
  X(lwzu) /* D-form update: gpr[RD] = Read_U32(EA_U); gpr[RA] = EA on no-DSI */                    \
  X(lhz)  /* D-form: gpr[RD] = Read_U16(EA) */                                                     \
  X(lhzu) /* D-form update: gpr[RD] = Read_U16(EA_U); gpr[RA] = EA on no-DSI */                    \
  X(lha)  /* D-form: gpr[RD] = sext16(Read_U16(EA)) */                                             \
  X(lhau) /* D-form update: gpr[RD] = sext16(Read_U16(EA_U)); gpr[RA] = EA on no-DSI */            \
  X(lbz)  /* D-form: gpr[RD] = Read_U8(EA) */                                                      \
  X(lbzu) /* D-form update: gpr[RD] = Read_U8(EA_U); gpr[RA] = EA on no-DSI */                     \
  X(stw)  /* D-form: Write_U32(gpr[RS], EA) */                                                     \
  X(stwu) /* D-form update: Write_U32(gpr[RS], EA_U); gpr[RA] = EA on no-DSI */                    \
  X(sth)  /* D-form: Write_U16(gpr[RS], EA) */                                                     \
  X(sthu) /* D-form update: Write_U16(gpr[RS], EA_U); gpr[RA] = EA on no-DSI */                    \
  X(stb)  /* D-form: Write_U8(gpr[RS], EA) */                                                      \
  X(stbu) /* D-form update: Write_U8(gpr[RS], EA_U); gpr[RA] = EA on no-DSI */

// Combined list driving the op-id enum, the emit site, the dispatch switch, and IsSpecializedOp.
// ALU entries first so their enum ids stay stable across LS additions.
#define CIR_SPECIALIZED_OP_LIST(X)                                                                 \
  CIR_SPECIALIZED_ALU_OPS(X)                                                                       \
  CIR_SPECIALIZED_LS_OPS(X)

// iCube: compact op-id stored in the specialized-only operand payload (SpecializedInterpretOperands)
// so ExecuteOneBlock can dispatch via a switch/jump-table keyed on the id instead of a linear chain
// of callback-pointer compares. The enum is X-macro-generated from the same combined list, so it can
// never drift from the emit/dispatch sites. CIR_SPEC_OP_COUNT bounds the table.
enum class CirSpecOp : u16
{
#define CIR_ENUM(name) name,
  CIR_SPECIALIZED_OP_LIST(CIR_ENUM)
#undef CIR_ENUM
      CIR_SPEC_OP_COUNT
};

// True if this opcode's chosen interpreter handler is on the specialized whitelist.
static bool IsSpecializedOp(Interpreter::Instruction func)
{
#define CIR_CHECK(name)                                                                            \
  if (func == &Interpreter::name)                                                                  \
    return true;
  CIR_SPECIALIZED_OP_LIST(CIR_CHECK)
#undef CIR_CHECK
  return false;
}

// Map a whitelisted handler pointer to its compact op-id (emit-time only; not on the hot path).
static CirSpecOp SpecOpId(Interpreter::Instruction func)
{
#define CIR_ID(name)                                                                               \
  if (func == &Interpreter::name)                                                                  \
    return CirSpecOp::name;
  CIR_SPECIALIZED_OP_LIST(CIR_ID)
#undef CIR_ID
  return CirSpecOp::CIR_SPEC_OP_COUNT;  // unreachable: callers gate on IsSpecializedOp first
}

// iCube: hot-block profiler (MAIN_CIR_PROFILE, default OFF). Read once in Init. When false the
// once-per-block hook in EndBlock/LinkBlock is a single predicted-not-taken bool test and the
// per-INSTRUCTION dispatch in ExecuteOneBlock is byte-for-byte untouched.
static bool s_cir_profile = false;

namespace
{
// Flycast/PPSSPP-style fixed open-addressing hot-block table. Sized once at first use for a game's
// working set (a few thousand blocks; we reserve 16384 slots, a power of two for mask-indexing).
// NEVER rehashes/reallocates, so the CPU thread writing and the report thread reading can coexist
// lock-free without UB (a torn read of a u64 counter is harmless for a perf report). Keyed by block
// ENTRY guest PC. O(1) amortized insert: a linear probe in a slot array that is never resized.
struct CIRBlockProfile
{
  static constexpr u32 kSlots = 1u << 14;  // 16384
  static constexpr u32 kMask = kSlots - 1;
  static constexpr u32 kEmpty = 0xFFFFFFFFu;  // sentinel; guest PC 0xFFFFFFFF is not a real entry

  struct Slot
  {
    u32 pc;            // entry guest PC, or kEmpty
    u32 _pad;
    u64 run_count;
    u64 total_cycles;
  };

  std::vector<Slot> slots;
  u64 grand_total_cycles = 0;
  u64 grand_total_runs = 0;

  void EnsureAllocated()
  {
    if (slots.empty())
      slots.assign(kSlots, Slot{kEmpty, 0, 0, 0});
  }

  // Per-block O(1) record. Called at most once per block execution from the terminal callback,
  // guarded by s_cir_profile, on the CPU emulation thread only.
  void Record(u32 entry_pc, u32 cycles)
  {
    EnsureAllocated();
    u32 idx = (entry_pc * 2654435761u) & kMask;  // Knuth multiplicative hash
    // Linear probe. The table is pre-sized far above a typical working set, so probes stay short;
    // if the table is pathologically full we just charge the grand totals and skip the per-block
    // slot (the report degrades gracefully rather than spinning or reallocating).
    for (u32 i = 0; i <= kMask; ++i)
    {
      Slot& s = slots[idx];
      if (s.pc == entry_pc)
      {
        s.run_count += 1;
        s.total_cycles += cycles;
        break;
      }
      if (s.pc == kEmpty)
      {
        s.pc = entry_pc;
        s.run_count = 1;
        s.total_cycles = cycles;
        break;
      }
      idx = (idx + 1) & kMask;
    }
    grand_total_cycles += cycles;
    grand_total_runs += 1;
  }

  void Clear()
  {
    if (!slots.empty())
      std::fill(slots.begin(), slots.end(), Slot{kEmpty, 0, 0, 0});
    grand_total_cycles = 0;
    grand_total_runs = 0;
  }
};

// File-static instance. Default-constructed empty; only allocated when profiling actually records.
CIRBlockProfile s_block_profile;
}  // namespace

namespace CIRProfiler
{
void Reset()
{
  s_block_profile.Clear();
}

std::string BuildHotBlocksReport(u32 top_n)
{
  if (!s_cir_profile)
    return "(CIR profiler off — set Main.Core.CIRProfile=true / icube.cirProfile and reboot game)\n";

  // Snapshot non-empty slots. The table never reallocates, so this read is safe even while the CPU
  // thread keeps writing; we tolerate a slightly inconsistent instant (a perf report, not ledger).
  struct Entry
  {
    u32 pc;
    u64 runs;
    u64 cycles;
  };
  std::vector<Entry> entries;
  const u64 grand_cycles = s_block_profile.grand_total_cycles;
  if (s_block_profile.slots.empty() || grand_cycles == 0)
    return "(CIR profiler on, no blocks recorded yet)\n";

  entries.reserve(1024);
  for (const auto& s : s_block_profile.slots)
  {
    if (s.pc != CIRBlockProfile::kEmpty && s.run_count != 0)
      entries.push_back({s.pc, s.run_count, s.total_cycles});
  }
  if (entries.empty())
    return "(CIR profiler on, no blocks recorded yet)\n";

  std::sort(entries.begin(), entries.end(),
            [](const Entry& a, const Entry& b) { return a.cycles > b.cycles; });

  const u32 n = std::min<u32>(top_n, static_cast<u32>(entries.size()));
  std::ostringstream out;
  out << "  unique_blocks=" << entries.size() << " total_block_runs="
      << s_block_profile.grand_total_runs << " total_cycles=" << grand_cycles << "\n";
  out << "  rank  entry_pc    runs         cycles        cyc/run   %cyc  hint\n";
  for (u32 i = 0; i < n; ++i)
  {
    const Entry& e = entries[i];
    const double pct = 100.0 * static_cast<double>(e.cycles) / static_cast<double>(grand_cycles);
    const double cyc_per_run =
        e.runs ? static_cast<double>(e.cycles) / static_cast<double>(e.runs) : 0.0;
    // Spin/idle-loop hint the idle detector may have missed: a block that runs a huge number of
    // times for a tiny per-run cycle cost is almost certainly a wait/poll loop. Thresholds are
    // heuristic (Flycast-style): >=50k runs AND <=8 cycles/run.
    const char* hint = (e.runs >= 50000 && cyc_per_run <= 8.0) ? "SPIN?" : "";
    char line[160];
    snprintf(line, sizeof(line), "  %4u  0x%08x  %10llu  %12llu  %8.2f  %5.1f  %s\n", i + 1, e.pc,
             static_cast<unsigned long long>(e.runs),
             static_cast<unsigned long long>(e.cycles), cyc_per_run, pct, hint);
    out << line;
  }
  return std::move(out).str();
}
}  // namespace CIRProfiler

void CachedInterpreter::Init()
{
  // Wire the fastmem arena BEFORE RefreshConfig() — RefreshConfig computes jo.fastmem from
  // jo.fastmem_arena, and Jit64/JitArm64::Init both call InitFastmemArena() first for exactly this
  // reason. Without it, jo.fastmem_arena stays false -> jo.fastmem is always false -> the PIC
  // direct-pointer load/store fast path (gated on jo.fastmem at the DoJit emission site) NEVER
  // emits, silently leaving the CIR as the bare stock interpreter (the PIC win was inert). The
  // ~16GiB arena is covered by the app's extended-virtual-addressing + increased-memory-limit
  // entitlements; if reservation fails on a device, jo.fastmem_arena stays false and PIC gracefully
  // no-ops. PIC region-checks every access and falls back to the generic handler, so it never
  // faults — the CIR needs no backpatch fault handler (unlike the JITs).
  InitFastmemArena();
  RefreshConfig();
  s_pic_loadstore = Config::Get(Config::MAIN_CIR_PIC_LOADSTORE);
  s_specialized_ops = Config::Get(Config::MAIN_CIR_SPECIALIZED_OPS);
  s_specialized_ops_validate = Config::Get(Config::MAIN_CIR_SPECIALIZED_OPS_VALIDATE);
  s_microop_fusion = Config::Get(Config::MAIN_CIR_MICROOP_FUSION);
  s_microop_fusion_validate = Config::Get(Config::MAIN_CIR_MICROOP_FUSION_VALIDATE);
  s_block_linking = Config::Get(Config::MAIN_CIR_BLOCK_LINKING);
  s_block_linking_validate = Config::Get(Config::MAIN_CIR_BLOCK_LINKING_VALIDATE);
  s_validate_instance = s_block_linking_validate ? this : nullptr;
  // iCube: default false (no hints; the fast state). Flip ON only to A/B the +33%-by-removal finding.
  s_prefetch_enabled = Config::Get(Config::MAIN_CACHED_INTERPRETER_PREFETCH);
  // iCube: hot-block profiler (default OFF). Read once; clear counters so each game boot starts fresh.
  // When ON, allocate the slot table HERE (before emulation starts, before any cross-thread report
  // read can fire) rather than lazily on the first Record() on the CPU thread — closes the (tiny)
  // race window between the first-block allocation and a Copy-State reader.
  s_cir_profile = Config::Get(Config::MAIN_CIR_PROFILE);
  s_block_profile.Clear();
  if (s_cir_profile)
    s_block_profile.EnsureAllocated();

  AllocCodeSpace(CODE_SIZE);
  ResetFreeMemoryRanges();

  // iCube: drive upstream link bookkeeping from the flag. When OFF this stays false and the CIR is
  // byte-for-byte the stock 2509 path (no LinkBlock trampolines emitted, FinalizeBlock(block_link=
  // false) records no links). When ON, FinalizeBlock populates links_to/linkData and calls LinkBlock/
  // UnlinkBlock; DestroyBlock unlinks on every block-freeing path (Clear/ErasePhysicalRange/
  // EraseSingleBlock all funnel through it), so a stale rel can never survive a block destruction.
  jo.enableBlocklink = s_block_linking;

  m_block_cache.Init();

  code_block.m_stats = &js.st;
  code_block.m_gpa = &js.gpa;
  code_block.m_fpa = &js.fpa;
}

void CachedInterpreter::Shutdown()
{
  m_block_cache.Shutdown();
}

// iCube: the single source of dispatch for specialized ops. Given an already-decoded CirSpecOp `id`,
// the live `ppc_state`, and a SpecializedInterpretOperands `ops`, runs the same per-op handler the
// generic path would have run — but by its compile-time-constant pointer Interpreter::name(...), so
// the call is DIRECT and inlinable (ZERO indirect calls, exactly the property of the prior per-op
// compare-chain). The `switch` lowers to a jump-table: one indirect *branch* (not an indirect call),
// replacing the old chain's 2*N pointer compares. The caller does the write_pc pc/npc writes and the
// return-distance/advancement, so this macro is identical whether invoked inline in ExecuteOneBlock
// or inside the InterpretSpecialized callback — they can never diverge.
#define CIR_SPEC_CASE(name)                                                                        \
  case CirSpecOp::name:                                                                            \
    Interpreter::name(cir_spec_ops.interpreter, cir_spec_ops.inst);                                \
    break;
#define CIR_SPEC_SWITCH(id_expr, ops_expr)                                                         \
  do                                                                                               \
  {                                                                                                \
    const SpecializedInterpretOperands& cir_spec_ops = (ops_expr);                                 \
    switch (id_expr)                                                                                \
    {                                                                                              \
      CIR_SPECIALIZED_OP_LIST(CIR_SPEC_CASE)                                                        \
    default:                                                                                       \
      break;                                                                                       \
    }                                                                                              \
  } while (0)

// iCube: block-linking safety guard. Caps consecutive linked hops per dispatcher entry so an opt-in
// linked chain can never spin unbounded between CoreTiming::Advance() round-trips (the wake-race at a
// high emulated clock). 256 is well above any real static-branch chain length, so the common case
// never trips it; it only bounds the pathological case. Reset point is implicit: linked_hops is a
// local in ExecuteOneBlock, which IS the dispatcher entry, so it is zeroed on every (re-)entry.
static constexpr u32 CIR_MAX_LINKED_HOPS = 256;

void CachedInterpreter::ExecuteOneBlock(const CPU::State* state_ptr)
{
  const u8* normal_entry = m_block_cache.Dispatch();
  if (!normal_entry)
  {
    Jit(m_ppc_state.pc);
    return;
  }

  auto& ppc_state = m_ppc_state;
  // iCube: block-linking safety guard — consecutive-linked-hop counter, reset on each dispatcher entry
  // (this function). Only ever touched on the LinkBlock-followed branch below, so it is a no-op when
  // block linking is off (no LinkBlock callbacks are emitted, so that branch never executes).
  u32 linked_hops = 0;
  // iCube: optional register-file prefetch hints (MAIN_CACHED_INTERPRETER_PREFETCH, default OFF). When
  // the flag is off NOTHING is emitted here and the loop is byte-identical to the current fast state.
  // ON re-adds the hints to A/B the "remove-prefetch = +33% on Apple Silicon" finding (expected slower).
#if defined(__GNUC__) || defined(__clang__)
  if (s_prefetch_enabled)
  {
    __builtin_prefetch(&ppc_state.gpr[0], 0, 3);
    __builtin_prefetch(&ppc_state.ps[0], 0, 3);
  }
#endif
  while (true)
  {
    const auto callback = *reinterpret_cast<const AnyCallback*>(normal_entry);
    const u8* payload = normal_entry + sizeof(callback);
    // Direct dispatch to the most commonly used callbacks for better performance
    if (callback == reinterpret_cast<AnyCallback>(CallbackCast(Interpret<false>))) [[likely]]
    {
      Interpret<false>(ppc_state, *reinterpret_cast<const InterpretOperands*>(payload));
      normal_entry = payload + sizeof(InterpretOperands);
    }
    else if (callback == reinterpret_cast<AnyCallback>(CallbackCast(Interpret<true>)))
    {
      Interpret<true>(ppc_state, *reinterpret_cast<const InterpretOperands*>(payload));
      normal_entry = payload + sizeof(InterpretOperands);
    }
    // iCube: specialized hot-op dispatch (only emitted when MAIN_CIR_SPECIALIZED_OPS is on; when off
    // neither marker callback value is ever written into the stream, so these two branches are dead
    // and the path below is never taken — flag-off behavior is byte-identical to stock 2509). We
    // recognize the marker (write_pc false/true), read the compact op-id from the payload, and
    // jump-table to the direct handler. This collapses the old chain's 2*N failing pointer compares
    // (N=29 with the LS ops added) to at most 2 marker compares + one jump-table branch, while
    // preserving the zero-indirect-CALL property. The [[likely]] generic fast path above is untouched
    // and still tested first.
    else if (callback == reinterpret_cast<AnyCallback>(CallbackCast(InterpretSpecialized<false>)))
    {
      const auto& ops = *reinterpret_cast<const SpecializedInterpretOperands*>(payload);
      const auto id = static_cast<CirSpecOp>(ops.op_id);
      CIR_SPEC_SWITCH(id, ops);
      normal_entry = payload + sizeof(SpecializedInterpretOperands);
    }
    else if (callback == reinterpret_cast<AnyCallback>(CallbackCast(InterpretSpecialized<true>)))
    {
      const auto& ops = *reinterpret_cast<const SpecializedInterpretOperands*>(payload);
      ppc_state.pc = ops.current_pc;
      ppc_state.npc = ops.current_pc + 4;
      const auto id = static_cast<CirSpecOp>(ops.op_id);
      CIR_SPEC_SWITCH(id, ops);
      normal_entry = payload + sizeof(SpecializedInterpretOperands);
    }
    // iCube: block-linking safety guard. LinkBlock is the ONLY callback whose nonzero return jumps to
    // ANOTHER block's entry (every other positive distance just advances within the current block), so
    // a linked hop is exactly "the followed callback was LinkBlock". We give it a dedicated branch (this
    // is the same callback-identity discrimination the hot branches above already use) so the guard's
    // cost — one state load + compare + one counter increment + compare — is paid ONLY per real linked
    // hop, never per instruction and never per intra-block callback. The stored value comes from
    // Write(LinkBlock, ...) -> AnyCallbackCast(reinterpret_cast<AnyCallback>) of the runtime overload;
    // we reconstruct the identical value here. The LinkBlock name is overloaded (runtime + ostream
    // debug), so we disambiguate to the runtime overload via the Callback<LinkBlockOperands> cast.
    // When block linking is OFF no LinkBlock callback is ever emitted, so this branch never matches and
    // the guard is dead — the only off-path delta is one extra failed pointer-compare at block-terminal
    // callbacks (once per block), never on the per-instruction Interpret<> fast path.
    else if (callback ==
             reinterpret_cast<AnyCallback>(CallbackCast<LinkBlockOperands>(LinkBlock))) [[unlikely]]
    {
      const auto distance = callback(ppc_state, payload);
      if (distance == 0)
        break;  // LinkBlock's own guards (downcount<=0 / npc!=expected_pc / rel==0) -> dispatcher.
      normal_entry += distance;
      // (1) Per-iteration running check: a stop/pause/state-change request would otherwise not be
      // observed until the slice ends (the linked loop has no downcount<=0 exit of its own). Mirror
      // Run()'s `*state_ptr == CPU::State::Running` test — a single non-atomic load + compare, no new
      // atomics. Bails to the dispatcher (Run's inner do/while re-checks the same condition).
      if (*state_ptr != CPU::State::Running) [[unlikely]]
        break;
      // (2) Bounded hop cap: force a dispatcher round-trip after CIR_MAX_LINKED_HOPS consecutive links
      // regardless of downcount, bounding the worst-case wake-race spin. Reset is implicit (linked_hops
      // is a fresh local on the next ExecuteOneBlock entry). This does NOT touch downcount or call
      // CoreTiming::Advance(), so interrupt/decrementer cadence is byte-for-byte unchanged — a cap-hit
      // only costs one extra Dispatch() of the same target on the opt-in linked path.
      if (++linked_hops >= CIR_MAX_LINKED_HOPS) [[unlikely]]
        break;
    }
    else
    {
      if (const auto distance = callback(ppc_state, payload))
        normal_entry += distance;
      else
        break;
    }
  }
}

void CachedInterpreter::Run()
{
  auto& core_timing = m_system.GetCoreTiming();

  const CPU::State* state_ptr = m_system.GetCPU().GetStatePtr();
  while (*state_ptr == CPU::State::Running)
  {
    // Start new timing slice
    // NOTE: Exceptions may change PC
    core_timing.Advance();

    do
    {
      ExecuteOneBlock(state_ptr);
    } while (m_ppc_state.downcount > 0 && *state_ptr == CPU::State::Running);
  }
}

void CachedInterpreter::SingleStep()
{
  // Enter new timing slice
  m_system.GetCoreTiming().Advance();
  // iCube: thread the run-state pointer through for the block-linking safety guard (same source Run()
  // uses). On a single step a linked chain cannot form across the one block, so the guard is inert here.
  ExecuteOneBlock(m_system.GetCPU().GetStatePtr());
}

s32 CachedInterpreter::StartProfiledBlock(PowerPC::PowerPCState& ppc_state,
                                          const StartProfiledBlockOperands& operands)
{
  JitBlock::ProfileData::BeginProfiling(operands.profile_data);
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool profiled>
s32 CachedInterpreter::EndBlock(PowerPC::PowerPCState& ppc_state,
                                const EndBlockOperands<profiled>& operands)
{
  ppc_state.pc = ppc_state.npc;
  ppc_state.downcount -= operands.downcount;
  // iCube WIN#3: only touch the PMC when the game actually configured it (MMCR0/MMCR1 non-zero).
  // Most titles never enable the performance monitor, so this skips the update entirely while
  // staying bit-accurate for the titles that do — strictly better than the old default-off skip flag.
  if (PowerPC::PerformanceMonitorActive(ppc_state))
    PowerPC::UpdatePerformanceMonitor(operands.downcount, operands.num_load_stores,
                                      operands.num_fp_inst, ppc_state);
  // iCube: hot-block profiler (MAIN_CIR_PROFILE, default OFF). Once-per-block, gated on a single
  // predicted-not-taken bool — the per-instruction Interpret<> path is untouched. operands.downcount
  // is the SAME emulated-cycle count already charged to ppc_state.downcount; no new timing.
  if (s_cir_profile) [[unlikely]]
    s_block_profile.Record(operands.entry_pc, operands.downcount);
  if constexpr (profiled)
    JitBlock::ProfileData::EndProfiling(operands.profile_data, operands.downcount);
  return 0;
}

// iCube: block-linking trampoline. See header. Composes with the specialized-op prototype: those
// flags only change which per-INSTRUCTION callback is emitted; this changes only the block TERMINAL.
// They never touch the same operand and ExecuteOneBlock dispatches LinkBlock through the unchanged
// generic indirect tail, so the two features are orthogonal and may be enabled together.
s32 CachedInterpreter::LinkBlock(PowerPC::PowerPCState& ppc_state, const LinkBlockOperands& operands)
{
  // (1) End-of-block accounting — IDENTICAL to EndBlock<false>. Must run on EVERY exit (linked or
  // not) so pc/downcount/PMC bookkeeping is exactly what the unlinked path would have produced.
  ppc_state.pc = ppc_state.npc;
  ppc_state.downcount -= operands.downcount;
  // iCube WIN#3: PMC update gated on the game having configured the performance monitor (see EndBlock).
  if (PowerPC::PerformanceMonitorActive(ppc_state))
    PowerPC::UpdatePerformanceMonitor(operands.downcount, operands.num_load_stores,
                                      operands.num_fp_inst, ppc_state);

  // iCube: hot-block profiler (MAIN_CIR_PROFILE, default OFF). This block executed regardless of
  // whether the link is followed below, so record here — once per block exit, mirroring EndBlock.
  // Gated on a single predicted-not-taken bool; never touches the per-instruction fast path.
  if (s_cir_profile) [[unlikely]]
    s_block_profile.Record(operands.entry_pc, operands.downcount);

  // (2) Slice-boundary guard. If the timing slice is exhausted we MUST return to the dispatcher / Run
  // loop so CoreTiming::Advance() runs and services the decrementer + external interrupts (delivered
  // via CheckExternalExceptions once MSR.EE is set). Following a link here would starve timing and
  // miss interrupts — exactly the guard the evolved testflight LinkToBlockEndDistance dropped.
  if (ppc_state.downcount <= 0) [[unlikely]]
    return 0;

  // (3) Target guard. Only follow the link when the architectural next PC equals the STATIC branch
  // target this exit was compiled for. For an unconditional bx this always holds; for a conditional
  // bcx it holds only on the taken edge — the not-taken edge has npc == fallthrough != expected_pc
  // and correctly deopts to the dispatcher. Any computed/indirect divergence also deopts. Fail-safe:
  // a mismatch NEVER executes the wrong stream, it just costs one dispatcher round-trip.
  if (ppc_state.npc != operands.expected_pc) [[unlikely]]
    return 0;

  // (4) Linkage. rel == 0 means the target is not (yet) compiled or has been unlinked/destroyed; the
  // upstream machinery sets it via WriteLinkBlock and clears it back to 0 on UnlinkBlock/DestroyBlock.
  // (No explicit zero-downcount/infinite-chain guard like the old rollback impl: a linkable terminal
  // is always a bx/bcx, which the analyzer always charges >=1 cycle, so a linked block's per-iteration
  // downcount is always >=1 and the slice bail in (2) terminates every chain in bounded steps.)
  const s32 rel = operands.rel;
  if (rel == 0) [[unlikely]]
    return 0;

  // (5) Optional self-validation. The strongest check (resolving GetBlockFromStartAddress(npc,
  // feature_flags) and asserting normalEntry == callback_site + rel) needs the block cache, which a
  // static callback can reach only through the singleton instance pointer recorded in Init. We use it
  // here, gated and [[unlikely]], so the fast path is untouched. This proves: (a) the dispatcher would
  // resolve a block right now, (b) its entry is exactly where rel points (rel is not stale and not
  // off-by-one), and (c) the target's feature_flags equal the running context's flags (no MSR/IR/DR
  // divergence across the link). Equivalent emit-time invariants are also asserted in WriteLinkBlock.
  if (s_block_linking_validate && s_validate_instance) [[unlikely]]
  {
    const u8* callback_site = reinterpret_cast<const u8*>(&operands) - sizeof(AnyCallback);
    JitBlock* expected = s_validate_instance->m_block_cache.GetBlockFromStartAddress(
        ppc_state.pc, ppc_state.feature_flags);
    ASSERT_MSG(DYNA_REC, expected != nullptr,
               "CIR link: dispatcher would NOT have resolved a block at pc {:#010x}", ppc_state.pc);
    if (expected)
    {
      ASSERT_MSG(DYNA_REC, expected->normalEntry == callback_site + rel,
                 "CIR link: stale/wrong rel at pc {:#010x} (rel={}, target entry {} != {})",
                 ppc_state.pc, rel, fmt::ptr(expected->normalEntry), fmt::ptr(callback_site + rel));
      ASSERT_MSG(DYNA_REC, expected->feature_flags == ppc_state.feature_flags,
                 "CIR link: feature_flags divergence at pc {:#010x} (block {:#x} vs ctx {:#x})",
                 ppc_state.pc, static_cast<u32>(expected->feature_flags),
                 static_cast<u32>(ppc_state.feature_flags));
    }
  }

  return rel;
}

s32 CachedInterpreter::LinkBlock(std::ostream& stream, const LinkBlockOperands& operands)
{
  fmt::print(stream, "LinkBlock(downcount={}, expected_pc={:#010x}, rel={})\n", operands.downcount,
             operands.expected_pc, operands.rel);
  return sizeof(AnyCallback) + sizeof(operands);
}

void CachedInterpreter::PatchLinkBlockRel(u8* exit_ptrs, s32 rel)
{
  // The trampoline is laid out as [AnyCallback][LinkBlockOperands]; rel is the last field of the
  // operands. We mutate ONLY rel — never the callback pointer or the other (immutable) operands — so
  // a concurrent reader on the CPU thread either sees the old or the new rel, both of which are
  // self-consistent (LinkBlock re-validates downcount + npc regardless). On this single-CPU-thread
  // core the patch happens during codegen (Jit), with the CPU thread not executing this block.
  auto* operands = reinterpret_cast<LinkBlockOperands*>(exit_ptrs + sizeof(AnyCallback));
  operands->rel = rel;
}

template <bool write_pc>
s32 CachedInterpreter::Interpret(PowerPC::PowerPCState& ppc_state,
                                 const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  operands.func(operands.interpreter, operands.inst);
  return sizeof(AnyCallback) + sizeof(operands);
}

// True if the op-id is a Tier-3 load/store (vs a Tier-1 ALU op). LS ops are NOT safe to double-run
// (a store would double-write memory, a load could double-read MMIO), so the validate path uses
// single-run validation for them. Generated from CIR_SPECIALIZED_LS_OPS so it can't drift.
static bool IsLoadStoreSpecOp(CirSpecOp id)
{
  switch (id)
  {
#define CIR_LS_CASE(name)                                                                          \
  case CirSpecOp::name:                                                                            \
    return true;
    CIR_SPECIALIZED_LS_OPS(CIR_LS_CASE)
#undef CIR_LS_CASE
  default:
    return false;
  }
}

// iCube: specialized dispatch callback. Two instantiations (write_pc false/true). On the fast path
// this is NOT called indirectly — ExecuteOneBlock recognizes the marker and inlines the same
// CIR_SPEC_SWITCH jump-table. This body exists as a correct STANDALONE callback (identical switch),
// so it is safe if ever reached through the generic indirect tail, and as the value the dispatch
// compares against. The ONLY behavioral difference from Interpret<write_pc> is that the per-op
// handler is invoked by its compile-time-constant pointer (direct/inlinable) via the switch instead
// of operands.func (indirect). write_pc pc/npc writes and the return distance are reproduced exactly.
template <bool write_pc>
s32 CachedInterpreter::InterpretSpecialized(PowerPC::PowerPCState& ppc_state,
                                            const SpecializedInterpretOperands& operands)
{
  const auto id = static_cast<CirSpecOp>(operands.op_id);
  const s32 specialized_distance = sizeof(AnyCallback) + sizeof(operands);

  if (s_specialized_ops_validate) [[unlikely]]
  {
    // Two validate regimes, keyed on the op category (the X-macro is still the single source of
    // truth — IsLoadStoreSpecOp is generated from CIR_SPECIALIZED_LS_OPS).
    if (IsLoadStoreSpecOp(id))
    {
      // SINGLE-RUN validation. A second/reference run is UNSAFE for load/stores: a store would
      // double-write memory and a load could double-read MMIO. Handler math is identical by
      // construction (the switch calls the SAME Interpreter::name GetInterpreterOp returned, and the
      // generic path also routes these through plain Interpret since memcheck is off), so there is
      // nothing to diff — we validate only the BOOKKEEPING contract: pc/npc behavior and the return
      // distance. write_pc is always false for these (D-form, canEndBlock == false), so pc/npc must
      // be UNCHANGED by the dispatch. We snapshot pc/npc AND Exceptions before the single live run
      // and assert pc/npc are untouched afterward; Exceptions is captured so a DSI raised inside the
      // MMU access is observed but explicitly NOT required to be clear (deferred to the block
      // boundary exactly as the generic path leaves it).
      // NOTE: write_pc is always false for these at emit time (D-form, canEndBlock == false). Both
      // if constexpr branches are kept for completeness/robustness, but only the !write_pc path runs.
      // saved_pc/saved_npc are read only in the !write_pc instantiation's assert; tag maybe_unused so
      // the write_pc==true instantiation (where the else-branch uses operands.current_pc) is clean.
      [[maybe_unused]] const u32 saved_pc = ppc_state.pc;
      [[maybe_unused]] const u32 saved_npc = ppc_state.npc;
      const u32 saved_exceptions = ppc_state.Exceptions;

      if constexpr (write_pc)
      {
        ppc_state.pc = operands.current_pc;
        ppc_state.npc = operands.current_pc + 4;
      }
      CIR_SPEC_SWITCH(id, operands);

      if constexpr (!write_pc)
      {
        ASSERT_MSG(DYNA_REC, ppc_state.pc == saved_pc && ppc_state.npc == saved_npc,
                   "CIR specialized LS op unexpectedly wrote pc/npc at pc {:#x} (pc {:#x}->{:#x}, "
                   "npc {:#x}->{:#x})",
                   operands.current_pc, saved_pc, ppc_state.pc, saved_npc, ppc_state.npc);
      }
      else
      {
        ASSERT_MSG(DYNA_REC,
                   ppc_state.pc == operands.current_pc && ppc_state.npc == operands.current_pc + 4,
                   "CIR specialized LS op pc/npc contract violated at pc {:#x}",
                   operands.current_pc);
      }
      // Exceptions is part of the validated state set: assert the dispatch only ever ADDS bits
      // (never clears a pending exception), matching the generic trampoline which never touches it.
      ASSERT_MSG(DYNA_REC, (ppc_state.Exceptions & saved_exceptions) == saved_exceptions,
                 "CIR specialized LS op cleared a pending exception at pc {:#x} ({:#x}->{:#x})",
                 operands.current_pc, saved_exceptions, ppc_state.Exceptions);
      return specialized_distance;
    }

    // DOUBLE-RUN validation for Tier-1 ALU ops (safe: side effects confined to the register file).
    // Run the generic Interpret<write_pc> on the live state, snapshot the result, restore, run the
    // specialized switch, and assert architectural state + return distance match. gpr/cr.fields are
    // C arrays; snapshot via std::array copies so we can compare with ==.
    std::array<u32, 32> saved_gpr;
    std::array<u64, 8> saved_cr;
    std::copy(std::begin(ppc_state.gpr), std::end(ppc_state.gpr), saved_gpr.begin());
    std::copy(std::begin(ppc_state.cr.fields), std::end(ppc_state.cr.fields), saved_cr.begin());
    // XER lives in the split fields xer_ca / xer_so_ov, NOT spr[SPR_XER] (only reconstructed on
    // mfspr). Watch the live fields so this is correct for ops that affect carry/overflow.
    const u8 saved_xer_ca = ppc_state.xer_ca;
    const u8 saved_xer_so_ov = ppc_state.xer_so_ov;
    const u32 saved_pc = ppc_state.pc;
    const u32 saved_npc = ppc_state.npc;
    // Snapshot Exceptions too so a stray bit from the reference run can neither leak into the
    // specialized run nor falsify the diff (ALU ops should never touch it, which the compare proves).
    const u32 saved_exceptions = ppc_state.Exceptions;

    // Generic reference run on the live state (exactly what the unspecialized block would have done,
    // using the same operands.func the emission site captured into the InterpretOperands prefix).
    const InterpretOperands& generic_operands = operands;
    const s32 generic_distance = Interpret<write_pc>(ppc_state, generic_operands);

    std::array<u32, 32> generic_gpr;
    std::array<u64, 8> generic_cr;
    std::copy(std::begin(ppc_state.gpr), std::end(ppc_state.gpr), generic_gpr.begin());
    std::copy(std::begin(ppc_state.cr.fields), std::end(ppc_state.cr.fields), generic_cr.begin());
    const u8 generic_xer_ca = ppc_state.xer_ca;
    const u8 generic_xer_so_ov = ppc_state.xer_so_ov;
    const u32 generic_pc = ppc_state.pc;
    const u32 generic_npc = ppc_state.npc;
    const u32 generic_exceptions = ppc_state.Exceptions;

    // Restore (including Exceptions) and run the specialized switch.
    std::copy(saved_gpr.begin(), saved_gpr.end(), std::begin(ppc_state.gpr));
    std::copy(saved_cr.begin(), saved_cr.end(), std::begin(ppc_state.cr.fields));
    ppc_state.xer_ca = saved_xer_ca;
    ppc_state.xer_so_ov = saved_xer_so_ov;
    ppc_state.pc = saved_pc;
    ppc_state.npc = saved_npc;
    ppc_state.Exceptions = saved_exceptions;

    if constexpr (write_pc)
    {
      ppc_state.pc = operands.current_pc;
      ppc_state.npc = operands.current_pc + 4;
    }
    CIR_SPEC_SWITCH(id, operands);

    std::array<u32, 32> spec_gpr;
    std::array<u64, 8> spec_cr;
    std::copy(std::begin(ppc_state.gpr), std::end(ppc_state.gpr), spec_gpr.begin());
    std::copy(std::begin(ppc_state.cr.fields), std::end(ppc_state.cr.fields), spec_cr.begin());

    // Distance is checked against its own analytic constant (NOT generic_distance): the specialized
    // payload is SpecializedInterpretOperands (larger than the generic InterpretOperands), so the two
    // distances legitimately differ — equating them would spuriously fire. Architectural-state
    // compares below are layout-independent and ARE compared against the generic run.
    ASSERT_MSG(DYNA_REC,
               specialized_distance ==
                   static_cast<s32>(sizeof(AnyCallback) + sizeof(SpecializedInterpretOperands)),
               "CIR specialized op return distance constant mismatch: {}", specialized_distance);
    // The generic distance is checked against ITS OWN base-payload constant — the two distances
    // legitimately differ (SpecializedInterpretOperands is larger than InterpretOperands), which is
    // exactly why specialized_distance is NOT compared to generic_distance. This also consumes
    // generic_distance (the reference run's return) so it is not a set-but-unused value.
    ASSERT_MSG(DYNA_REC,
               generic_distance ==
                   static_cast<s32>(sizeof(AnyCallback) + sizeof(InterpretOperands)),
               "CIR generic op return distance constant mismatch: {}", generic_distance);
    ASSERT_MSG(DYNA_REC, spec_gpr == generic_gpr, "CIR specialized op GPR mismatch at pc {:#x}",
               operands.current_pc);
    ASSERT_MSG(DYNA_REC, spec_cr == generic_cr, "CIR specialized op CR mismatch at pc {:#x}",
               operands.current_pc);
    ASSERT_MSG(DYNA_REC,
               ppc_state.xer_ca == generic_xer_ca && ppc_state.xer_so_ov == generic_xer_so_ov,
               "CIR specialized op XER mismatch at pc {:#x}", operands.current_pc);
    ASSERT_MSG(DYNA_REC, ppc_state.pc == generic_pc && ppc_state.npc == generic_npc,
               "CIR specialized op PC/NPC mismatch at pc {:#x}", operands.current_pc);
    ASSERT_MSG(DYNA_REC, ppc_state.Exceptions == generic_exceptions,
               "CIR specialized op Exceptions mismatch at pc {:#x} ({:#x} vs generic {:#x})",
               operands.current_pc, ppc_state.Exceptions, generic_exceptions);
    return specialized_distance;
  }

  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  CIR_SPEC_SWITCH(id, operands);
  return specialized_distance;
}

template <bool write_pc>
s32 CachedInterpreter::InterpretAndCheckExceptions(
    PowerPC::PowerPCState& ppc_state, const InterpretAndCheckExceptionsOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  operands.func(operands.interpreter, operands.inst);

  if ((ppc_state.Exceptions & (EXCEPTION_DSI | EXCEPTION_PROGRAM)) != 0)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.downcount -= operands.downcount;
    operands.power_pc.CheckExceptions();
    return 0;
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

// iCube WIN#1: PIC direct-pointer D-form integer load/store. INTEGER ONLY (FP opcodes are excluded at
// the emission site via FL_USE_FPU and never reach here). Any opcode/alignment/region this switch does
// not handle delegates to Cold_LoadStoreFallback, which runs the exact generic interpreter handler, so
// DSI/alignment/MMIO semantics are preserved for everything PIC does not specialize. write_pc mirrors
// Interpret<write_pc>. Ported (integer subset, scalar lmw/stmw) from feature/icube-testflight.
template <bool write_pc>
s32 CachedInterpreter::LoadStoreDFormPIC(PowerPC::PowerPCState& ppc_state,
                                         const LoadStoreDFormPICOperands& operands)
{
  const auto& [interpreter, func, current_pc, inst, power_pc, mem1_base, mem1_mask, exram_base,
               exram_mask, fakevmem_base, fakevmem_mask] = operands;

  if constexpr (write_pc)
  {
    ppc_state.pc = current_pc;
    ppc_state.npc = current_pc + 4;
  }

  // D-form EA: ea = (RA ? GPR[RA] : 0) + SIMM_16
  const u32 ra = inst.RA;
  const u32 ea = ra ? (ppc_state.gpr[ra] + static_cast<u32>(inst.SIMM_16))
                    : static_cast<u32>(inst.SIMM_16);

  u8* base_ptr = nullptr;
  u32 offset = 0;
  const auto region = CI_GetRegionInfo(ea, ppc_state.msr.DR, mem1_base, mem1_mask, exram_base,
                                       exram_mask, fakevmem_base, fakevmem_mask);
  if (region.base)
  {
    base_ptr = region.base;
    offset = CI_RegionOffset(region, ea);
  }

  if (base_ptr) [[likely]]
  {
    // iCube: optional PIC-data prefetch (MAIN_CACHED_INTERPRETER_PREFETCH, default OFF). Off => no
    // hint emitted (byte-identical to the current fast state); ON re-adds it to A/B the +33%-by-
    // removal finding. Read hints (locality 1) over the target line; safe for both loads and stores.
#if defined(__GNUC__) || defined(__clang__)
    if (s_prefetch_enabled)
    {
      __builtin_prefetch(base_ptr + offset, 0, 1);
      __builtin_prefetch(base_ptr + offset + 32, 0, 1);
    }
#endif
    switch (inst.OPCD)
    {
    case 32:  // lwz
    {
      if ((ea & 0b11) != 0) [[unlikely]]
        break;
      const u32 raw = *reinterpret_cast<const u32*>(base_ptr + offset);
      ppc_state.gpr[inst.RD] = Common::FromBigEndian(raw);
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 33:  // lwzu (update)
    {
      if (ra == 0 || (ea & 0b11) != 0) [[unlikely]]
        break;
      const u32 raw = *reinterpret_cast<const u32*>(base_ptr + offset);
      ppc_state.gpr[inst.RD] = Common::FromBigEndian(raw);
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 34:  // lbz
    {
      ppc_state.gpr[inst.RD] = static_cast<u32>(*(base_ptr + offset));
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 35:  // lbzu (update)
    {
      if (ra == 0)
        break;
      ppc_state.gpr[inst.RD] = static_cast<u32>(*(base_ptr + offset));
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 40:  // lhz
    {
      if ((ea & 0b1) != 0) [[unlikely]]
        break;
      const u16 raw = *reinterpret_cast<const u16*>(base_ptr + offset);
      ppc_state.gpr[inst.RD] = static_cast<u32>(Common::FromBigEndian(raw));
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 41:  // lhzu (update)
    {
      if (ra == 0 || (ea & 0b1) != 0) [[unlikely]]
        break;
      const u16 raw = *reinterpret_cast<const u16*>(base_ptr + offset);
      ppc_state.gpr[inst.RD] = static_cast<u32>(Common::FromBigEndian(raw));
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 42:  // lha
    {
      if ((ea & 0b1) != 0) [[unlikely]]
        break;
      const u16 raw = *reinterpret_cast<const u16*>(base_ptr + offset);
      ppc_state.gpr[inst.RD] = static_cast<u32>(static_cast<s16>(Common::FromBigEndian(raw)));
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 43:  // lhau (update)
    {
      if (ra == 0 || (ea & 0b1) != 0) [[unlikely]]
        break;
      const u16 raw = *reinterpret_cast<const u16*>(base_ptr + offset);
      ppc_state.gpr[inst.RD] = static_cast<u32>(static_cast<s16>(Common::FromBigEndian(raw)));
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 36:  // stw
    {
      if ((ea & 0b11) != 0) [[unlikely]]
        break;
      *reinterpret_cast<u32*>(base_ptr + offset) = Common::swap32(ppc_state.gpr[inst.RS]);
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 37:  // stwu (update)
    {
      if (ra == 0 || (ea & 0b11) != 0) [[unlikely]]
        break;
      *reinterpret_cast<u32*>(base_ptr + offset) = Common::swap32(ppc_state.gpr[inst.RS]);
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 38:  // stb
    {
      *(base_ptr + offset) = static_cast<u8>(ppc_state.gpr[inst.RS]);
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 39:  // stbu (update)
    {
      if (ra == 0)
        break;
      *(base_ptr + offset) = static_cast<u8>(ppc_state.gpr[inst.RS]);
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 44:  // sth
    {
      if ((ea & 0b1) != 0) [[unlikely]]
        break;
      *reinterpret_cast<u16*>(base_ptr + offset) =
          Common::swap16(static_cast<u16>(ppc_state.gpr[inst.RS]));
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 45:  // sthu (update)
    {
      if (ra == 0 || (ea & 0b1) != 0) [[unlikely]]
        break;
      *reinterpret_cast<u16*>(base_ptr + offset) =
          Common::swap16(static_cast<u16>(ppc_state.gpr[inst.RS]));
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 46:  // lmw
    {
      if ((ea & 0b11) != 0 || ppc_state.msr.LE) [[unlikely]]
        break;
      const u32 count = 32u - static_cast<u32>(inst.RD);
      // Pre-scan: the entire range must lie in a single fast region, else fall back.
      u8* region_base = nullptr;
      u32 region_mask = 0;
      u32 region_sub = 0;
      bool region_is_fake = false;
      bool ok = true;
      u32 addr = ea;
      for (u32 k = 0; k < count; ++k, addr += 4)
      {
        const auto r = CI_GetRegionInfo(addr, ppc_state.msr.DR, mem1_base, mem1_mask, exram_base,
                                        exram_mask, fakevmem_base, fakevmem_mask);
        if (!r.base)
        {
          ok = false;
          break;
        }
        if (!region_base)
        {
          region_base = r.base;
          region_mask = r.mask;
          region_sub = r.sub;
          region_is_fake = r.is_fake;
        }
        else if (region_base != r.base || region_mask != r.mask || region_sub != r.sub ||
                 region_is_fake != r.is_fake)
        {
          ok = false;
          break;
        }
      }
      if (!ok || !region_base)
        break;
      addr = ea;
      for (u32 r = static_cast<u32>(inst.RD); r <= 31u; ++r, addr += 4)
      {
        const u32 roff =
            region_is_fake ? (addr & region_mask) : ((addr - region_sub) & region_mask);
        const u32 raw = *reinterpret_cast<const u32*>(region_base + roff);
        ppc_state.gpr[r] = Common::FromBigEndian(raw);
      }
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 47:  // stmw
    {
      if ((ea & 0b11) != 0 || ppc_state.msr.LE) [[unlikely]]
        break;
      const u32 count = 32u - static_cast<u32>(inst.RS);
      u8* region_base = nullptr;
      u32 region_mask = 0;
      u32 region_sub = 0;
      bool region_is_fake = false;
      bool ok = true;
      u32 addr = ea;
      for (u32 k = 0; k < count; ++k, addr += 4)
      {
        const auto r = CI_GetRegionInfo(addr, ppc_state.msr.DR, mem1_base, mem1_mask, exram_base,
                                        exram_mask, fakevmem_base, fakevmem_mask);
        if (!r.base)
        {
          ok = false;
          break;
        }
        if (!region_base)
        {
          region_base = r.base;
          region_mask = r.mask;
          region_sub = r.sub;
          region_is_fake = r.is_fake;
        }
        else if (region_base != r.base || region_mask != r.mask || region_sub != r.sub ||
                 region_is_fake != r.is_fake)
        {
          ok = false;
          break;
        }
      }
      if (!ok || !region_base)
        break;
      addr = ea;
      for (u32 r = static_cast<u32>(inst.RS); r <= 31u; ++r, addr += 4)
      {
        const u32 roff =
            region_is_fake ? (addr & region_mask) : ((addr - region_sub) & region_mask);
        *reinterpret_cast<u32*>(region_base + roff) = Common::swap32(ppc_state.gpr[r]);
      }
      return sizeof(AnyCallback) + sizeof(operands);
    }
    default:
      break;  // FP or unsupported D-form -> fallback
    }
  }
  return Cold_LoadStoreFallback(ppc_state, operands);
}

template <bool write_pc>
s32 CachedInterpreter::LoadStoreDFormPIC(std::ostream& stream,
                                         const LoadStoreDFormPICOperands& operands)
{
  fmt::print(stream, "LoadStoreDFormPIC(pc={:#010x}, OPCD={})\n", operands.current_pc,
             operands.inst.OPCD);
  return sizeof(AnyCallback) + sizeof(operands);
}

// iCube WIN#1: PIC direct-pointer X-form integer load/store (OPCD == 31). INTEGER ONLY. Byte-reverse
// variants (lwbrx/lhbrx/stwbrx/sthbrx) are integer and included; FP-indexed and paired-single forms
// are excluded at the emission site (FL_USE_FPU) and any unhandled SUBOP10 falls back generically.
template <bool write_pc>
s32 CachedInterpreter::LoadStoreXFormPIC(PowerPC::PowerPCState& ppc_state,
                                         const LoadStoreDFormPICOperands& operands)
{
  const auto& [interpreter, func, current_pc, inst, power_pc, mem1_base, mem1_mask, exram_base,
               exram_mask, fakevmem_base, fakevmem_mask] = operands;

  if constexpr (write_pc)
  {
    ppc_state.pc = current_pc;
    ppc_state.npc = current_pc + 4;
  }

  // X-form EA: ea = (RA ? GPR[RA] : 0) + GPR[RB]
  const u32 ra = inst.RA;
  const u32 rb = inst.RB;
  const u32 ea = (ra ? ppc_state.gpr[ra] : 0) + ppc_state.gpr[rb];

  u8* base_ptr = nullptr;
  u32 offset = 0;
  const auto region = CI_GetRegionInfo(ea, ppc_state.msr.DR, mem1_base, mem1_mask, exram_base,
                                       exram_mask, fakevmem_base, fakevmem_mask);
  if (region.base)
  {
    base_ptr = region.base;
    offset = CI_RegionOffset(region, ea);
  }

  if (base_ptr) [[likely]]
  {
    // iCube: optional PIC-data prefetch (MAIN_CACHED_INTERPRETER_PREFETCH, default OFF). Off => no
    // hint emitted (byte-identical to the current fast state); ON re-adds it to A/B the +33%-by-
    // removal finding. Read hints (locality 1) over the target line; safe for both loads and stores.
#if defined(__GNUC__) || defined(__clang__)
    if (s_prefetch_enabled)
    {
      __builtin_prefetch(base_ptr + offset, 0, 1);
      __builtin_prefetch(base_ptr + offset + 32, 0, 1);
    }
#endif
    switch (inst.SUBOP10)
    {
    case 23:   // lwzx
    case 55:   // lwzux (update)
    {
      const bool update = (inst.SUBOP10 == 55);
      if ((ea & 0b11) != 0 || (update && ra == 0)) [[unlikely]]
        break;
      const u32 raw = *reinterpret_cast<const u32*>(base_ptr + offset);
      ppc_state.gpr[inst.RD] = Common::FromBigEndian(raw);
      if (update)
        ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 87:   // lbzx
    case 119:  // lbzux (update)
    {
      const bool update = (inst.SUBOP10 == 119);
      if (update && ra == 0)
        break;
      ppc_state.gpr[inst.RD] = static_cast<u32>(*(base_ptr + offset));
      if (update)
        ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 279:  // lhzx
    case 311:  // lhzux (update)
    {
      const bool update = (inst.SUBOP10 == 311);
      if ((ea & 0b1) != 0 || (update && ra == 0)) [[unlikely]]
        break;
      const u16 raw = *reinterpret_cast<const u16*>(base_ptr + offset);
      ppc_state.gpr[inst.RD] = static_cast<u32>(Common::FromBigEndian(raw));
      if (update)
        ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 343:  // lhax
    case 375:  // lhaux (update)
    {
      const bool update = (inst.SUBOP10 == 375);
      if ((ea & 0b1) != 0 || (update && ra == 0)) [[unlikely]]
        break;
      const u16 raw = *reinterpret_cast<const u16*>(base_ptr + offset);
      ppc_state.gpr[inst.RD] = static_cast<u32>(static_cast<s16>(Common::FromBigEndian(raw)));
      if (update)
        ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 151:  // stwx
    case 183:  // stwux (update)
    {
      const bool update = (inst.SUBOP10 == 183);
      if ((ea & 0b11) != 0 || (update && ra == 0)) [[unlikely]]
        break;
      *reinterpret_cast<u32*>(base_ptr + offset) = Common::swap32(ppc_state.gpr[inst.RS]);
      if (update)
        ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 215:  // stbx
    case 247:  // stbux (update)
    {
      const bool update = (inst.SUBOP10 == 247);
      if (update && ra == 0)
        break;
      *(base_ptr + offset) = static_cast<u8>(ppc_state.gpr[inst.RS]);
      if (update)
        ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 407:  // sthx
    case 439:  // sthux (update)
    {
      const bool update = (inst.SUBOP10 == 439);
      if ((ea & 0b1) != 0 || (update && ra == 0)) [[unlikely]]
        break;
      *reinterpret_cast<u16*>(base_ptr + offset) =
          Common::swap16(static_cast<u16>(ppc_state.gpr[inst.RS]));
      if (update)
        ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 534:  // lwbrx
    {
      if ((ea & 0b11) != 0) [[unlikely]]
        break;
      const u32 raw = *reinterpret_cast<const u32*>(base_ptr + offset);
      ppc_state.gpr[inst.RD] = Common::swap32(Common::FromBigEndian(raw));
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 790:  // lhbrx
    {
      if ((ea & 0b1) != 0) [[unlikely]]
        break;
      const u16 raw = *reinterpret_cast<const u16*>(base_ptr + offset);
      ppc_state.gpr[inst.RD] = static_cast<u32>(Common::swap16(Common::FromBigEndian(raw)));
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 662:  // stwbrx
    {
      if ((ea & 0b11) != 0)
        break;
      const u32 raw = ppc_state.gpr[inst.RS];
      std::memcpy(base_ptr + offset, &raw, sizeof(raw));
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 918:  // sthbrx
    {
      if ((ea & 0b1) != 0)
        break;
      const u16 raw = static_cast<u16>(ppc_state.gpr[inst.RS]);
      std::memcpy(base_ptr + offset, &raw, sizeof(raw));
      return sizeof(AnyCallback) + sizeof(operands);
    }
    default:
      break;  // FP-indexed / paired-single / unsupported X-form -> fallback
    }
  }
  return Cold_LoadStoreFallback(ppc_state, operands);
}

template <bool write_pc>
s32 CachedInterpreter::LoadStoreXFormPIC(std::ostream& stream,
                                         const LoadStoreDFormPICOperands& operands)
{
  fmt::print(stream, "LoadStoreXFormPIC(pc={:#010x}, SUBOP10={})\n", operands.current_pc,
             operands.inst.SUBOP10);
  return sizeof(AnyCallback) + sizeof(operands);
}

// iCube WIN#1: cold fallback. Runs the exact generic interpreter handler captured at emit time, so
// DSI/alignment/MMIO semantics are identical to the non-PIC generic path. pc/npc were already written
// by the PIC body (write_pc) before any fallback, matching Interpret<write_pc>.
s32 CachedInterpreter::Cold_LoadStoreFallback(PowerPC::PowerPCState& /*ppc_state*/,
                                              const LoadStoreDFormPICOperands& operands)
{
  operands.func(operands.interpreter, operands.inst);
  return sizeof(AnyCallback) + sizeof(operands);
}

// iCube WIN#2: micro-op fusion engine (MAIN_CIR_MICROOP_FUSION). CI_SetPCForMicroOps mirrors the
// Interpret<write_pc> pc/npc contract; ExecuteMicroOps runs the packed MicroOp array via a
// computed-goto dispatch (one indirect branch per op, zero indirect calls). The dispatch_table
// order MUST match enum class MicroOpCode (static_assert enforces it). Each handler reproduces its
// interpreter op's GPR/CR0/XER side-effects byte-exactly. Ported verbatim from feature/icube-
// testflight. Only reached when the flag emitted an ExecuteMicroOps callback (flag-off: never).
template <bool write_pc>
static inline void CI_SetPCForMicroOps(PowerPC::PowerPCState& ppc_state, u32 pc)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = pc;
    ppc_state.npc = pc + 4;
  }
}

template <bool write_pc>
s32 CachedInterpreter::ExecuteMicroOps(PowerPC::PowerPCState& ppc_state,
                                                       const ExecuteMicroOpsOperands& operands)
{
  CI_SetPCForMicroOps<write_pc>(ppc_state, operands.current_pc);

  const u32 count = operands.count;
  const MicroOp* ops = operands.ops;
#if defined(__GNUC__) || defined(__clang__)
  {
    u32 i = 0;
    if (i >= count)
      goto micro_done;

    // The order here MUST match enum class MicroOpCode in CachedInterpreter.h
    static const void* dispatch_table[] = {
        &&op_CONST32,       // 0 MicroOpCode::CONST32
        &&op_CONST32_ADDRA, // 1 MicroOpCode::CONST32_ADDRA
        &&op_ADDI,          // 2 MicroOpCode::ADDI
        &&op_ADDIS,         // 3 MicroOpCode::ADDIS
        &&op_ORI,           // 4 MicroOpCode::ORI
        &&op_ORIS,          // 5 MicroOpCode::ORIS
        &&op_XORI,          // 6 MicroOpCode::XORI
        &&op_XORIS,         // 7 MicroOpCode::XORIS
        &&op_ANDI,          // 8 MicroOpCode::ANDI
        &&op_ANDIS,         // 9 MicroOpCode::ANDIS
        &&op_RLWINM_IMM,    // 10 MicroOpCode::RLWINM_IMM
        &&op_AND_RR,        // 11 MicroOpCode::AND_RR
        &&op_OR_RR,         // 12 MicroOpCode::OR_RR
        &&op_XOR_RR,        // 13 MicroOpCode::XOR_RR
        &&op_RLWIMI_IMM,    // 14 MicroOpCode::RLWIMI_IMM
        &&op_RLWNM_VAR,     // 15 MicroOpCode::RLWNM_VAR
        &&op_ANDC_RR,       // 16 MicroOpCode::ANDC_RR
        &&op_ORC_RR,        // 17 MicroOpCode::ORC_RR
        &&op_NAND_RR,       // 18 MicroOpCode::NAND_RR
        &&op_NOR_RR,        // 19 MicroOpCode::NOR_RR
        &&op_EQV_RR,        // 20 MicroOpCode::EQV_RR
        &&op_CNTLZW,        // 21 MicroOpCode::CNTLZW
        &&op_EXTSB,         // 22 MicroOpCode::EXTSB
        &&op_EXTSH,         // 23 MicroOpCode::EXTSH
        &&op_SLW_VAR,       // 24 MicroOpCode::SLW_VAR
        &&op_SRW_VAR,       // 25 MicroOpCode::SRW_VAR
        &&op_SRAW_VAR,      // 26 MicroOpCode::SRAW_VAR
        &&op_SRAWI_IMM,     // 27 MicroOpCode::SRAWI_IMM
        // Integer add/sub with carry/overflow semantics
        &&op_ADD_RR,        // 28 MicroOpCode::ADD_RR
        &&op_ADDC_RR,       // 29 MicroOpCode::ADDC_RR
        &&op_ADDE_RR,       // 30 MicroOpCode::ADDE_RR
        &&op_ADDME,         // 31 MicroOpCode::ADDME
        &&op_ADDZE,         // 32 MicroOpCode::ADDZE
        &&op_SUBF_RR,       // 33 MicroOpCode::SUBF_RR
        &&op_SUBFC_RR,      // 34 MicroOpCode::SUBFC_RR
        &&op_SUBFE_RR,      // 35 MicroOpCode::SUBFE_RR
        &&op_SUBFME,        // 36 MicroOpCode::SUBFME
        &&op_SUBFZE,        // 37 MicroOpCode::SUBFZE
        // Integer compare ops
        &&op_CMP_S_RR,      // 38 MicroOpCode::CMP_S_RR
        &&op_CMPL_U_RR,     // 39 MicroOpCode::CMPL_U_RR
        &&op_CMP_S_IMM,     // 40 MicroOpCode::CMP_S_IMM
        &&op_CMPL_U_IMM,    // 41 MicroOpCode::CMPL_U_IMM
        &&op_NOP            // 42 MicroOpCode::NOP
    };
    static_assert(std::size(dispatch_table) == static_cast<size_t>(MicroOpCode::COUNT),
                  "dispatch_table must cover all MicroOpCode entries and match enum order");

  micro_dispatch:
    {
      const MicroOp& m = ops[i];
      const unsigned op_index = static_cast<unsigned>(m.op);
      if (__builtin_expect(op_index >= static_cast<unsigned>(MicroOpCode::COUNT), 0))
        goto micro_done; // fail fast; invalid op emitted
      goto *dispatch_table[op_index];
    }

  op_CONST32:
    {
      const MicroOp& m = ops[i];
      ppc_state.gpr[m.rd] = m.imm;
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  // Compare handlers: update CR[rd] only, no GPR writes
  op_CMP_S_RR:
    {
      const MicroOp& m = ops[i];
      const s32 a = s32(ppc_state.gpr[m.ra]);
      const s32 b = s32(ppc_state.gpr[m.rb]);
      u32 crf = 0;
      crf |= (a < b) ? PowerPC::CR_LT : 0;
      crf |= (a > b) ? PowerPC::CR_GT : 0;
      crf |= (a == b) ? PowerPC::CR_EQ : 0;
      CI_WriteCRField(ppc_state, m.rd, crf);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_CMPL_U_RR:
    {
      const MicroOp& m = ops[i];
      const u32 a = ppc_state.gpr[m.ra];
      const u32 b = ppc_state.gpr[m.rb];
      u32 crf = 0;
      crf |= (a < b) ? PowerPC::CR_LT : 0;
      crf |= (a > b) ? PowerPC::CR_GT : 0;
      crf |= (a == b) ? PowerPC::CR_EQ : 0;
      CI_WriteCRField(ppc_state, m.rd, crf);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_CMP_S_IMM:
    {
      const MicroOp& m = ops[i];
      const s32 a = s32(ppc_state.gpr[m.ra]);
      const s32 b = s32(s16(m.imm & 0xFFFF));
      u32 crf = 0;
      crf |= (a < b) ? PowerPC::CR_LT : 0;
      crf |= (a > b) ? PowerPC::CR_GT : 0;
      crf |= (a == b) ? PowerPC::CR_EQ : 0;
      CI_WriteCRField(ppc_state, m.rd, crf);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_CMPL_U_IMM:
    {
      const MicroOp& m = ops[i];
      const u32 a = ppc_state.gpr[m.ra];
      const u32 b = m.imm & 0xFFFFu;
      u32 crf = 0;
      crf |= (a < b) ? PowerPC::CR_LT : 0;
      crf |= (a > b) ? PowerPC::CR_GT : 0;
      crf |= (a == b) ? PowerPC::CR_EQ : 0;
      CI_WriteCRField(ppc_state, m.rd, crf);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_CONST32_ADDRA:
    {
      const MicroOp& m = ops[i];
      const u32 ra_val = ppc_state.gpr[m.ra];
      const s32 hi = static_cast<s16>(static_cast<u32>(m.imm) >> 16);
      const u32 lo = m.imm & 0xFFFFu;
      const u32 upper_add = ra_val + (static_cast<u32>(hi) << 16);
      ppc_state.gpr[m.rd] = upper_add | lo;
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_ADDI:
    {
      const MicroOp& m = ops[i];
      const u32 ra_val = (m.ra == 0) ? 0u : ppc_state.gpr[m.ra];
      const s32 simm = static_cast<s32>(static_cast<s16>(m.imm & 0xFFFF));
      ppc_state.gpr[m.rd] = ra_val + static_cast<u32>(simm);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_ADDIS:
    {
      const MicroOp& m = ops[i];
      const u32 ra_val = (m.ra == 0) ? 0u : ppc_state.gpr[m.ra];
      const s32 simm = static_cast<s32>(static_cast<s16>(m.imm & 0xFFFF));
      ppc_state.gpr[m.rd] = ra_val + (static_cast<u32>(simm) << 16);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_ORI:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 ui = m.imm & 0xFFFFu;
      ppc_state.gpr[m.rd] = rs_val | ui;
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_ORIS:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 ui = (m.imm & 0xFFFFu) << 16;
      ppc_state.gpr[m.rd] = rs_val | ui;
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_XORI:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 ui = m.imm & 0xFFFFu;
      ppc_state.gpr[m.rd] = rs_val ^ ui;
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_XORIS:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 ui = (m.imm & 0xFFFFu) << 16;
      ppc_state.gpr[m.rd] = rs_val ^ ui;
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_ANDI:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 ui = m.imm & 0xFFFFu;
      ppc_state.gpr[m.rd] = rs_val & ui;
      CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_ANDIS:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 ui = (m.imm & 0xFFFFu) << 16;
      ppc_state.gpr[m.rd] = rs_val & ui;
      CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_RLWINM_IMM:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 sh = (m.imm >> 0) & 31u;
      const u32 mb = (m.imm >> 5) & 31u;
      const u32 me = (m.imm >> 10) & 31u;
      const u32 mask = MakeRotationMask(mb, me);
      ppc_state.gpr[m.rd] = std::rotl(rs_val, sh) & mask;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_AND_RR:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = rs_val & rb_val;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_OR_RR:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = rs_val | rb_val;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_XOR_RR:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = rs_val ^ rb_val;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_RLWIMI_IMM:
    {
      const MicroOp& m = ops[i];
      const u32 ra_old = ppc_state.gpr[m.rd];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 sh = (m.imm >> 0) & 31u;
      const u32 mb = (m.imm >> 5) & 31u;
      const u32 me = (m.imm >> 10) & 31u;
      const u32 mask = MakeRotationMask(mb, me);
      const u32 rot = std::rotl(rs_val, sh) & mask;
      ppc_state.gpr[m.rd] = (ra_old & ~mask) | rot;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_RLWNM_VAR:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb] & 31u; // shift is low 5 bits of RB
      const u32 mb = (m.imm >> 5) & 31u;
      const u32 me = (m.imm >> 10) & 31u;
      const u32 mask = MakeRotationMask(mb, me);
      ppc_state.gpr[m.rd] = std::rotl(rs_val, rb_val) & mask;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_ANDC_RR:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = rs_val & ~rb_val;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_ORC_RR:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = rs_val | ~rb_val;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_NAND_RR:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = ~(rs_val & rb_val);
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_NOR_RR:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = ~(rs_val | rb_val);
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_EQV_RR:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = ~(rs_val ^ rb_val);
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_CNTLZW:
    {
      const MicroOp& m = ops[i];
      ppc_state.gpr[m.rd] = static_cast<u32>(std::countl_zero(ppc_state.gpr[m.ra]));
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_EXTSB:
    {
      const MicroOp& m = ops[i];
      ppc_state.gpr[m.rd] = static_cast<u32>(static_cast<s32>(static_cast<s8>(ppc_state.gpr[m.ra])));
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_EXTSH:
    {
      const MicroOp& m = ops[i];
      ppc_state.gpr[m.rd] = static_cast<u32>(static_cast<s32>(static_cast<s16>(ppc_state.gpr[m.ra])));
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_SLW_VAR:
    {
      const MicroOp& m = ops[i];
      const u32 amount = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = (amount & 0x20u) ? 0u : (ppc_state.gpr[m.ra] << (amount & 0x1fu));
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_SRW_VAR:
    {
      const MicroOp& m = ops[i];
      const u32 amount = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = (amount & 0x20u) ? 0u : (ppc_state.gpr[m.ra] >> (amount & 0x1fu));
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_SRAW_VAR:
    {
      const MicroOp& m = ops[i];
      const u32 rb_val = ppc_state.gpr[m.rb];
      if (rb_val & 0x20u)
      {
        if (ppc_state.gpr[m.ra] & 0x80000000u)
        {
          ppc_state.gpr[m.rd] = 0xFFFFFFFFu;
          ppc_state.SetCarry(1);
        }
        else
        {
          ppc_state.gpr[m.rd] = 0x00000000u;
          ppc_state.SetCarry(0);
        }
      }
      else
      {
        const u32 amount = rb_val & 0x1fu;
        const s32 rrs = static_cast<s32>(ppc_state.gpr[m.ra]);
        ppc_state.gpr[m.rd] = static_cast<u32>(rrs >> amount);
        ppc_state.SetCarry(rrs < 0 && amount > 0 && (static_cast<u32>(rrs) << (32 - amount)) != 0);
      }
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_SRAWI_IMM:
    {
      const MicroOp& m = ops[i];
      const u32 amount = m.imm & 31u;
      const s32 rrs = static_cast<s32>(ppc_state.gpr[m.ra]);
      ppc_state.gpr[m.rd] = static_cast<u32>(rrs >> amount);
      ppc_state.SetCarry(rrs < 0 && amount > 0 && (static_cast<u32>(rrs) << (32 - amount)) != 0);
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  // Integer add/sub with carry/overflow semantics
  op_ADD_RR:
    {
      const MicroOp& m = ops[i];
      const u32 a = ppc_state.gpr[m.ra];
      const u32 b = ppc_state.gpr[m.rb];
      const u32 result = a + b;
      ppc_state.gpr[m.rd] = result;
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_ADDC_RR:
    {
      const MicroOp& m = ops[i];
      const u32 a = ppc_state.gpr[m.ra];
      const u32 b = ppc_state.gpr[m.rb];
      const u32 result = a + b;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, b));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_ADDE_RR:
    {
      const MicroOp& m = ops[i];
      const u32 carry = ppc_state.GetCarry();
      const u32 a = ppc_state.gpr[m.ra];
      const u32 b = ppc_state.gpr[m.rb];
      const u32 result = a + b + carry;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, b) || (carry != 0 && CI_Helper_Carry(a + b, carry)));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_ADDME:
    {
      const MicroOp& m = ops[i];
      const u32 carry = ppc_state.GetCarry();
      const u32 a = ppc_state.gpr[m.ra];
      const u32 b = 0xFFFFFFFFu;
      const u32 result = a + b + carry;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, carry - 1));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_ADDZE:
    {
      const MicroOp& m = ops[i];
      const u32 carry = ppc_state.GetCarry();
      const u32 a = ppc_state.gpr[m.ra];
      const u32 result = a + carry;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, carry));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, 0, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_SUBF_RR:
    {
      const MicroOp& m = ops[i];
      const u32 a = ~ppc_state.gpr[m.ra];
      const u32 b = ppc_state.gpr[m.rb];
      const u32 result = a + b + 1u;
      ppc_state.gpr[m.rd] = result;
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_SUBFC_RR:
    {
      const MicroOp& m = ops[i];
      const u32 a = ~ppc_state.gpr[m.ra];
      const u32 b = ppc_state.gpr[m.rb];
      const u32 result = a + b + 1u;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(a == 0xFFFFFFFFu || CI_Helper_Carry(b, a + 1u));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_SUBFE_RR:
    {
      const MicroOp& m = ops[i];
      const u32 a = ~ppc_state.gpr[m.ra];
      const u32 b = ppc_state.gpr[m.rb];
      const u32 carry = ppc_state.GetCarry();
      const u32 result = a + b + carry;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, b) || CI_Helper_Carry(a + b, carry));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_SUBFME:
    {
      const MicroOp& m = ops[i];
      const u32 a = ~ppc_state.gpr[m.ra];
      const u32 b = 0xFFFFFFFFu;
      const u32 carry = ppc_state.GetCarry();
      const u32 result = a + b + carry;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, carry - 1));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_SUBFZE:
    {
      const MicroOp& m = ops[i];
      const u32 a = ~ppc_state.gpr[m.ra];
      const u32 carry = ppc_state.GetCarry();
      const u32 result = a + carry;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, carry));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, 0, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_NOP:
    {
      ++i;
      if (i < count) goto micro_dispatch;
    }

  micro_done:
    ;
  }
#else
  for (u32 i = 0; i < count; ++i)
  {
    const MicroOp& m = ops[i];
    switch (m.op)
    {
    case MicroOpCode::CONST32:
      ppc_state.gpr[m.rd] = m.imm;
      break;
    case MicroOpCode::CONST32_ADDRA:
    {
      const u32 ra_val = ppc_state.gpr[m.ra];
      const s32 hi = static_cast<s16>(static_cast<u32>(m.imm) >> 16);
      const u32 lo = m.imm & 0xFFFFu;
      const u32 upper_add = ra_val + (static_cast<u32>(hi) << 16);
      ppc_state.gpr[m.rd] = upper_add | lo;
      break;
    }
    case MicroOpCode::ADDI:
    {
      const u32 ra_val = (m.ra == 0) ? 0u : ppc_state.gpr[m.ra];
      const s32 simm = static_cast<s32>(static_cast<s16>(m.imm & 0xFFFF));
      ppc_state.gpr[m.rd] = ra_val + static_cast<u32>(simm);
      break;
    }
    case MicroOpCode::ADDIS:
    {
      const u32 ra_val = (m.ra == 0) ? 0u : ppc_state.gpr[m.ra];
      const s32 simm = static_cast<s32>(static_cast<s16>(m.imm & 0xFFFF));
      ppc_state.gpr[m.rd] = ra_val + (static_cast<u32>(simm) << 16);
      break;
    }
    case MicroOpCode::ORI:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 ui = m.imm & 0xFFFFu;
      ppc_state.gpr[m.rd] = rs_val | ui;
      break;
    }
    case MicroOpCode::ORIS:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 ui = (m.imm & 0xFFFFu) << 16;
      ppc_state.gpr[m.rd] = rs_val | ui;
      break;
    }
    case MicroOpCode::XORI:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 ui = m.imm & 0xFFFFu;
      ppc_state.gpr[m.rd] = rs_val ^ ui;
      break;
    }
    case MicroOpCode::XORIS:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 ui = (m.imm & 0xFFFFu) << 16;
      ppc_state.gpr[m.rd] = rs_val ^ ui;
      break;
    }
    case MicroOpCode::ANDI:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 ui = m.imm & 0xFFFFu;
      ppc_state.gpr[m.rd] = rs_val & ui;
      CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::ANDIS:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 ui = (m.imm & 0xFFFFu) << 16;
      ppc_state.gpr[m.rd] = rs_val & ui;
      CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::RLWINM_IMM:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 sh = (m.imm >> 0) & 31u;
      const u32 mb = (m.imm >> 5) & 31u;
      const u32 me = (m.imm >> 10) & 31u;
      const u32 mask = MakeRotationMask(mb, me);
      ppc_state.gpr[m.rd] = std::rotl(rs_val, sh) & mask;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::AND_RR:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = rs_val & rb_val;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::OR_RR:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = rs_val | rb_val;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::XOR_RR:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = rs_val ^ rb_val;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::RLWIMI_IMM:
    {
      const u32 ra_old = ppc_state.gpr[m.rd];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 sh = (m.imm >> 0) & 31u;
      const u32 mb = (m.imm >> 5) & 31u;
      const u32 me = (m.imm >> 10) & 31u;
      const u32 mask = MakeRotationMask(mb, me);
      const u32 rot = std::rotl(rs_val, sh) & mask;
      ppc_state.gpr[m.rd] = (ra_old & ~mask) | rot;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::RLWNM_VAR:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb] & 31u;
      const u32 mb = (m.imm >> 5) & 31u;
      const u32 me = (m.imm >> 10) & 31u;
      const u32 mask = MakeRotationMask(mb, me);
      ppc_state.gpr[m.rd] = std::rotl(rs_val, rb_val) & mask;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::ANDC_RR:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = rs_val & ~rb_val;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::ORC_RR:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = rs_val | ~rb_val;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::NAND_RR:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = ~(rs_val & rb_val);
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::NOR_RR:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = ~(rs_val | rb_val);
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::EQV_RR:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = ~(rs_val ^ rb_val);
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::CNTLZW:
    {
      ppc_state.gpr[m.rd] = static_cast<u32>(std::countl_zero(ppc_state.gpr[m.ra]));
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::EXTSB:
    {
      ppc_state.gpr[m.rd] = static_cast<u32>(static_cast<s32>(static_cast<s8>(ppc_state.gpr[m.ra])));
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::EXTSH:
    {
      ppc_state.gpr[m.rd] = static_cast<u32>(static_cast<s32>(static_cast<s16>(ppc_state.gpr[m.ra])));
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::SLW_VAR:
    {
      const u32 amount = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = (amount & 0x20u) ? 0u : (ppc_state.gpr[m.ra] << (amount & 0x1fu));
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::SRW_VAR:
    {
      const u32 amount = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = (amount & 0x20u) ? 0u : (ppc_state.gpr[m.ra] >> (amount & 0x1fu));
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::SRAW_VAR:
    {
      const u32 rb_val = ppc_state.gpr[m.rb];
      if (rb_val & 0x20u)
      {
        if (ppc_state.gpr[m.ra] & 0x80000000u)
        {
          ppc_state.gpr[m.rd] = 0xFFFFFFFFu;
          ppc_state.SetCarry(1);
        }
        else
        {
          ppc_state.gpr[m.rd] = 0x00000000u;
          ppc_state.SetCarry(0);
        }
      }
      else
      {
        const u32 amount = rb_val & 0x1fu;
        const s32 rrs = static_cast<s32>(ppc_state.gpr[m.ra]);
        ppc_state.gpr[m.rd] = static_cast<u32>(rrs >> amount);
        ppc_state.SetCarry(rrs < 0 && amount > 0 && (static_cast<u32>(rrs) << (32 - amount)) != 0);
      }
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::SRAWI_IMM:
    {
      const u32 amount = m.imm & 31u;
      const s32 rrs = static_cast<s32>(ppc_state.gpr[m.ra]);
      ppc_state.gpr[m.rd] = static_cast<u32>(rrs >> amount);
      ppc_state.SetCarry(rrs < 0 && amount > 0 && (static_cast<u32>(rrs) << (32 - amount)) != 0);
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    // Integer add/sub with carry/overflow semantics
    case MicroOpCode::ADD_RR:
    {
      const u32 a = ppc_state.gpr[m.ra];
      const u32 b = ppc_state.gpr[m.rb];
      const u32 result = a + b;
      ppc_state.gpr[m.rd] = result;
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      break;
    }
    case MicroOpCode::ADDC_RR:
    {
      const u32 a = ppc_state.gpr[m.ra];
      const u32 b = ppc_state.gpr[m.rb];
      const u32 result = a + b;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, b));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      break;
    }
    case MicroOpCode::ADDE_RR:
    {
      const u32 carry = ppc_state.GetCarry();
      const u32 a = ppc_state.gpr[m.ra];
      const u32 b = ppc_state.gpr[m.rb];
      const u32 result = a + b + carry;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, b) || (carry != 0 && CI_Helper_Carry(a + b, carry)));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      break;
    }
    case MicroOpCode::ADDME:
    {
      const u32 carry = ppc_state.GetCarry();
      const u32 a = ppc_state.gpr[m.ra];
      const u32 b = 0xFFFFFFFFu;
      const u32 result = a + b + carry;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, carry - 1));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      break;
    }
    case MicroOpCode::ADDZE:
    {
      const u32 carry = ppc_state.GetCarry();
      const u32 a = ppc_state.gpr[m.ra];
      const u32 result = a + carry;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, carry));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, 0, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      break;
    }
    case MicroOpCode::SUBF_RR:
    {
      const u32 a = ~ppc_state.gpr[m.ra];
      const u32 b = ppc_state.gpr[m.rb];
      const u32 result = a + b + 1u;
      ppc_state.gpr[m.rd] = result;
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      break;
    }
    case MicroOpCode::SUBFC_RR:
    {
      const u32 a = ~ppc_state.gpr[m.ra];
      const u32 b = ppc_state.gpr[m.rb];
      const u32 result = a + b + 1u;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(a == 0xFFFFFFFFu || CI_Helper_Carry(b, a + 1u));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      break;
    }
    case MicroOpCode::SUBFE_RR:
    {
      const u32 a = ~ppc_state.gpr[m.ra];
      const u32 b = ppc_state.gpr[m.rb];
      const u32 carry = ppc_state.GetCarry();
      const u32 result = a + b + carry;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, b) || CI_Helper_Carry(a + b, carry));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      break;
    }
    case MicroOpCode::SUBFME:
    {
      const u32 a = ~ppc_state.gpr[m.ra];
      const u32 b = 0xFFFFFFFFu;
      const u32 carry = ppc_state.GetCarry();
      const u32 result = a + b + carry;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, carry - 1));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      break;
    }
    case MicroOpCode::SUBFZE:
    {
      const u32 a = ~ppc_state.gpr[m.ra];
      const u32 carry = ppc_state.GetCarry();
      const u32 result = a + carry;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, carry));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, 0, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      break;
    }
    case MicroOpCode::NOP:
    default:
      break;
    }
  }
#endif

  // No exceptions/CR updates are modeled here; decoder must only emit safe ops.
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
s32 CachedInterpreter::ExecuteMicroOps(std::ostream& stream,
                                       const ExecuteMicroOpsOperands& operands)
{
  fmt::print(stream, "MicroOps (count={}) at PC={:#010x}\n", operands.count,
             operands.current_pc);
  return sizeof(AnyCallback) + sizeof(operands);
}

// iCube WIN#2 validate (MAIN_CIR_MICROOP_FUSION_VALIDATE). Direct analogue of InterpretSpecialized's
// double-run ALU validate (see ~line 680): the reference here is the REAL generic Interpreter:: handlers
// for the ORIGINAL consumed instructions — NOT the MicroOps — so it catches the case where the fused
// handler's hand-rolled CR0/XER/GPR math diverges from the true interpreter (the Luigi's-Mansion class).
// All packed ops are pure-register (is_simple_mop excludes FL_LOADSTORE/FL_USE_FPU), so double-running
// is side-effect-safe. Run order mirrors specialized: snapshot -> generic reference on live -> capture
// -> restore -> fused dispatch (the SHIPPING path, committed last) -> capture -> assert-compare.
template <bool write_pc>
s32 CachedInterpreter::ExecuteMicroOpsValidate(PowerPC::PowerPCState& ppc_state,
                                               const ExecuteMicroOpsValidateOperands& operands)
{
  const s32 validate_distance = sizeof(AnyCallback) + sizeof(operands);

  // Snapshot the full validated state set (same set the specialized ALU validate uses).
  std::array<u32, 32> saved_gpr;
  std::array<u64, 8> saved_cr;
  std::copy(std::begin(ppc_state.gpr), std::end(ppc_state.gpr), saved_gpr.begin());
  std::copy(std::begin(ppc_state.cr.fields), std::end(ppc_state.cr.fields), saved_cr.begin());
  const u8 saved_xer_ca = ppc_state.xer_ca;
  const u8 saved_xer_so_ov = ppc_state.xer_so_ov;
  const u32 saved_pc = ppc_state.pc;
  const u32 saved_npc = ppc_state.npc;
  const u32 saved_exceptions = ppc_state.Exceptions;

  // GENERIC REFERENCE RUN on the live state: the actual Interpreter:: handlers for the original
  // consumed instructions, in program order. write_pc mirrors Interpret<write_pc> (pc/npc set ONCE at
  // the block-start contract, exactly as the fused CI_SetPCForMicroOps does — not per sub-op).
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  for (u32 k = 0; k < operands.generic_count; ++k)
    operands.generic_func[k](*operands.interpreter, operands.generic_inst[k]);

  std::array<u32, 32> generic_gpr;
  std::array<u64, 8> generic_cr;
  std::copy(std::begin(ppc_state.gpr), std::end(ppc_state.gpr), generic_gpr.begin());
  std::copy(std::begin(ppc_state.cr.fields), std::end(ppc_state.cr.fields), generic_cr.begin());
  const u8 generic_xer_ca = ppc_state.xer_ca;
  const u8 generic_xer_so_ov = ppc_state.xer_so_ov;
  const u32 generic_pc = ppc_state.pc;
  const u32 generic_npc = ppc_state.npc;
  const u32 generic_exceptions = ppc_state.Exceptions;

  // Restore the pre-run state (including Exceptions) so the fused run starts from identical inputs.
  std::copy(saved_gpr.begin(), saved_gpr.end(), std::begin(ppc_state.gpr));
  std::copy(saved_cr.begin(), saved_cr.end(), std::begin(ppc_state.cr.fields));
  ppc_state.xer_ca = saved_xer_ca;
  ppc_state.xer_so_ov = saved_xer_so_ov;
  ppc_state.pc = saved_pc;
  ppc_state.npc = saved_npc;
  ppc_state.Exceptions = saved_exceptions;

  // FUSED RUN — the SHIPPING path, run LAST so its result is what stays committed (exactly as the
  // specialized validate leaves the specialized result committed). Reuse the real ExecuteMicroOps by
  // forwarding the fused half of the payload, so the dispatch under test is byte-identical to ship.
  ExecuteMicroOpsOperands fused{};
  fused.count = operands.count;
  fused.current_pc = operands.current_pc;
  std::copy(std::begin(operands.ops), std::begin(operands.ops) + operands.count, std::begin(fused.ops));
  ExecuteMicroOps<write_pc>(ppc_state, fused);

  std::array<u32, 32> fused_gpr;
  std::array<u64, 8> fused_cr;
  std::copy(std::begin(ppc_state.gpr), std::end(ppc_state.gpr), fused_gpr.begin());
  std::copy(std::begin(ppc_state.cr.fields), std::end(ppc_state.cr.fields), fused_cr.begin());

  ASSERT_MSG(DYNA_REC, fused_gpr == generic_gpr,
             "CIR micro-op fusion GPR mismatch at pc {:#x} (count={}, generic_count={})",
             operands.current_pc, operands.count, operands.generic_count);
  ASSERT_MSG(DYNA_REC, fused_cr == generic_cr,
             "CIR micro-op fusion CR mismatch at pc {:#x}", operands.current_pc);
  ASSERT_MSG(DYNA_REC,
             ppc_state.xer_ca == generic_xer_ca && ppc_state.xer_so_ov == generic_xer_so_ov,
             "CIR micro-op fusion XER mismatch at pc {:#x}", operands.current_pc);
  ASSERT_MSG(DYNA_REC, ppc_state.pc == generic_pc && ppc_state.npc == generic_npc,
             "CIR micro-op fusion PC/NPC mismatch at pc {:#x}", operands.current_pc);
  ASSERT_MSG(DYNA_REC, ppc_state.Exceptions == generic_exceptions,
             "CIR micro-op fusion Exceptions mismatch at pc {:#x} ({:#x} vs generic {:#x})",
             operands.current_pc, ppc_state.Exceptions, generic_exceptions);

  return validate_distance;
}

template <bool write_pc>
s32 CachedInterpreter::ExecuteMicroOpsValidate(std::ostream& stream,
                                               const ExecuteMicroOpsValidateOperands& operands)
{
  fmt::print(stream, "MicroOpsValidate (count={}, generic_count={}) at PC={:#010x}\n", operands.count,
             operands.generic_count, operands.current_pc);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreter::HLEFunction(PowerPC::PowerPCState& ppc_state,
                                   const HLEFunctionOperands& operands)
{
  const auto& [system, current_pc, hook_index] = operands;
  ppc_state.pc = current_pc;
  HLE::Execute(Core::CPUThreadGuard{system}, current_pc, hook_index);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreter::WriteBrokenBlockNPC(PowerPC::PowerPCState& ppc_state,
                                           const WriteBrokenBlockNPCOperands& operands)
{
  const auto& [current_pc] = operands;
  ppc_state.npc = current_pc;
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreter::CheckFPU(PowerPC::PowerPCState& ppc_state, const CheckHaltOperands& operands)
{
  const auto& [power_pc, current_pc, downcount] = operands;
  if (!ppc_state.msr.FP)
  {
    ppc_state.pc = current_pc;
    ppc_state.downcount -= downcount;
    ppc_state.Exceptions |= EXCEPTION_FPU_UNAVAILABLE;
    power_pc.CheckExceptions();
    return 0;
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreter::CheckBreakpoint(PowerPC::PowerPCState& ppc_state,
                                       const CheckHaltOperands& operands)
{
  const auto& [power_pc, current_pc, downcount] = operands;
  ppc_state.pc = current_pc;
  if (power_pc.CheckAndHandleBreakPoints())
  {
    // Accessing PowerPCState through power_pc instead of ppc_state produces better assembly.
    power_pc.GetPPCState().downcount -= downcount;
    return 0;
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreter::CheckIdle(PowerPC::PowerPCState& ppc_state,
                                 const CheckIdleOperands& operands)
{
  const auto& [core_timing, idle_pc] = operands;
  if (ppc_state.npc == idle_pc)
    core_timing.Idle();
  return sizeof(AnyCallback) + sizeof(operands);
}

// Fast-forward CTR-only tight idle loops: when at the loop branch PC, force loop exit and yield.
s32 CachedInterpreter::FastForwardCtrIdle(PowerPC::PowerPCState& ppc_state,
                                          const CheckCtrIdleOperands& operands)
{
  const auto& [core_timing, idle_pc, fallthrough_pc] = operands;
  if (ppc_state.npc == idle_pc)
  {
    // Force CTR exhaustion and take the fallthrough.
    CTR(ppc_state) = 0;
    ppc_state.pc = idle_pc;
    ppc_state.npc = fallthrough_pc;
    core_timing.Idle();
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

bool CachedInterpreter::HandleFunctionHooking(u32 address)
{
  // CachedInterpreter inherits from JitBase and is considered a JIT by relevant code.
  // (see JitInterface and how m_mode is set within PowerPC.cpp)
  const auto result = HLE::TryReplaceFunction(m_ppc_symbol_db, address, PowerPC::CoreMode::JIT);
  if (!result)
    return false;

  Write(HLEFunction, {m_system, address, result.hook_index});

  if (result.type != HLE::HookType::Replace)
    return false;

  js.downcountAmount += js.st.numCycles;
  WriteEndBlock();
  return true;
}

void CachedInterpreter::WriteEndBlock(u32 link_target)
{
  // iCube: linkable IFF all hold: feature on; not profiling (the link trampoline is unprofiled);
  // not debugging (breakpoints/stepping must round-trip the dispatcher so a single ExecuteOneBlock
  // never runs a whole chain past a breakpoint); and the terminal is a STATIC direct branch
  // (link_target != UINT32_MAX). The last gate is the EE/MSR-safety invariant: only bx/bcx set a real
  // op.branchTo (PPCAnalyst.cpp), so sc/rfi/bclr/bcctr/broken-block/HLE-replace (all UINT32_MAX or
  // never passing a target) are excluded and keep their plain EndBlock — we never link past a terminal
  // that can change MSR/feature_flags or toggle EE without the dispatcher getting a turn.
  const bool linkable = s_block_linking && !IsProfilingEnabled() && !IsDebuggingEnabled() &&
                        link_target != 0xFFFFFFFF;

  if (!linkable)
  {
    // iCube: 4th field is the block ENTRY PC (js.blockStart) for the hot-block profiler. Written
    // unconditionally (the slot was formerly anonymous padding); zero layout/size delta.
    if (IsProfilingEnabled())
    {
      Write(EndBlock<true>,
            {{js.downcountAmount, js.numLoadStoreInst, js.numFloatingPointInst, js.blockStart},
             js.curBlock->profile_data.get()});
    }
    else
    {
      Write(EndBlock<false>,
            {js.downcountAmount, js.numLoadStoreInst, js.numFloatingPointInst, js.blockStart});
    }
    return;
  }

  // Emit the link trampoline. rel starts at 0 (unlinked); the upstream machinery patches it via
  // CachedInterpreterBlockCache::WriteLinkBlock once the target block exists, and clears it back to 0
  // on UnlinkBlock/DestroyBlock. expected_pc is the static target; npc must equal it at runtime to
  // follow the link.
  const LinkBlockOperands operands = {js.downcountAmount,
                                      js.numLoadStoreInst,
                                      js.numFloatingPointInst,
                                      link_target,
                                      static_cast<u32>(js.curBlock->feature_flags),
                                      0,
                                      js.blockStart};  // iCube: entry PC for the hot-block profiler
  // exitPtrs must point at the AnyCallback slot (start of this callback), so WriteLinkBlock can
  // compute rel = dest->normalEntry - exitPtrs and LinkBlock recovers the same callback_site.
  u8* const callback_site = GetWritableCodePtr();
  Write(LinkBlock, operands);

  // Record the exit so the upstream linker (FinalizeBlock(block_link) -> LinkBlock -> LinkBlockExits)
  // resolves and patches it, and so DestroyBlock -> UnlinkBlock unpatches it on invalidation. One
  // LinkData per block (single static target) — deliberately NOT the old two-slot-per-exit scheme
  // that mismatched WriteLinkBlock's clear/set discrimination.
  JitBlock::LinkData ld{};
  ld.exitPtrs = callback_site;
#ifdef _M_ARM_64
  ld.exitFarcode = nullptr;
#endif
  ld.exitAddress = link_target;
  ld.linkStatus = false;
  ld.call = false;
  js.curBlock->linkData.push_back(ld);
}

bool CachedInterpreter::SetEmitterStateToFreeCodeRegion()
{
  const auto free = m_free_ranges.by_size_begin();
  if (free == m_free_ranges.by_size_end())
  {
    WARN_LOG_FMT(DYNA_REC, "Failed to find free memory region in code region.");
    return false;
  }
  SetCodePtr(free.from(), free.to());
  return true;
}

void CachedInterpreter::FreeRanges()
{
  for (const auto& [from, to] : m_block_cache.GetRangesToFree())
    m_free_ranges.insert(from, to);
  m_block_cache.ClearRangesToFree();
}

void CachedInterpreter::ResetFreeMemoryRanges()
{
  m_free_ranges.clear();
  m_free_ranges.insert(region, region + region_size);
}

void CachedInterpreter::Jit(u32 em_address)
{
  Jit(em_address, true);
}

void CachedInterpreter::Jit(u32 em_address, bool clear_cache_and_retry_on_failure)
{
  if (IsAlmostFull() || SConfig::GetInstance().bJITNoBlockCache)
  {
    ClearCache();
  }
  FreeRanges();

  const u32 nextPC =
      analyzer.Analyze(em_address, &code_block, &m_code_buffer, m_code_buffer.size());
  if (code_block.m_memory_exception)
  {
    // Address of instruction could not be translated
    m_ppc_state.npc = nextPC;
    m_ppc_state.Exceptions |= EXCEPTION_ISI;
    m_system.GetPowerPC().CheckExceptions();
    WARN_LOG_FMT(POWERPC, "ISI exception at {:#010x}", nextPC);
    return;
  }

  if (SetEmitterStateToFreeCodeRegion())
  {
    JitBlock* b = m_block_cache.AllocateBlock(em_address);
    b->normalEntry = b->near_begin = GetWritableCodePtr();

    if (DoJit(em_address, b, nextPC))
    {
      // Record what memory region was used so we know what to free if this block gets invalidated.
      b->near_end = GetWritableCodePtr();
      b->far_begin = b->far_end = nullptr;

      // Mark the memory region that this code block uses in the RangeSizeSet.
      if (b->near_begin != b->near_end)
        m_free_ranges.erase(b->near_begin, b->near_end);

      m_block_cache.FinalizeBlock(*b, jo.enableBlocklink, code_block, m_code_buffer);

#ifdef JIT_LOG_GENERATED_CODE
      LogGeneratedCode();
#endif

      return;
    }
  }

  if (clear_cache_and_retry_on_failure)
  {
    WARN_LOG_FMT(DYNA_REC, "flushing code caches, please report if this happens a lot");
    ClearCache();
    Jit(em_address, false);
    return;
  }

  PanicAlertFmtT("JIT failed to find code space after a cache clear. This should never happen. "
                 "Please report this incident on the bug tracker. Dolphin will now exit.");
  std::exit(-1);
}

bool CachedInterpreter::DoJit(u32 em_address, JitBlock* b, u32 nextPC)
{
  js.blockStart = em_address;
  js.firstFPInstructionFound = false;
  js.fifoBytesSinceCheck = 0;
  js.downcountAmount = 0;
  js.numLoadStoreInst = 0;
  js.numFloatingPointInst = 0;
  js.curBlock = b;

  auto& interpreter = m_system.GetInterpreter();
  auto& power_pc = m_system.GetPowerPC();
  auto& cpu = m_system.GetCPU();
  auto& breakpoints = power_pc.GetBreakPoints();

  if (IsProfilingEnabled())
    Write(StartProfiledBlock, {js.curBlock->profile_data.get()});

  for (u32 i = 0; i < code_block.m_num_instructions; i++)
  {
    PPCAnalyst::CodeOp& op = m_code_buffer[i];
    js.op = &op;

    js.compilerPC = op.address;
    js.instructionsLeft = (code_block.m_num_instructions - 1) - i;
    js.downcountAmount += op.opinfo->num_cycles;
    if (op.opinfo->flags & FL_LOADSTORE)
      ++js.numLoadStoreInst;
    if (op.opinfo->flags & FL_USE_FPU)
      ++js.numFloatingPointInst;

    if (HandleFunctionHooking(js.compilerPC))
      break;

    if (!op.skip)
    {
      if (IsDebuggingEnabled() && !cpu.IsStepping() &&
          breakpoints.IsAddressBreakPoint(js.compilerPC))
      {
        Write(CheckBreakpoint, {power_pc, js.compilerPC, js.downcountAmount});
      }
      if (!js.firstFPInstructionFound && (op.opinfo->flags & FL_USE_FPU) != 0)
      {
        Write(CheckFPU, {power_pc, js.compilerPC, js.downcountAmount});
        js.firstFPInstructionFound = true;
      }

      // Instruction may cause a DSI Exception or Program Exception.
      if ((jo.memcheck && (op.opinfo->flags & FL_LOADSTORE) != 0) ||
          (!op.canEndBlock && ShouldHandleFPExceptionForInstruction(&op)))
      {
        const InterpretAndCheckExceptionsOperands operands = {
            {interpreter, Interpreter::GetInterpreterOp(op.inst), js.compilerPC, op.inst},
            power_pc,
            js.downcountAmount};
        Write(op.canEndBlock ? CallbackCast(InterpretAndCheckExceptions<true>) :
                               CallbackCast(InterpretAndCheckExceptions<false>),
              operands);
      }
      else
      {
        // iCube WIN#2: micro-op fusion + CONST32 folding (MAIN_CIR_MICROOP_FUSION). Tried FIRST, gated
        // entirely on the flag — when OFF this whole block is skipped and DoJit is byte-identical to
        // upstream. Recognizes (a) the addis/ori CONST32 idiom and (b) runs of fusable pure-register
        // integer/immediate ALU ops, emitting ONE ExecuteMicroOps callback for the run. On success it
        // advances `i` to the LAST consumed op and `continue`s, so the outer loop's ++i lands on the
        // next unconsumed op. CRITICAL re-graft vs the good branch: we HARD-STOP before packing any
        // op.canEndBlock terminal (never pack-then-break), so a terminal always gets its own iteration
        // and the WIN#4 WriteEndBlock(op.branchTo) / idle-loop handling below still fires unchanged.
        // FL_LOADSTORE/FL_USE_FPU and op.skip ops are excluded by is_simple_mop, so numLoadStore/numFP
        // accounting is untouched. Cycle accounting: the outer loop already charged op[i]; the fusion
        // code charges each ADDITIONAL consumed op exactly once (guarded by `if (j != i)` / the fold
        // loops' explicit `+=`), so the slice downcount matches the unfused path op-for-op.
        if (s_microop_fusion && !op.canEndBlock)
        {
          auto is_simple_mop = [](const UGeckoInstruction& ins) -> bool {
            switch (ins.OPCD)
            {
            case 10:  // cmpli
            case 11:  // cmpi
            case 14:  // addi
            case 15:  // addis
            case 20:  // rlwimix
            case 21:  // rlwinm / rlwinm.
            case 23:  // rlwnmx
            case 24:  // ori
            case 25:  // oris
            case 26:  // xori
            case 27:  // xoris
            case 28:  // andi.
            case 29:  // andis.
              return true;
            case 31:  // X-form logical reg-reg and/or/xor + arithmetic
              switch (ins.SUBOP10)
              {
              case 0:    // cmp
              case 32:   // cmpl
              case 28:   // andx
              case 444:  // orx
              case 316:  // xorx
              case 60:   // andcx
              case 412:  // orcx
              case 476:  // nandx
              case 124:  // norx
              case 284:  // eqvx
              case 266:  // addx
              case 778:  // addox
              case 10:   // addcx
              case 522:  // addcox
              case 138:  // addex
              case 650:  // addeox
              case 234:  // addmex
              case 746:  // addmeox
              case 202:  // addzex
              case 714:  // addzeox
              case 40:   // subfx
              case 552:  // subfox
              case 8:    // subfcx
              case 520:  // subfcox
              case 136:  // subfex
              case 648:  // subfeox
              case 232:  // subfmex
              case 744:  // subfmeox
              case 200:  // subfzex
              case 712:  // subfzeox
              case 26:   // cntlzwx
              case 954:  // extsbx
              case 922:  // extshx
              case 24:   // slwx
              case 536:  // srwx
              case 792:  // srawx
              case 824:  // srawix
                return true;
              default:
                return false;
              }
            default:
              return false;
            }
          };

          // iCube WIN#2 validate: single emit point for a fused run, so the lean-vs-validate choice
          // can't drift across the three packer sites (CONST32 / CONST32_ADDRA / ALU run). [first_idx,
          // last_idx] is the CONTIGUOUS, COMPLETE range of ORIGINAL consumed instructions (the packer
          // never skips-and-continues; every stop ends the run and the force-stop default backs the op
          // out of last_consumed). When validate is OFF this emits the byte-identical lean
          // ExecuteMicroOps; when ON it additionally captures each non-skip original (func, inst) as the
          // generic-interpreter reference and emits ExecuteMicroOpsValidate. All packed ops are
          // non-terminal (canEndBlock hard-stops the run), so write_pc is always false here.
          auto emit_fused = [&](const ExecuteMicroOpsOperands& mop, u32 first_idx, u32 last_idx) {
            if (!s_microop_fusion_validate)
            {
              Write(CallbackCast(ExecuteMicroOps<false>), mop);
              return;
            }
            ExecuteMicroOpsValidateOperands vop{};
            vop.count = mop.count;
            std::copy(std::begin(mop.ops), std::begin(mop.ops) + mop.count, std::begin(vop.ops));
            vop.current_pc = mop.current_pc;
            vop.interpreter = &interpreter;
            vop.generic_count = 0;
            for (u32 g = first_idx; g <= last_idx &&
                                    vop.generic_count < ExecuteMicroOpsValidateOperands::kMaxOps;
                 ++g)
            {
              const PPCAnalyst::CodeOp& orig = m_code_buffer[g];
              if (orig.skip)
                continue;
              vop.generic_func[vop.generic_count] = Interpreter::GetInterpreterOp(orig.inst);
              vop.generic_inst[vop.generic_count] = orig.inst;
              ++vop.generic_count;
            }
            Write(CallbackCast(ExecuteMicroOpsValidate<false>), vop);
          };

          // (a) CONST32: addis rt,r0,hi; ori rt,rt,lo  => rt = (hi<<16)|lo. Both ops are non-terminal
          // (ori never ends a block; addis here has RA==0). The next op (ori) must also be present and
          // non-LS/non-FP/non-skip. We never reach here if op.canEndBlock (guarded above).
          if (op.inst.OPCD == 15 /*addis*/ && op.inst.RA == 0 &&
              (i + 1) < code_block.m_num_instructions)
          {
            PPCAnalyst::CodeOp& op2 = m_code_buffer[i + 1];
            if (!op2.skip && (op2.opinfo->flags & (FL_LOADSTORE | FL_USE_FPU)) == 0 &&
                op2.inst.OPCD == 24 /*ori*/ && op2.inst.RA == op.inst.RD &&
                op2.inst.RS == op.inst.RD)
            {
              ExecuteMicroOpsOperands mop{};
              mop.count = 1;
              mop.current_pc = js.compilerPC;
              MicroOp& mu = mop.ops[0];
              mu.op = MicroOpCode::CONST32;
              mu.rd = op.inst.RD;
              const u32 hi = static_cast<u32>(static_cast<s16>(op.inst.SIMM_16));
              const u32 lo = static_cast<u32>(op2.inst.UIMM & 0xFFFFu);
              mu.imm = (hi << 16) | lo;

              js.downcountAmount += op2.opinfo->num_cycles;  // op[i] (addis) charged at loop top
              emit_fused(mop, i, i + 1);  // consumes addis (op[i]) + ori (op[i+1]); neither ends block
              i += 1;       // consume op2; outer ++i lands past it
              continue;
            }
          }

          // (b) CONST32_ADDRA: addis rt,ra,hi; ori rt,rt,lo  => rt = GPR[ra] + ((hi<<16)|lo).
          if (op.inst.OPCD == 15 /*addis*/ && op.inst.RA != 0 &&
              (i + 1) < code_block.m_num_instructions)
          {
            PPCAnalyst::CodeOp& op2 = m_code_buffer[i + 1];
            if (!op2.skip && (op2.opinfo->flags & (FL_LOADSTORE | FL_USE_FPU)) == 0 &&
                op2.inst.OPCD == 24 /*ori*/ && op2.inst.RA == op.inst.RD &&
                op2.inst.RS == op.inst.RD)
            {
              ExecuteMicroOpsOperands mop{};
              mop.count = 1;
              mop.current_pc = js.compilerPC;
              MicroOp& mu = mop.ops[0];
              mu.op = MicroOpCode::CONST32_ADDRA;
              mu.rd = op.inst.RD;
              mu.ra = op.inst.RA;
              const u32 hi = static_cast<u32>(static_cast<s16>(op.inst.SIMM_16));
              const u32 lo = static_cast<u32>(op2.inst.UIMM & 0xFFFFu);
              mu.imm = (hi << 16) | lo;

              js.downcountAmount += op2.opinfo->num_cycles;
              emit_fused(mop, i, i + 1);  // consumes addis (op[i]) + ori (op[i+1])
              i += 1;
              continue;
            }
          }

          // (c) Pack a run of simple ALU ops into one ExecuteMicroOps. We never start a run on a
          // terminal (guarded above) and HARD-STOP before packing any canEndBlock op, so the terminal
          // is left for its own iteration.
          if (is_simple_mop(op.inst))
          {
            ExecuteMicroOpsOperands mop{};
            mop.count = 0;
            mop.current_pc = js.compilerPC;
            u32 last_consumed = i;

            for (u32 j = i; j < code_block.m_num_instructions &&
                            mop.count < ExecuteMicroOpsOperands::kMaxOps;
                 ++j)
            {
              PPCAnalyst::CodeOp& next = m_code_buffer[j];
              // Capture the primary op index BEFORE the ori/oris/xori/xoris fold loops advance j.
              // `next` is a reference bound at j==j_start and does NOT rebind when a fold mutates j, so
              // the post-switch cycle charge must key on j_start (not the moved j) to avoid charging
              // op[j_start] twice. Folded ops are charged inside the fold loop; op[i] at the loop top.
              const u32 j_start = j;
              // iCube WIN#2 validate cap: the validate operands carry ONE (func,inst) reference slot per
              // ORIGINAL consumed instruction, and folds (ori/oris/xori/xoris) consume MANY originals per
              // MicroOp — so the consumed-original span (j - i + 1), NOT mop.count, is what can overflow
              // generic_func[kMaxOps]. GATED on the validate flag so the lean (fusion-on/validate-off)
              // shipping path is byte-identical to before — only a validate session pays the run-split.
              // The fold loops below carry the same (jj - i) bound, identically gated.
              if (s_microop_fusion_validate && (j - i) >= ExecuteMicroOpsValidateOperands::kMaxOps)
                break;  // consumed-original span is full; leave the rest for the next iteration
              if (next.skip || (next.opinfo->flags & (FL_LOADSTORE | FL_USE_FPU)) != 0 ||
                  !is_simple_mop(next.inst) || next.canEndBlock)
              {
                break;  // hard stop: terminal / LS / FP / skip / non-simple ends the run
              }

              MicroOp& mu = mop.ops[mop.count++];
              switch (next.inst.OPCD)
              {
              case 10:  // cmpli
              {
                mu.op = MicroOpCode::CMPL_U_IMM;
                mu.rd = next.inst.CRFD;
                mu.ra = next.inst.RA;
                mu.rb = 0;
                mu.rc = 0;
                mu.imm = next.inst.UIMM;
                goto end_pack_switch;
              }
              case 11:  // cmpi
              {
                mu.op = MicroOpCode::CMP_S_IMM;
                mu.rd = next.inst.CRFD;
                mu.ra = next.inst.RA;
                mu.rb = 0;
                mu.rc = 0;
                mu.imm = static_cast<u16>(next.inst.SIMM_16);  // keep 16-bit immediate
                goto end_pack_switch;
              }
              case 14:  // addi
                mu.op = MicroOpCode::ADDI;
                mu.rd = next.inst.RD;  // RT
                mu.ra = next.inst.RA;  // RA (0 allowed)
                mu.imm = static_cast<u32>(next.inst.SIMM_16);
                break;
              case 15:  // addis
                mu.op = MicroOpCode::ADDIS;
                mu.rd = next.inst.RD;
                mu.ra = next.inst.RA;
                mu.imm = static_cast<u32>(next.inst.SIMM_16);
                break;
              case 20:  // rlwimix
                mu.op = MicroOpCode::RLWIMI_IMM;
                mu.rd = next.inst.RA;  // destination RA
                mu.ra = next.inst.RS;  // source RS
                mu.rb = 0;
                mu.rc = static_cast<u8>(next.inst.Rc);
                // Pack SH/MB/ME into imm: [0..4]=SH, [5..9]=MB, [10..14]=ME
                mu.imm = (static_cast<u32>(next.inst.SH) & 31u) |
                         ((static_cast<u32>(next.inst.MB) & 31u) << 5) |
                         ((static_cast<u32>(next.inst.ME) & 31u) << 10);
                break;
              case 21:  // rlwinm/rlwinm.
                mu.op = MicroOpCode::RLWINM_IMM;
                mu.rd = next.inst.RA;  // destination RA
                mu.ra = next.inst.RS;  // source RS
                mu.rb = 0;
                mu.rc = static_cast<u8>(next.inst.Rc);
                mu.imm = (static_cast<u32>(next.inst.SH) & 31u) |
                         ((static_cast<u32>(next.inst.MB) & 31u) << 5) |
                         ((static_cast<u32>(next.inst.ME) & 31u) << 10);
                {
                  // NOP elimination: rlwinm rA,rA,0,0,31 with Rc==0
                  const bool is_identity = (next.inst.SH & 31u) == 0 && (next.inst.MB & 31u) == 0 &&
                                           (next.inst.ME & 31u) == 31 &&
                                           next.inst.RA == next.inst.RS && next.inst.Rc == 0;
                  if (is_identity)
                  {
                    --mop.count;  // drop this op from the batch
                    goto end_pack_switch;
                  }
                }
                break;
              case 23:  // rlwnmx
                mu.op = MicroOpCode::RLWNM_VAR;
                mu.rd = next.inst.RA;  // destination RA
                mu.ra = next.inst.RS;  // source RS
                mu.rb = next.inst.RB;  // variable shift from RB
                mu.rc = static_cast<u8>(next.inst.Rc);
                // Pack MB/ME into imm: [5..9]=MB, [10..14]=ME (SH is variable from RB)
                mu.imm = ((static_cast<u32>(next.inst.MB) & 31u) << 5) |
                         ((static_cast<u32>(next.inst.ME) & 31u) << 10);
                break;
              case 24:  // ori
                mu.op = MicroOpCode::ORI;
                mu.rd = next.inst.RA;  // destination is RA
                mu.ra = next.inst.RS;  // source is RS
                mu.imm = static_cast<u32>(next.inst.UIMM);
                {
                  // NOP elimination: ori rA,rA,0
                  if (next.inst.RA == next.inst.RS && (next.inst.UIMM & 0xFFFFu) == 0)
                  {
                    --mop.count;
                    goto end_pack_switch;
                  }
                  // Fold consecutive ori RA, RA, uimm
                  const u8 rt = next.inst.RA;
                  const u8 rs = next.inst.RS;
                  u32 combined = mu.imm & 0xFFFFu;
                  u32 jj = j + 1;
                  // (jj - i) bound: keep the consumed-original span within the validate reference array.
                  // GATED on the validate flag so the lean shipping fold is byte-identical to before.
                  while (jj < code_block.m_num_instructions &&
                         (!s_microop_fusion_validate ||
                          (jj - i) < ExecuteMicroOpsValidateOperands::kMaxOps))
                  {
                    PPCAnalyst::CodeOp& n2 = m_code_buffer[jj];
                    if (n2.skip || (n2.opinfo->flags & (FL_LOADSTORE | FL_USE_FPU)) != 0 ||
                        !is_simple_mop(n2.inst) || n2.canEndBlock)
                      break;
                    if (n2.inst.OPCD != 24 /*ori*/ || n2.inst.RA != rt || n2.inst.RS != rs)
                      break;
                    combined |= static_cast<u32>(n2.inst.UIMM & 0xFFFFu);
                    js.downcountAmount += n2.opinfo->num_cycles;
                    j = jj;  // consume
                    ++jj;
                  }
                  mu.imm = combined;
                }
                break;
              case 25:  // oris
                mu.op = MicroOpCode::ORIS;
                mu.rd = next.inst.RA;  // destination is RA
                mu.ra = next.inst.RS;  // source is RS
                mu.imm = static_cast<u32>(next.inst.UIMM);
                {
                  // NOP elimination: oris rA,rA,0
                  if (next.inst.RA == next.inst.RS && (next.inst.UIMM & 0xFFFFu) == 0)
                  {
                    --mop.count;
                    goto end_pack_switch;
                  }
                  // Fold consecutive oris RA, RA, uimm
                  const u8 rt = next.inst.RA;
                  const u8 rs = next.inst.RS;
                  u32 combined = mu.imm & 0xFFFFu;
                  u32 jj = j + 1;
                  // (jj - i) bound: keep the consumed-original span within the validate reference array.
                  // GATED on the validate flag so the lean shipping fold is byte-identical to before.
                  while (jj < code_block.m_num_instructions &&
                         (!s_microop_fusion_validate ||
                          (jj - i) < ExecuteMicroOpsValidateOperands::kMaxOps))
                  {
                    PPCAnalyst::CodeOp& n2 = m_code_buffer[jj];
                    if (n2.skip || (n2.opinfo->flags & (FL_LOADSTORE | FL_USE_FPU)) != 0 ||
                        !is_simple_mop(n2.inst) || n2.canEndBlock)
                      break;
                    if (n2.inst.OPCD != 25 /*oris*/ || n2.inst.RA != rt || n2.inst.RS != rs)
                      break;
                    combined |= static_cast<u32>(n2.inst.UIMM & 0xFFFFu);
                    js.downcountAmount += n2.opinfo->num_cycles;
                    j = jj;
                    ++jj;
                  }
                  mu.imm = combined;
                }
                break;
              case 26:  // xori
                mu.op = MicroOpCode::XORI;
                mu.rd = next.inst.RA;  // destination is RA
                mu.ra = next.inst.RS;  // source is RS
                mu.imm = static_cast<u32>(next.inst.UIMM);
                {
                  // NOP elimination: xori rA,rA,0
                  if (next.inst.RA == next.inst.RS && (next.inst.UIMM & 0xFFFFu) == 0)
                  {
                    --mop.count;
                    goto end_pack_switch;
                  }
                  // Fold consecutive xori RA, RA, uimm
                  const u8 rt = next.inst.RA;
                  const u8 rs = next.inst.RS;
                  u32 combined = mu.imm & 0xFFFFu;
                  u32 jj = j + 1;
                  // (jj - i) bound: keep the consumed-original span within the validate reference array.
                  // GATED on the validate flag so the lean shipping fold is byte-identical to before.
                  while (jj < code_block.m_num_instructions &&
                         (!s_microop_fusion_validate ||
                          (jj - i) < ExecuteMicroOpsValidateOperands::kMaxOps))
                  {
                    PPCAnalyst::CodeOp& n2 = m_code_buffer[jj];
                    if (n2.skip || (n2.opinfo->flags & (FL_LOADSTORE | FL_USE_FPU)) != 0 ||
                        !is_simple_mop(n2.inst) || n2.canEndBlock)
                      break;
                    if (n2.inst.OPCD != 26 /*xori*/ || n2.inst.RA != rt || n2.inst.RS != rs)
                      break;
                    combined ^= static_cast<u32>(n2.inst.UIMM & 0xFFFFu);
                    js.downcountAmount += n2.opinfo->num_cycles;
                    j = jj;
                    ++jj;
                  }
                  mu.imm = combined;
                }
                break;
              case 27:  // xoris
                mu.op = MicroOpCode::XORIS;
                mu.rd = next.inst.RA;  // destination is RA
                mu.ra = next.inst.RS;  // source is RS
                mu.imm = static_cast<u32>(next.inst.UIMM);
                {
                  // NOP elimination: xoris rA,rA,0
                  if (next.inst.RA == next.inst.RS && (next.inst.UIMM & 0xFFFFu) == 0)
                  {
                    --mop.count;
                    goto end_pack_switch;
                  }
                  // Fold consecutive xoris RA, RA, uimm
                  const u8 rt = next.inst.RA;
                  const u8 rs = next.inst.RS;
                  u32 combined = mu.imm & 0xFFFFu;
                  u32 jj = j + 1;
                  // (jj - i) bound: keep the consumed-original span within the validate reference array.
                  // GATED on the validate flag so the lean shipping fold is byte-identical to before.
                  while (jj < code_block.m_num_instructions &&
                         (!s_microop_fusion_validate ||
                          (jj - i) < ExecuteMicroOpsValidateOperands::kMaxOps))
                  {
                    PPCAnalyst::CodeOp& n2 = m_code_buffer[jj];
                    if (n2.skip || (n2.opinfo->flags & (FL_LOADSTORE | FL_USE_FPU)) != 0 ||
                        !is_simple_mop(n2.inst) || n2.canEndBlock)
                      break;
                    if (n2.inst.OPCD != 27 /*xoris*/ || n2.inst.RA != rt || n2.inst.RS != rs)
                      break;
                    combined ^= static_cast<u32>(n2.inst.UIMM & 0xFFFFu);
                    js.downcountAmount += n2.opinfo->num_cycles;
                    j = jj;
                    ++jj;
                  }
                  mu.imm = combined;
                }
                break;
              case 28:  // andi.
                mu.op = MicroOpCode::ANDI;
                mu.rd = next.inst.RA;  // destination is RA (recording variant)
                mu.ra = next.inst.RS;  // source is RS
                mu.imm = static_cast<u32>(next.inst.UIMM);
                break;
              case 29:  // andis.
                mu.op = MicroOpCode::ANDIS;
                mu.rd = next.inst.RA;  // destination is RA (recording variant)
                mu.ra = next.inst.RS;  // source is RS
                mu.imm = static_cast<u32>(next.inst.UIMM);
                break;
              case 31:  // X-form logicals/shifts/misc
              {
                switch (next.inst.SUBOP10)
                {
                case 0:  // cmp
                {
                  mu.op = MicroOpCode::CMP_S_RR;
                  mu.rd = next.inst.CRFD;
                  mu.ra = next.inst.RA;
                  mu.rb = next.inst.RB;
                  mu.rc = 0;
                  mu.imm = 0;
                  goto end_pack_switch;
                }
                case 32:  // cmpl
                {
                  mu.op = MicroOpCode::CMPL_U_RR;
                  mu.rd = next.inst.CRFD;
                  mu.ra = next.inst.RA;
                  mu.rb = next.inst.RB;
                  mu.rc = 0;
                  mu.imm = 0;
                  goto end_pack_switch;
                }
                case 28:  // andx
                  mu.op = MicroOpCode::AND_RR;
                  break;
                case 444:  // orx
                  mu.op = MicroOpCode::OR_RR;
                  break;
                case 316:  // xorx
                  mu.op = MicroOpCode::XOR_RR;
                  break;
                case 60:  // andcx
                  mu.op = MicroOpCode::ANDC_RR;
                  break;
                case 412:  // orcx
                  mu.op = MicroOpCode::ORC_RR;
                  break;
                case 476:  // nandx
                  mu.op = MicroOpCode::NAND_RR;
                  break;
                case 124:  // norx
                  mu.op = MicroOpCode::NOR_RR;
                  break;
                case 284:  // eqvx
                  mu.op = MicroOpCode::EQV_RR;
                  break;
                case 266:  // addx
                case 778:  // addox (OE)
                {
                  mu.op = MicroOpCode::ADD_RR;
                  mu.rd = next.inst.RD;
                  mu.ra = next.inst.RA;
                  mu.rb = next.inst.RB;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = (next.inst.SUBOP10 == 778) ? 1u : 0u;  // imm bit0 -> OE
                  goto end_pack_switch;
                }
                case 10:   // addcx
                case 522:  // addcox (OE)
                {
                  mu.op = MicroOpCode::ADDC_RR;
                  mu.rd = next.inst.RD;
                  mu.ra = next.inst.RA;
                  mu.rb = next.inst.RB;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = (next.inst.SUBOP10 == 522) ? 1u : 0u;
                  goto end_pack_switch;
                }
                case 138:  // addex
                case 650:  // addeox (OE)
                {
                  mu.op = MicroOpCode::ADDE_RR;
                  mu.rd = next.inst.RD;
                  mu.ra = next.inst.RA;
                  mu.rb = next.inst.RB;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = (next.inst.SUBOP10 == 650) ? 1u : 0u;
                  goto end_pack_switch;
                }
                case 234:  // addmex
                case 746:  // addmeox (OE)
                {
                  mu.op = MicroOpCode::ADDME;
                  mu.rd = next.inst.RD;
                  mu.ra = next.inst.RA;
                  mu.rb = 0;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = (next.inst.SUBOP10 == 746) ? 1u : 0u;
                  goto end_pack_switch;
                }
                case 202:  // addzex
                case 714:  // addzeox (OE)
                {
                  mu.op = MicroOpCode::ADDZE;
                  mu.rd = next.inst.RD;
                  mu.ra = next.inst.RA;
                  mu.rb = 0;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = (next.inst.SUBOP10 == 714) ? 1u : 0u;
                  goto end_pack_switch;
                }
                case 40:   // subfx
                case 552:  // subfox (OE)
                {
                  mu.op = MicroOpCode::SUBF_RR;
                  mu.rd = next.inst.RD;
                  mu.ra = next.inst.RA;
                  mu.rb = next.inst.RB;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = (next.inst.SUBOP10 == 552) ? 1u : 0u;
                  goto end_pack_switch;
                }
                case 8:    // subfcx
                case 520:  // subfcox (OE)
                {
                  mu.op = MicroOpCode::SUBFC_RR;
                  mu.rd = next.inst.RD;
                  mu.ra = next.inst.RA;
                  mu.rb = next.inst.RB;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = (next.inst.SUBOP10 == 520) ? 1u : 0u;
                  goto end_pack_switch;
                }
                case 136:  // subfex
                case 648:  // subfeox (OE)
                {
                  mu.op = MicroOpCode::SUBFE_RR;
                  mu.rd = next.inst.RD;
                  mu.ra = next.inst.RA;
                  mu.rb = next.inst.RB;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = (next.inst.SUBOP10 == 648) ? 1u : 0u;
                  goto end_pack_switch;
                }
                case 232:  // subfmex
                case 744:  // subfmeox (OE)
                {
                  mu.op = MicroOpCode::SUBFME;
                  mu.rd = next.inst.RD;
                  mu.ra = next.inst.RA;
                  mu.rb = 0;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = (next.inst.SUBOP10 == 744) ? 1u : 0u;
                  goto end_pack_switch;
                }
                case 200:  // subfzex
                case 712:  // subfzeox (OE)
                {
                  mu.op = MicroOpCode::SUBFZE;
                  mu.rd = next.inst.RD;
                  mu.ra = next.inst.RA;
                  mu.rb = 0;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = (next.inst.SUBOP10 == 712) ? 1u : 0u;
                  goto end_pack_switch;
                }
                case 26:  // cntlzwx
                  mu.op = MicroOpCode::CNTLZW;
                  mu.rd = next.inst.RA;
                  mu.ra = next.inst.RS;
                  mu.rb = 0;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = 0;
                  goto end_pack_switch;
                case 954:  // extsbx
                  mu.op = MicroOpCode::EXTSB;
                  mu.rd = next.inst.RA;
                  mu.ra = next.inst.RS;
                  mu.rb = 0;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = 0;
                  goto end_pack_switch;
                case 922:  // extshx
                  mu.op = MicroOpCode::EXTSH;
                  mu.rd = next.inst.RA;
                  mu.ra = next.inst.RS;
                  mu.rb = 0;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = 0;
                  goto end_pack_switch;
                case 24:  // slwx
                  mu.op = MicroOpCode::SLW_VAR;
                  mu.rd = next.inst.RA;
                  mu.ra = next.inst.RS;
                  mu.rb = next.inst.RB;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = 0;
                  goto end_pack_switch;
                case 536:  // srwx
                  mu.op = MicroOpCode::SRW_VAR;
                  mu.rd = next.inst.RA;
                  mu.ra = next.inst.RS;
                  mu.rb = next.inst.RB;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = 0;
                  goto end_pack_switch;
                case 792:  // srawx
                  mu.op = MicroOpCode::SRAW_VAR;
                  mu.rd = next.inst.RA;
                  mu.ra = next.inst.RS;
                  mu.rb = next.inst.RB;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = 0;
                  goto end_pack_switch;
                case 824:  // srawix
                  mu.op = MicroOpCode::SRAWI_IMM;
                  mu.rd = next.inst.RA;
                  mu.ra = next.inst.RS;
                  mu.rb = 0;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = static_cast<u32>(next.inst.SH & 31u);
                  goto end_pack_switch;
                default:
                  // Not supported; undo reservation and stop packing.
                  --mop.count;
                  j = code_block.m_num_instructions;  // force stop
                  goto end_pack_switch;
                }
                // Common reg-reg logicals fallthrough: set standard fields.
                mu.rd = next.inst.RA;
                mu.ra = next.inst.RS;
                mu.rb = next.inst.RB;
                mu.rc = static_cast<u8>(next.inst.Rc);
                mu.imm = 0;
                break;
              }
              default:
                --mop.count;
                j = code_block.m_num_instructions;  // force stop
                break;
              }
            end_pack_switch:

              // Charge cycles for every consumed op AFTER op[i] (charged at the loop top). Key on
              // j_start, NOT the post-fold j: `next` == op[j_start], and the fold loops already charged
              // op[j_start+1..j]. The `j < num` half suppresses the force-stop default (j set to num).
              if (j_start != i && j < code_block.m_num_instructions)
                js.downcountAmount += next.opinfo->num_cycles;

              if (j < code_block.m_num_instructions)
                last_consumed = j;
            }

            if (mop.count > 0)
            {
              // All packed ops are non-terminal (canEndBlock hard-stopped the run), so write_pc is
              // always false here. Emit one callback for the consumed run [i..last_consumed].
              emit_fused(mop, i, last_consumed);
              i = last_consumed;  // outer ++i advances to the next unconsumed op
              continue;
            }
            // mop.count == 0: either nothing matched (last_consumed == i -> fall through to the generic
            // paths so op[i] is still emitted exactly once) or we consumed a run of pure NOP-eliminated
            // ops (last_consumed > i). In the latter case the ops are correctly elided AND already
            // charged in the packer, so skip them via i = last_consumed; continue; (re-emitting them
            // through the generic path would double-charge and re-execute them).
            if (last_consumed > i)
            {
              // With validate ON, still emit a (count==0) validate callback so the generic reference
              // runs the original NOP-eliminated ops and asserts they truly produce no state change —
              // i.e. the elision was sound. With validate OFF this elides silently (lean path).
              if (s_microop_fusion_validate)
                emit_fused(mop, i, last_consumed);  // mop.count == 0; generic-only reference
              i = last_consumed;
              continue;
            }
          }
        }

        const auto func = Interpreter::GetInterpreterOp(op.inst);
        const InterpretOperands operands = {interpreter, func, js.compilerPC, op.inst};
        bool emitted = false;
        // iCube WIN#1: PIC direct-pointer load/store fast path (MAIN_CIR_PIC_LOADSTORE). Emitted FIRST
        // and supersedes the specialized path for the ops it covers (integer load/stores). HARD GATES,
        // all required and independent of the flag's intent:
        //   - !jo.memcheck: already implied here (the exception-path branch above diverts every
        //     FL_LOADSTORE op when jo.memcheck is set), but reasserted for defense in depth — MMU-mode
        //     Wii titles and any debugger watchpoint MUST take the generic exception path.
        //   - jo.fastmem: the fastmem arena/region pointers are valid (the "fastmem is valid" gate).
        //   - FL_LOADSTORE && !FL_USE_FPU: INTEGER load/stores only. The PIC bodies are integer-only;
        //     emitting them for FP load/stores would force EA-compute + region-lookup + switch-miss +
        //     cold fallback on every FP access (a regression), so FP stays on the generic path.
        // The PIC body still null-checks the resolved region at runtime and delegates anything it does
        // not handle to Cold_LoadStoreFallback (exact generic handler), so correctness holds regardless.
        const u32 ls_flags = op.opinfo->flags;
        if (!emitted && s_pic_loadstore && !jo.memcheck && jo.fastmem &&
            (ls_flags & FL_LOADSTORE) != 0 && (ls_flags & FL_USE_FPU) == 0)
        {
          auto& memory = m_system.GetMemory();
          const LoadStoreDFormPICOperands pic_operands = {interpreter,
                                                          func,
                                                          js.compilerPC,
                                                          op.inst,
                                                          power_pc,
                                                          memory.GetRAM(),
                                                          memory.GetRamMask(),
                                                          memory.GetEXRAM(),
                                                          memory.GetExRamMask(),
                                                          memory.GetFakeVMEM(),
                                                          memory.GetFakeVMemMask()};
          if (op.inst.OPCD == 31)
          {
            Write(op.canEndBlock ? CallbackCast(LoadStoreXFormPIC<true>) :
                                   CallbackCast(LoadStoreXFormPIC<false>),
                  pic_operands);
          }
          else
          {
            Write(op.canEndBlock ? CallbackCast(LoadStoreDFormPIC<true>) :
                                   CallbackCast(LoadStoreDFormPIC<false>),
                  pic_operands);
          }
          emitted = true;
        }
        // iCube: route whitelisted hot ops to the specialized dispatch when MAIN_CIR_SPECIALIZED_OPS
        // is on. We emit ONE of two marker callbacks (write_pc false/true) plus a
        // SpecializedInterpretOperands payload that carries the InterpretOperands prefix verbatim and
        // the compact op-id ExecuteOneBlock jump-tables on. write_pc == op.canEndBlock, matching the
        // generic Interpret selection. Cold/non-whitelisted ops fall through to the unchanged generic
        // emission below — and when the flag is OFF, no marker callback is ever written, so the
        // dispatch never takes the specialized branch (flag-off stream is byte-identical to stock).
        if (!emitted && s_specialized_ops && IsSpecializedOp(func))
        {
          const SpecializedInterpretOperands spec_operands = {operands,
                                                              static_cast<u16>(SpecOpId(func))};
          Write(op.canEndBlock ? CallbackCast(InterpretSpecialized<true>) :
                                 CallbackCast(InterpretSpecialized<false>),
                spec_operands);
          emitted = true;
        }
        if (!emitted)
        {
          Write(op.canEndBlock ? CallbackCast(Interpret<true>) : CallbackCast(Interpret<false>),
                operands);
        }
      }

      if (op.branchIsIdleLoop)
        Write(CheckIdle, {m_system.GetCoreTiming(), js.blockStart});
      // For simple CTR-controlled tight loops, fast-forward by exiting the loop and yielding.
      if (op.branchIsCtrIdleLoop)
      {
        const u32 fallthrough_pc = op.address + 4;
        Write(FastForwardCtrIdle, {m_system.GetCoreTiming(), js.blockStart, fallthrough_pc});
      }
      if (op.canEndBlock)
      {
        // iCube: pass the STATIC branch target for linking. Exclude idle-loop terminals: their
        // preceding CheckIdle/FastForwardCtrIdle forces downcount<=0 via CoreTiming::Idle(), so a
        // link would bail anyway — keep them on the plain EndBlock path for clarity. Non-static
        // terminals carry branchTo==UINT32_MAX and so are not linkable inside WriteEndBlock.
        const bool idle_terminal = op.branchIsIdleLoop || op.branchIsCtrIdleLoop;
        WriteEndBlock(idle_terminal ? 0xFFFFFFFF : op.branchTo);
      }
    }
  }
  if (code_block.m_broken)
  {
    Write(WriteBrokenBlockNPC, {nextPC});
    WriteEndBlock();  // broken block: npc forced to nextPC, not a static target -> plain EndBlock
  }

  if (HasWriteFailed())
  {
    WARN_LOG_FMT(DYNA_REC, "JIT ran out of space in code region during code generation.");
    return false;
  }
  return true;
}

void CachedInterpreter::EraseSingleBlock(const JitBlock& block)
{
  m_block_cache.EraseSingleBlock(block);
  FreeRanges();
}

std::vector<JitBase::MemoryStats> CachedInterpreter::GetMemoryStats() const
{
  return {{"free", m_free_ranges.get_stats()}};
}

std::size_t CachedInterpreter::DisassembleNearCode(const JitBlock& block,
                                                   std::ostream& stream) const
{
  return Disassemble(block, stream);
}

std::size_t CachedInterpreter::DisassembleFarCode(const JitBlock& block, std::ostream& stream) const
{
  stream << "N/A\n";
  return 0;
}

void CachedInterpreter::ClearCache()
{
  m_block_cache.Clear();
  m_block_cache.ClearRangesToFree();
  ClearCodeSpace();
  ResetFreeMemoryRanges();
  RefreshConfig();
  Host_JitCacheInvalidation();
}

void CachedInterpreter::LogGeneratedCode() const
{
  std::ostringstream stream;

  stream << "\nPPC Code Buffer:\n";
  for (const PPCAnalyst::CodeOp& op :
       std::span{m_code_buffer.data(), code_block.m_num_instructions})
  {
    fmt::print(stream, "0x{:08x}\t\t{}\n", op.address,
               Common::GekkoDisassembler::Disassemble(op.inst.hex, op.address));
  }

  stream << "\nHost Code:\n";
  Disassemble(*js.curBlock, stream);

  // TODO C++20: std::ostringstream::view()
  DEBUG_LOG_FMT(DYNA_REC, "{}", std::move(stream).str());
}
