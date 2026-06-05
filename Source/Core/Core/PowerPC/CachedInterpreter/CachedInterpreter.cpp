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
#include "Core/PowerPC/JitInterface.h"
#include "Core/PowerPC/MMU.h"
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

// iCube: dead CR-flag elimination predicate. True IFF this op writes CR fields that are ALL discardable
// AND the Rc bit is the genuine mechanism that controls that CR write — so clearing the Rc bit in a copy
// of the instruction word skips the dead CR computation while leaving the GPR/XER result identical.
//
// The FL_RC_BIT/FL_RC_BIT_F guard is LOAD-BEARING, not cosmetic (PPCAnalyst.cpp:616-619): only ops
// carrying one of those flags have their CR0/CR1 gated on inst.Rc, and only for those ops is instruction
// bit 0 actually the Rc bit. The always-record ops (andi./andis. -> FL_SET_CR0, compares -> FL_SET_CRn)
// would (a) still compute CR0/CRn regardless of bit 0 AND (b) have their immediate's LSB silently
// corrupted if we cleared "Rc". For those, crOut can be fully discardable, so deadCR alone would
// wrongly fire — the flag check is what excludes them. We also require inst.Rc == 1 (clearing an already-
// 0 bit is a no-op the validate harness would needlessly double-run) and a non-empty crOut.
static bool DeadFlagElimApplies(const PPCAnalyst::CodeOp& op)
{
  const auto cr_out = op.crOut;
  if (cr_out.Count() == 0)
    return false;  // op writes no CR field; nothing to eliminate
  if ((cr_out & ~op.crDiscardable) != BitSet8{})
    return false;  // some written CR field is LIVE downstream — must keep computing it
  if (op.inst.Rc == 0)
    return false;  // record bit already clear: CR not being written via Rc anyway
  // Only ops whose CR write is gated on the Rc bit (and whose bit 0 IS the Rc bit) are safe to rewrite.
  const u64 flags = op.opinfo->flags;
  return (flags & (FL_RC_BIT | FL_RC_BIT_F)) != 0;
}

// iCube: dead-FPRF elimination predicate. True IFF this op PRODUCES an FPRF (op.outputFPRF, from
// FL_SET_FPRF) that PPCAnalyst's back-to-front pass proved DEAD (op.wantsFPRF == false — overwritten
// before any read, and the analyzer forces it LIVE across every exception/block-exit boundary via
// may_exit_block, so a dead FPRF can never be observed). This is the exact FP analogue of the JIT's own
// wantsFPRF optimization. Compares (fcmpo/fcmpu, ps_cmp*) are EXCLUDED via FL_READ_FPRF: they (a) write
// the FPCC subfield DIRECTLY (bypassing UpdateFPRF*, so the hint could not skip them anyway) and (b)
// also write CR — excluding them keeps every wrapped op pure-arithmetic (touches only FPRs + FPSCR),
// which keeps the validate harness's "everything except FPRF matches" scope clean. The FL_READ_FPRF
// gate is also what makes the partial-FPCC-overwrite hazard safe: a compare carries FL_READ_FPRF, so it
// never kills upstream FPRF liveness in the analyzer — only a full-FPRF-overwriting helper op does — so
// outputFPRF && !wantsFPRF is never true for an op whose FPRF partially survives.
static bool FPRFElimApplies(const PPCAnalyst::CodeOp& op)
{
  if (!op.outputFPRF)
    return false;  // op produces no FPRF; nothing to eliminate
  if (op.wantsFPRF)
    return false;  // the FPRF this op produces is LIVE downstream — must keep computing it
  return (op.opinfo->flags & FL_READ_FPRF) == 0;  // exclude compares (write FPCC directly + write CR)
}

// iCube: hot-block profiler (MAIN_CIR_PROFILE, default OFF). Read once in Init. When false the
// once-per-block hook in EndBlock/LinkBlock is a single predicted-not-taken bool test and the
// per-INSTRUCTION dispatch in ExecuteOneBlock is byte-for-byte untouched.
static bool s_cir_profile = false;
// iCube: MemoryManager handle used ONLY at report-build time (BuildHotBlocksReport, which runs when
// the user taps Copy State — never on the hot path) to read guest instruction words for disassembling
// the top hot blocks. Captured in Init from m_system.GetMemory() (the manager OBJECT is stable for the
// session; we re-check GetRamSizeReal() each read rather than caching the raw m_ram pointer, which can
// go null). Mirrors the s_validate_instance pattern: a static free function has no `this`, so it needs
// a file-static handle to reach emulator state. NEVER touched on the per-block accumulation path.
static Memory::MemoryManager* s_profile_memory = nullptr;

// iCube: dead CR-flag elimination (MAIN_CIR_DEAD_FLAG_ELIM). Read once in Init. When true, DoJit skips
// the CR computation for an Rc-form op whose ENTIRE crOut is discardable (proven dead by PPCAnalyst) by
// emitting the op with the Rc bit cleared in a LOCAL copy of its instruction word — the same handler then
// computes the identical GPR result minus the dead flag. Default OFF: when false NO instruction word is
// ever rewritten and the emitted callback stream is byte-identical to the flag-off baseline.
static bool s_dead_flag_elim = false;
// iCube: when true, every eliminated op double-runs (reference Rc-set vs eliminated Rc-cleared) and asserts
// every LIVE (non-crOut) CR field matches. Default OFF; correctness passes only. See InterpretDeadFlagValidate.
static bool s_dead_flag_elim_validate = false;
// iCube: dead-FPRF elimination (MAIN_CIR_DEAD_FPRF_ELIM). Read once in Init. When true, DoJit wraps an
// arithmetic FP/PS op whose FPRF is proven dead (FPRFElimApplies) in InterpretFPRFElim, which suppresses
// the UpdateFPRF* classify for that one handler call. Default OFF: when false NO op is wrapped and the
// emitted callback stream is byte-identical to the flag-off baseline (the hint is never set true).
static bool s_dead_fprf_elim = false;
// iCube: when true, every FPRF-eliminated op double-runs (FPRF computed vs skipped) and asserts the FPRs
// and all non-FPRF FPSCR bits match. Default OFF; correctness passes only. See InterpretFPRFElimValidate.
static bool s_dead_fprf_elim_validate = false;

// iCube: counted-store-loop (memset) fast-path (MAIN_CIR_STORE_LOOP_FF). Read once in Init. When OFF
// (default) the DoJit recognizer never runs and NO StoreLoopFill callback is emitted, so the callback
// stream is byte-for-byte identical to the flag-off baseline. When ON, a recognized "M*stb + addi +
// bdnz" memset loop emits a StoreLoopFill callback alongside the unchanged store records. UNVALIDATED
// on-device — gated for A/B.
static bool s_store_loop_ff = false;
// iCube: validate twin (MAIN_CIR_STORE_LOOP_FF_VALIDATE). When ON, StoreLoopFill sequences a real
// per-store reference run against the bulk fill on a snapshot and asserts equivalence. Default OFF;
// correctness passes only.
static bool s_store_loop_ff_validate = false;
// iCube: emulator handles for the StoreLoopFill static callback (a free function has no `this`). Set in
// Init ONLY when the store-loop fast-path is on; left null otherwise so the flag-off path can never
// touch them. Mirrors the s_profile_memory pattern (one-per-System, stable for the session). The MMU is
// the translation/reference-store engine; Memory resolves the host RAM pointer for the bulk range; the
// JitInterface invalidates the icache over the filled range (SMC coherency).
static PowerPC::MMU* s_store_loop_mmu = nullptr;
static Memory::MemoryManager* s_store_loop_memory = nullptr;
static JitInterface* s_store_loop_jit = nullptr;

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

// iCube: report-time guest-code reader. Bounds-checks `addr` against the live MEM1/EXRAM sizes BEFORE
// reading so we never trip a PanicAlert (GetSpanForAddress/GetPointerForRange/Read_U32 all panic on a
// bad address). Returns false (and leaves *out untouched) when the address is unreadable — game not
// running (GetRamSizeReal()==0), unmapped, or a partial word at a region's tail. On success *out holds
// the instruction word in NATIVE order (Read_U32 does the big-endian swap32), exactly what
// GekkoDisassembler::Disassemble expects. Read-only; called only from BuildHotBlocksReport.
static bool CIR_TryReadGuestU32(u32 addr, u32* out)
{
  Memory::MemoryManager* mem = s_profile_memory;
  if (!mem)
    return false;
  // Mirror GetSpanForAddress's region math (MEM1 then EXRAM) but WITHOUT its panic-on-miss, and
  // require a full 4-byte word inside one region (no straddle past the tail).
  const u32 masked = addr & 0x3FFFFFFFu;
  const u32 ram_real = mem->GetRamSizeReal();
  if (ram_real >= 4 && masked <= ram_real - 4)
  {
    *out = mem->Read_U32(addr);  // panic path unreachable: range pre-validated above
    return true;
  }
  if ((masked >> 28) == 0x1u)
  {
    const u32 exram_real = mem->GetExRamSizeReal();
    const u32 exoff = masked & mem->GetExRamMask();
    if (exram_real >= 4 && exoff <= exram_real - 4)
    {
      *out = mem->Read_U32(addr);  // panic path unreachable: range pre-validated above
      return true;
    }
  }
  return false;
}

// iCube: true if `op`'s primary opcode is a control-flow instruction that terminates a CIR block, so
// the disassembler can stop right after emitting it (a block is a straight run ending at its first
// taken/considered branch). Primary 16 = bc/bcx, 18 = b/bx, 19 = bclr/bcctr (and other CR-logical/
// branch-to-register forms). Over-continuing past a rare primary-19 CR op would just print one extra
// line; under-stopping never happens for the real branch encodings, which is what we care about.
static bool CIR_IsBlockTerminator(u32 op)
{
  const u32 primary = (op >> 26) & 0x3Fu;
  return primary == 16 || primary == 18 || primary == 19;
}

// iCube: append the PPC disassembly of a block to the report. Report-time ONLY (Copy State); never on
// the accumulation hot path. Walks up to kMaxInsts words from entry_pc, stopping after the first
// block-terminating branch. Each readable word is rendered "    0xADDR: 0xOPCODE  mnemonic operands";
// an unreadable word prints "    0xADDR: <unreadable>" and ends the walk (the rest of the block lives in
// the same region, so one miss means the block is gone/invalid). The short lwz/cmpw/bne-to-self shape of
// an idle poll the idle-detector missed is meant to be obvious at a glance here.
static void CIR_AppendBlockDisasm(std::ostringstream& out, u32 entry_pc)
{
  constexpr u32 kMaxInsts = 12;
  if (!s_profile_memory)
  {
    out << "        <disasm unavailable: profiler memory handle not set>\n";
    return;
  }
  u32 addr = entry_pc;
  for (u32 i = 0; i < kMaxInsts; ++i, addr += 4)
  {
    u32 op = 0;
    if (!CIR_TryReadGuestU32(addr, &op))
    {
      char miss[64];
      snprintf(miss, sizeof(miss), "        0x%08x: <unreadable>\n", addr);
      out << miss;
      break;
    }
    const std::string text = Common::GekkoDisassembler::Disassemble(op, addr);
    char line[160];
    snprintf(line, sizeof(line), "        0x%08x: 0x%08x  %s\n", addr, op, text.c_str());
    out << line;
    if (CIR_IsBlockTerminator(op))
      break;
  }
}
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
    const bool is_spin = (e.runs >= 50000 && cyc_per_run <= 8.0);
    const char* hint = is_spin ? "SPIN?" : "";
    char line[160];
    snprintf(line, sizeof(line), "  %4u  0x%08x  %10llu  %12llu  %8.2f  %5.1f  %s\n", i + 1, e.pc,
             static_cast<unsigned long long>(e.runs),
             static_cast<unsigned long long>(e.cycles), cyc_per_run, pct, hint);
    out << line;
    // iCube: for the top 10 ranked blocks (and any flagged SPIN?), append the PPC disassembly of the
    // block so we can classify what the hot/spin code actually does (idle-wait vs memory-heavy vs
    // compute vs dispatch-bound). Report-time only — runs when the user taps Copy State, NOT on the
    // per-block accumulation hot path (which is byte-identical to before this change). Read-only guest
    // memory with full bounds-checking; unreadable words print <unreadable> and never crash the report.
    if (i < 10 || is_spin)
      CIR_AppendBlockDisasm(out, e.pc);
  }
  return std::move(out).str();
}
}  // namespace CIRProfiler

// iCube: counted-store-loop (memset) recognizer (MAIN_CIR_STORE_LOOP_FF). Result of scanning a built
// CIR block for the EXACT memset shape. matched==false leaves the block untouched (normal per-store).
namespace
{
struct StoreLoopMatch
{
  bool matched = false;
  u32 reg_s = 0;   // value-source GPR (stb rS); the byte filled is GPR[rS] & 0xFF
  u32 reg_b = 0;   // base GPR (stb base + addi target); rB != 0, rB != rS
  u32 stride = 0;  // M: bytes per iteration == addi immediate == number of stb records
};

// Recognize EXACTLY: M consecutive `stb rS,k(rB)` for k in {0..M-1} (each offset once, same rS, same
// rB), then `addi rB,rB,M`, then a `bdnz` self-loop back to block start. rS/rB loop-invariant: rS != rB,
// rB != 0, and no instruction writes any GPR except rB by that one addi. No other instructions. Anything
// not matching => matched=false. Conservative by construction: every deviation bails.
static StoreLoopMatch RecognizeStoreLoop(const PPCAnalyst::CodeOp* code, u32 num_insts, u32 block_start)
{
  StoreLoopMatch m;
  // Need at least 1 stb + addi + bdnz = 3 instructions.
  if (num_insts < 3)
    return m;

  const u32 store_count = num_insts - 2;  // M
  const PPCAnalyst::CodeOp& addi_op = code[num_insts - 2];
  const PPCAnalyst::CodeOp& br_op = code[num_insts - 1];

  // --- Terminator must be a plain bdnz self-loop (decrement CTR, branch if CTR!=0, NO condition). ---
  const UGeckoInstruction br = br_op.inst;
  if (br.OPCD != 16)  // bcx
    return m;
  if (br.LK != 0)  // bdnzl writes LR — not loop-invariant
    return m;
  // BO = decrement (clear DONT_DECREMENT), branch-if-CTR!=0 (clear BRANCH_IF_CTR_0), don't-check-cond
  // (set DONT_CHECK_CONDITION). Excludes bdz / bdnzt / bdnzf / plain conditional branches.
  if ((br.BO & BO_DONT_DECREMENT_FLAG) != 0)
    return m;
  if ((br.BO & BO_BRANCH_IF_CTR_0) != 0)
    return m;
  if ((br.BO & BO_DONT_CHECK_CONDITION) == 0)
    return m;
  if (br_op.branchTo != block_start)  // must loop back to the first stb
    return m;

  // --- addi rB,rB,M : OPCD 14, RA==RD (in-place increment of the base), immediate == M. ---
  const UGeckoInstruction ai = addi_op.inst;
  if (ai.OPCD != 14)  // addi/li
    return m;
  const u32 reg_b = ai.RD;
  if (reg_b == 0)  // RA==0 in addi means "li" (no base reg); the base must be a real GPR
    return m;
  if (ai.RA != reg_b)  // must read+write the SAME base register
    return m;
  if (static_cast<u32>(static_cast<s32>(ai.SIMM_16)) != store_count)  // immediate must equal M
    return m;

  // --- M stores: each `stb rS,k(rB)` for k in {0..M-1}, same rS, same rB (==reg_b), rS != rB, rB != 0.
  u32 reg_s = 0;
  bool reg_s_set = false;
  // Track which offsets 0..M-1 we have seen (M <= num_insts <= code-buffer cap, well under 64).
  u64 seen_offsets = 0;
  if (store_count == 0 || store_count > 60)
    return m;
  for (u32 i = 0; i < store_count; ++i)
  {
    const UGeckoInstruction st = code[i].inst;
    if (st.OPCD != 38)  // stb (NOT stbu=39, NOT any other store/update form)
      return m;
    if (st.RA != reg_b)  // base must be rB
      return m;
    const u32 cur_s = st.RS;
    if (!reg_s_set)
    {
      reg_s = cur_s;
      reg_s_set = true;
    }
    else if (cur_s != reg_s)  // value source must be loop-invariant across all stores
    {
      return m;
    }
    const s32 off = static_cast<s32>(st.SIMM_16);
    if (off < 0 || static_cast<u32>(off) >= store_count)  // offsets must lie in {0..M-1}
      return m;
    const u64 bit = 1ull << static_cast<u32>(off);
    if (seen_offsets & bit)  // each offset exactly once (gap-free, overlap-free tiling)
      return m;
    seen_offsets |= bit;
  }
  // Every offset 0..M-1 present exactly once.
  if (seen_offsets != ((store_count >= 64) ? ~0ull : ((1ull << store_count) - 1)))
    return m;

  if (reg_s == reg_b)  // value source and base must differ (rS write would not be loop-invariant)
    return m;
  if (reg_b == 0)
    return m;

  // Loop-invariance: the ONLY GPR written anywhere in the block is rB, and only by that one addi. The
  // stores write memory, not GPRs; the bdnz writes only CTR. Verify via regsOut: addi writes {rB}; every
  // store and the branch write no GPR. (regsOut is the analyzer's per-op GPR write set.)
  for (u32 i = 0; i < store_count; ++i)
  {
    if (code[i].regsOut != BitSet32{})  // a stb writes no GPR
      return m;
  }
  if (addi_op.regsOut != BitSet32{static_cast<int>(reg_b)})  // addi writes exactly rB
    return m;
  if (br_op.regsOut != BitSet32{})  // bdnz writes no GPR
    return m;

  m.matched = true;
  m.reg_s = reg_s;
  m.reg_b = reg_b;
  m.stride = store_count;
  return m;
}
}  // namespace

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
  // iCube: dead CR-flag elimination (default OFF). Read once at codegen time. When off DoJit never clears
  // an Rc bit, so the emitted stream is byte-identical to the flag-off baseline.
  s_dead_flag_elim = Config::Get(Config::MAIN_CIR_DEAD_FLAG_ELIM);
  s_dead_flag_elim_validate = Config::Get(Config::MAIN_CIR_DEAD_FLAG_ELIM_VALIDATE);
  // iCube: dead-FPRF elimination (default OFF). Read once at codegen time. When off DoJit never wraps an
  // FP op, so the emitted stream is byte-identical to the flag-off baseline and the hint is never set.
  s_dead_fprf_elim = Config::Get(Config::MAIN_CIR_DEAD_FPRF_ELIM);
  s_dead_fprf_elim_validate = Config::Get(Config::MAIN_CIR_DEAD_FPRF_ELIM_VALIDATE);
  // iCube: psq FLOAT fast-path (default OFF). Read once here and stashed via the PowerPC accessors so the
  // generic psq Helper_Dequantize/Helper_Quantize handlers can consult them per-execution without a
  // Config::Get on the hot path. When off the handlers run only the unchanged generic switch.
  PowerPC::SetPsqFastpathEnabled(Config::Get(Config::MAIN_CIR_PSQ_FASTPATH));
  PowerPC::SetPsqFastpathValidate(Config::Get(Config::MAIN_CIR_PSQ_FASTPATH_VALIDATE));
  // iCube: refresh the shared NEON paired-single fast-path flags per game-boot (the handlers live in
  // Interpreter_Paired.cpp and are reached from the CIR's Interpret dispatch). Previously read once per
  // app process via a function-local static, so the toggle appeared inert until a full app restart.
  Interpreter::RefreshNeonPairedConfig();
  // iCube: counted-store-loop (memset) fast-path (default OFF). Read once. Capture the MMU/Memory/
  // JitInterface handles for the StoreLoopFill static callback ONLY when the feature is on, so the
  // flag-off path leaves them null and is byte-identical to baseline. One-per-System, set at boot.
  s_store_loop_ff = Config::Get(Config::MAIN_CIR_STORE_LOOP_FF);
  s_store_loop_ff_validate = Config::Get(Config::MAIN_CIR_STORE_LOOP_FF_VALIDATE);
  s_store_loop_mmu = s_store_loop_ff ? &m_system.GetMMU() : nullptr;
  s_store_loop_memory = s_store_loop_ff ? &m_system.GetMemory() : nullptr;
  s_store_loop_jit = s_store_loop_ff ? &m_system.GetJitInterface() : nullptr;
  s_block_profile.Clear();
  if (s_cir_profile)
    s_block_profile.EnsureAllocated();
  // iCube: capture the MemoryManager handle for the report-time block disassembler (see
  // s_profile_memory). Set only when profiling is on, so the profiler-disabled path leaves it null and
  // the report builder's disasm append is fully inert. Boot-time one-shot write; never on the hot path.
  s_profile_memory = s_cir_profile ? &m_system.GetMemory() : nullptr;

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
  // iCube: compare CR field-by-field, EXCLUDING any fields the packer dead-flag-eliminated
  // (MAIN_CIR_DEAD_FLAG_ELIM). Those fields are computed by the generic reference (original Rc-set
  // instructions) but deliberately skipped by the fused run, and PPCAnalyst proved them dead — so a
  // difference there is expected. elim_cr_mask is zero when dead-flag-elim is off, making this the
  // identical all-8-field compare as before. A divergence in any NON-eliminated (live) field still fires.
  const u8 elim_cr_mask = static_cast<u8>(operands.elim_cr_mask);
  for (u32 k = 0; k < 8; ++k)
  {
    if ((elim_cr_mask >> k) & 1u)
      continue;
    ASSERT_MSG(DYNA_REC, fused_cr[k] == generic_cr[k],
               "CIR micro-op fusion CR{} mismatch at pc {:#x} (fused={:#x} vs generic={:#x}, "
               "elim_mask={:#04x})",
               k, operands.current_pc, fused_cr[k], generic_cr[k], elim_cr_mask);
  }
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

// iCube: dead CR-flag elimination validate (MAIN_CIR_DEAD_FLAG_ELIM_VALIDATE). Direct analogue of the
// micro-op fusion / specialized-ops double-run, specialized to the single-op flag-skip transform. The
// transform only ever clears the Rc bit on an op whose ENTIRE crOut PPCAnalyst proved discardable; this
// harness double-runs the op (reference Rc-set CR vs eliminated Rc-cleared) and asserts every CR field
// OUTSIDE that crOut mask — i.e. every LIVE field read by the block continuation — is byte-identical.
// Run order mirrors the other validates: snapshot -> reference on live -> capture -> restore -> eliminated
// (the SHIPPING path, committed last) -> capture -> assert. GPR/XER/pc/npc/Exceptions are identical by
// construction (Rc 0/1 select the same opcode-keyed handler and the same GPR/XER math), so the diff is
// scoped to CR — the only field the transform touches. write_pc mirrors Interpret<write_pc>.
template <bool write_pc>
s32 CachedInterpreter::InterpretDeadFlagValidate(PowerPC::PowerPCState& ppc_state,
                                                 const InterpretDeadFlagValidateOperands& operands)
{
  const s32 validate_distance = sizeof(AnyCallback) + sizeof(operands);

  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }

  // Snapshot the CR (the only field the transform can perturb) plus the bookkeeping the reference run
  // mutates, so the eliminated run starts from byte-identical inputs.
  std::array<u64, 8> saved_cr;
  std::copy(std::begin(ppc_state.cr.fields), std::end(ppc_state.cr.fields), saved_cr.begin());
  std::array<u32, 32> saved_gpr;
  std::copy(std::begin(ppc_state.gpr), std::end(ppc_state.gpr), saved_gpr.begin());
  const u8 saved_xer_ca = ppc_state.xer_ca;
  const u8 saved_xer_so_ov = ppc_state.xer_so_ov;
  const u32 saved_pc = ppc_state.pc;
  const u32 saved_npc = ppc_state.npc;
  const u32 saved_exceptions = ppc_state.Exceptions;

  // REFERENCE RUN: the ORIGINAL (Rc-set) instruction, so the genuine CR result is computed.
  operands.func(operands.interpreter, operands.ref_inst);
  std::array<u64, 8> ref_cr;
  std::copy(std::begin(ppc_state.cr.fields), std::end(ppc_state.cr.fields), ref_cr.begin());

  // Restore to the pre-run state so the eliminated run sees identical inputs.
  std::copy(saved_cr.begin(), saved_cr.end(), std::begin(ppc_state.cr.fields));
  std::copy(saved_gpr.begin(), saved_gpr.end(), std::begin(ppc_state.gpr));
  ppc_state.xer_ca = saved_xer_ca;
  ppc_state.xer_so_ov = saved_xer_so_ov;
  ppc_state.pc = saved_pc;
  ppc_state.npc = saved_npc;
  ppc_state.Exceptions = saved_exceptions;

  // ELIMINATED RUN — the SHIPPING path, run LAST so its result stays committed. operands.inst already has
  // the Rc bit cleared, so the dead CR field(s) are NOT computed.
  operands.func(operands.interpreter, operands.inst);

  // Assert every CR field OUTSIDE the eliminated mask (the live/continuation-read fields) matches the
  // reference. The masked fields are exactly op.crOut, all proven discardable, so a divergence there is
  // expected and ignored; a divergence ANYWHERE else means a live flag was wrongly eliminated.
  const u8 elim_mask = operands.elim_cr_mask;
  for (u32 k = 0; k < 8; ++k)
  {
    if ((elim_mask >> k) & 1u)
      continue;  // this field was eliminated on purpose (proven dead) — allowed to differ
    ASSERT_MSG(DYNA_REC, ppc_state.cr.fields[k] == ref_cr[k],
               "CIR dead-flag-elim LIVE CR{} divergence at pc {:#010x} (elim={:#x} vs ref={:#x}, "
               "elim_mask={:#04x})",
               k, operands.current_pc, ppc_state.cr.fields[k], ref_cr[k], elim_mask);
  }

  return validate_distance;
}

template <bool write_pc>
s32 CachedInterpreter::InterpretDeadFlagValidate(std::ostream& stream,
                                                 const InterpretDeadFlagValidateOperands& operands)
{
  fmt::print(stream, "InterpretDeadFlagValidate(elim_mask={:#04x}) at PC={:#010x}\n",
             operands.elim_cr_mask, operands.current_pc);
  return sizeof(AnyCallback) + sizeof(operands);
}

// iCube: RAII guard for the dead-FPRF elimination hint. Sets PowerPC::SetDeadFPRFElimHint(true) on entry
// and unconditionally restores it to false on scope exit, so even if the handler throws/early-returns
// through a CheckExceptions path the hint can never be stranded true into the next op. Single CPU thread,
// so no re-entrancy; this is cheap insurance against a stuck-true corrupting every subsequent FP op.
namespace
{
struct DeadFPRFHintGuard
{
  DeadFPRFHintGuard() { PowerPC::SetDeadFPRFElimHint(true); }
  ~DeadFPRFHintGuard() { PowerPC::SetDeadFPRFElimHint(false); }
  DeadFPRFHintGuard(const DeadFPRFHintGuard&) = delete;
  DeadFPRFHintGuard& operator=(const DeadFPRFHintGuard&) = delete;
};
}  // namespace

// iCube: dead-FPRF elimination (MAIN_CIR_DEAD_FPRF_ELIM). Identical to Interpret<write_pc> except the
// handler runs inside the DeadFPRFHintGuard window, so UpdateFPRFSingle/Double early-return and the dead
// FPRF classify is skipped. func is the SAME opcode-keyed handler the generic path would call; the only
// difference is the FPRF write is suppressed. Numeric result / rounding / exceptions / all other FPSCR
// bits are untouched (the helpers do nothing but write FPRF). Off-path never emits this callback.
template <bool write_pc>
s32 CachedInterpreter::InterpretFPRFElim(PowerPC::PowerPCState& ppc_state,
                                         const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  {
    const DeadFPRFHintGuard guard;
    operands.func(operands.interpreter, operands.inst);
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
s32 CachedInterpreter::InterpretFPRFElim(std::ostream& stream, const InterpretOperands& operands)
{
  fmt::print(stream, "InterpretFPRFElim at PC={:#010x}\n", operands.current_pc);
  return sizeof(AnyCallback) + sizeof(operands);
}

// iCube: dead-FPRF elimination VALIDATE harness (MAIN_CIR_DEAD_FPRF_ELIM_VALIDATE). Double-runs the SAME
// op: first the REFERENCE (hint OFF -> FPRF computed) on the live state, snapshotting the FPRs + full
// FPSCR; then it restores the inputs and runs the ELIMINATED form (hint ON -> FPRF skipped), the SHIPPING
// path committed LAST. It then asserts the FPRs and every FPSCR bit OUTSIDE the FPRF field are byte-
// identical between the two runs — the FPRF field is the ONLY thing the elimination is allowed to perturb.
// A divergence in a result register, an exception/rounding bit, or any non-FPRF FPSCR state means a
// mis-applied elimination (eliminating a live FPRF would NOT be caught here directly — that is caught by
// the analyzer's wantsFPRF liveness — but a transform that wrongly touches non-FPRF state IS caught). The
// op writes only FPRs + FPSCR (compares, which also write CR, are excluded at emit via FL_READ_FPRF), so
// snapshotting GPR/CR/etc. is unnecessary; we still snapshot/restore the few input-affecting scalars the
// reference run could mutate so the eliminated run sees identical inputs. write_pc mirrors Interpret.
template <bool write_pc>
s32 CachedInterpreter::InterpretFPRFElimValidate(PowerPC::PowerPCState& ppc_state,
                                                 const InterpretOperands& operands)
{
  const s32 validate_distance = sizeof(AnyCallback) + sizeof(operands);

  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }

  // Snapshot all state the op (or the reference run) can perturb, so the eliminated run starts from
  // byte-identical inputs. FPRs and FPSCR are the op's outputs; pc/npc/Exceptions guard the exception
  // accounting some FP handlers touch.
  std::array<PowerPC::PairedSingle, 32> saved_ps;
  std::copy(std::begin(ppc_state.ps), std::end(ppc_state.ps), saved_ps.begin());
  const u32 saved_fpscr = ppc_state.fpscr.Hex;
  const u32 saved_pc = ppc_state.pc;
  const u32 saved_npc = ppc_state.npc;
  const u32 saved_exceptions = ppc_state.Exceptions;

  // REFERENCE RUN: hint OFF -> the genuine FPRF is computed. Capture the resulting FPRs + FPSCR.
  {
    PowerPC::SetDeadFPRFElimHint(false);
    operands.func(operands.interpreter, operands.inst);
  }
  std::array<PowerPC::PairedSingle, 32> ref_ps;
  std::copy(std::begin(ppc_state.ps), std::end(ppc_state.ps), ref_ps.begin());
  const u32 ref_fpscr = ppc_state.fpscr.Hex;

  // Restore to the pre-run state so the eliminated run sees identical inputs.
  std::copy(saved_ps.begin(), saved_ps.end(), std::begin(ppc_state.ps));
  ppc_state.fpscr.Hex = saved_fpscr;
  ppc_state.pc = saved_pc;
  ppc_state.npc = saved_npc;
  ppc_state.Exceptions = saved_exceptions;

  // ELIMINATED RUN — the SHIPPING path, run LAST so its result stays committed. Hint ON -> FPRF skipped.
  {
    const DeadFPRFHintGuard guard;
    operands.func(operands.interpreter, operands.inst);
  }

  // Assert every FPR matches the reference: the eliminated form must NOT perturb any numeric result.
  for (u32 k = 0; k < 32; ++k)
  {
    ASSERT_MSG(DYNA_REC,
               ppc_state.ps[k].ps0 == ref_ps[k].ps0 && ppc_state.ps[k].ps1 == ref_ps[k].ps1,
               "CIR dead-FPRF-elim FPR{} divergence at pc {:#010x} (elim ps0={:#018x} ps1={:#018x} "
               "vs ref ps0={:#018x} ps1={:#018x})",
               k, operands.current_pc, ppc_state.ps[k].ps0, ppc_state.ps[k].ps1, ref_ps[k].ps0,
               ref_ps[k].ps1);
  }
  // Assert every FPSCR bit OUTSIDE the FPRF field matches the reference. FPRF (bits 12-16) is the ONLY
  // field the elimination is allowed to differ on; a divergence in any other bit (exception/rounding/
  // summary) is a mis-applied transform.
  const u32 elim_fpscr = ppc_state.fpscr.Hex;
  ASSERT_MSG(DYNA_REC, (elim_fpscr & ~FPRF_MASK) == (ref_fpscr & ~FPRF_MASK),
             "CIR dead-FPRF-elim non-FPRF FPSCR divergence at pc {:#010x} (elim={:#010x} vs "
             "ref={:#010x}, FPRF_MASK={:#010x})",
             operands.current_pc, elim_fpscr, ref_fpscr, FPRF_MASK);

  return validate_distance;
}

template <bool write_pc>
s32 CachedInterpreter::InterpretFPRFElimValidate(std::ostream& stream,
                                                 const InterpretOperands& operands)
{
  fmt::print(stream, "InterpretFPRFElimValidate at PC={:#010x}\n", operands.current_pc);
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

// iCube: counted-store-loop (memset) fast-path handler (MAIN_CIR_STORE_LOOP_FF). Emitted alongside the
// recognized loop's records, BEFORE the first stb. Runs once on the first dispatch into the block. Bulk-
// fills the first (count-1) strides directly into host RAM after a per-page RAM-not-MMIO contiguity
// guard over the WHOLE filled range, then leaves exactly one iteration (CTR=1, rB at base+(count-1)*M)
// for the real stb/addi/bdnz records to execute — so the final store goes through the genuine faulting
// path and rB/CTR/npc/downcount end EXACTLY as the unfused loop. On ANY guard failure (range not
// contiguous normal RAM, count<=1, overflow) it bails (returns the normal record distance) and the real
// per-store loop runs unchanged, which correctly handles MMIO + per-store faults + CTR-underflow.
namespace
{
// Per-page translation guard: resolve a host pointer for the ENTIRE guest range [base, base+total) and
// require it to be contiguous normal RAM. Walks every page boundary (a guest-virtually contiguous range
// can map to physically discontiguous pages), translating each via MMU::GetTranslatedAddress (which
// honors MSR.DR / BAT / page tables), requiring physical contiguity, then resolving the single host
// pointer for the physical base with a panic-free region pre-check before GetPointerForRange (which
// PanicAlerts on a bad/oversized address). Returns nullptr on ANY failure (MMIO, unmapped, page-cross
// out of RAM, non-contiguous) => caller bails to the per-store records. total must be >= 1.
static u8* ResolveContiguousRamRange(PowerPC::MMU& mmu, Memory::MemoryManager& memory, u32 base,
                                     u32 total)
{
  constexpr u32 kPageSize = 0x1000;  // 4 KiB; conservative page granularity for the contiguity walk.

  // Translate the first byte. nullopt => not mapped for data access (or faults) => bail.
  const std::optional<u32> first_phys_opt = mmu.GetTranslatedAddress(base);
  if (!first_phys_opt)
    return nullptr;
  const u32 first_phys = *first_phys_opt;

  // Walk each subsequent page start, requiring physical contiguity with the first page.
  const u32 last = base + (total - 1);  // inclusive; total>=1 so no underflow
  // Guard against a wrapped range (base + total overflowing the 32-bit guest space).
  if (last < base)
    return nullptr;
  for (u32 page_base = (base & ~(kPageSize - 1)) + kPageSize; page_base != 0 && page_base <= last;
       page_base += kPageSize)
  {
    const std::optional<u32> phys_opt = mmu.GetTranslatedAddress(page_base);
    if (!phys_opt)
      return nullptr;
    // Physical address of this page must equal first_phys + (page_base - base-rounded). Compute the
    // expected physical for page_base relative to the first translated byte.
    const u32 expected_phys = first_phys + (page_base - base);
    if (*phys_opt != expected_phys)
      return nullptr;  // virtually contiguous but physically discontiguous => not safe to bulk-fill
  }

  // Panic-free region pre-check on the PHYSICAL base (mirror GetSpanForAddress's region math without its
  // panic-on-miss), requiring the full [first_phys, first_phys+total) to fit inside ONE normal-RAM
  // region (MEM1 or EXRAM). This is what excludes MMIO (e.g. the GX FIFO at 0xCC008000) and any range
  // straddling a region tail — neither reaches the RAM branches below.
  const u32 masked = first_phys & 0x3FFFFFFFu;
  const u32 ram_real = memory.GetRamSizeReal();
  bool in_ram = false;
  if (ram_real >= total && masked <= ram_real - total)
  {
    in_ram = true;  // wholly inside MEM1
  }
  else if ((masked >> 28) == 0x1u)
  {
    const u32 exram_real = memory.GetExRamSizeReal();
    const u32 exoff = masked & memory.GetExRamMask();
    if (exram_real >= total && exoff <= exram_real - total)
      in_ram = true;  // wholly inside EXRAM
  }
  if (!in_ram)
    return nullptr;

  // Safe now: the range is validated to fit one region, so GetPointerForRange will not panic.
  return memory.GetPointerForRange(first_phys, total);
}
}  // namespace

s32 CachedInterpreter::StoreLoopFill(PowerPC::PowerPCState& ppc_state,
                                     const StoreLoopFillOperands& operands)
{
  const auto& [interpreter, reg_s, reg_b, stride, current_pc, per_iter_cycles] = operands;
  const s32 normal_distance = sizeof(AnyCallback) + sizeof(operands);

  const u32 count = CTR(ppc_state);
  // count <= 1: nothing to pre-fill (the single real iteration does everything; count==0 underflows to
  // a 2^32-iteration loop on real hardware, which we deliberately do NOT optimize). Bail to the records.
  if (count <= 1)
    return normal_distance;

  const u32 bulk_count = count - 1;  // iterations we bulk-fill; the records run the last one.
  // Overflow guard on total = bulk_count * stride (32-bit guest space). stride is small (M <= 60).
  if (stride != 0 && bulk_count > (0xFFFFFFFFu / stride))
    return normal_distance;
  const u32 total = bulk_count * stride;
  if (total == 0)
    return normal_distance;

  const u32 base = ppc_state.gpr[reg_b];
  const u8 value = static_cast<u8>(ppc_state.gpr[reg_s] & 0xFFu);

  PowerPC::MMU* const mmu = s_store_loop_mmu;
  Memory::MemoryManager* const memory = s_store_loop_memory;
  JitInterface* const jit = s_store_loop_jit;
  if (!mmu || !memory || !jit)  // handles only set when the feature is on; defensive
    return normal_distance;

  // --- RAM-not-MMIO guard (load-bearing): host pointer for the WHOLE [base, base+total) range. ---
  u8* const host = ResolveContiguousRamRange(*mmu, *memory, base, total);
  if (host == nullptr)
    return normal_distance;  // not contiguous normal RAM => run the real per-store loop unchanged.

  // --- Validate twin (MAIN_CIR_STORE_LOOP_FF_VALIDATE): sequence a real per-store reference run against
  // the bulk fill on a snapshot and assert equivalence. Memory can't be written twice, so: snapshot the
  // range + (rB,CTR); run the authoritative per-store loop (mmu Write_U8, exactly the loop's stores);
  // capture the reference (range, rB, CTR); restore; run the bulk path; compare. Trap on mismatch.
  if (s_store_loop_ff_validate) [[unlikely]]
  {
    std::vector<u8> before(total);
    std::memcpy(before.data(), host, total);

    // Reference: emulate bulk_count iterations of "M*stb(value) ; rB += M" via the real MMU store path.
    u32 ref_b = base;
    for (u32 it = 0; it < bulk_count; ++it)
    {
      for (u32 k = 0; k < stride; ++k)
        mmu->Write_U8(value, ref_b + k);
      ref_b += stride;
    }
    std::vector<u8> ref_range(total);
    std::memcpy(ref_range.data(), host, total);
    const u32 ref_rb = ref_b;  // base + bulk_count*stride

    // Restore memory so the bulk fill is the live write (no double-write commit).
    std::memcpy(host, before.data(), total);

    // Bulk path.
    std::memset(host, value, total);

    // Compare the filled range and the post-state rB the bulk path will commit.
    ASSERT_MSG(DYNA_REC, std::memcmp(host, ref_range.data(), total) == 0,
               "CIR store-loop validate: bulk range mismatch at pc {:#010x} (base {:#010x} total {})",
               current_pc, base, total);
    ASSERT_MSG(DYNA_REC, (base + total) == ref_rb,
               "CIR store-loop validate: rB mismatch at pc {:#010x} (bulk {:#010x} vs ref {:#010x})",
               current_pc, base + total, ref_rb);
  }
  else
  {
    std::memset(host, value, total);
  }

  // --- SMC / code coherency: the fill may overwrite cached code. Invalidate over the EFFECTIVE range
  // (InvalidateICache translates internally). ---
  jit->InvalidateICache(base, total, true);

  // --- Exact post-state: rB advanced by the bulk-filled bytes; leave CTR=1 so the real bdnz decrements
  // 1->0 and exits after the records run the FINAL iteration; reconcile downcount for the skipped
  // iterations (the records' EndBlock charges the final one). pc/npc are NOT written here (this is not a
  // terminal; write_pc is always false for this callback) — the records' stb/addi/bdnz set npc. ---
  ppc_state.gpr[reg_b] = base + total;  // base + (count-1)*stride
  CTR(ppc_state) = 1;
  ppc_state.downcount -= static_cast<s32>(bulk_count * per_iter_cycles);

  return normal_distance;
}

s32 CachedInterpreter::StoreLoopFill(std::ostream& stream, const StoreLoopFillOperands& operands)
{
  fmt::print(stream, "StoreLoopFill(rS=r{}, rB=r{}, M={}) at PC={:#010x}\n", operands.reg_s,
             operands.reg_b, operands.stride, operands.current_pc);
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

  // iCube: counted-store-loop (memset) fast-path recognition (MAIN_CIR_STORE_LOOP_FF, default OFF).
  // Scan the WHOLE built block once for the exact "M*stb + addi + bdnz self-loop" shape. On match,
  // before emitting the first stb record we emit a StoreLoopFill callback ALONGSIDE the unchanged
  // records (emit-alongside, like FastForwardCtrIdle). The records are kept verbatim, so a runtime guard
  // failure (range not contiguous normal RAM) or count==0 just runs the real loop. When OFF, the
  // recognizer never runs and nothing is emitted -> byte-identical to baseline. We disable the fast path
  // when debugging is on (the records must stay singly-steppable / breakpointable) — the callback would
  // bulk-fill across instruction boundaries a breakpoint inside the loop could otherwise catch.
  StoreLoopMatch store_loop;
  u32 store_loop_per_iter = 0;
  if (s_store_loop_ff && !IsDebuggingEnabled())
  {
    store_loop = RecognizeStoreLoop(m_code_buffer.data(), code_block.m_num_instructions, js.blockStart);
    if (store_loop.matched)
    {
      // per-iteration emulated cycles = sum of every op's num_cycles (== js.downcountAmount at the bdnz,
      // which the normal path charges once per dispatch == once per loop iteration).
      for (u32 k = 0; k < code_block.m_num_instructions; ++k)
        store_loop_per_iter += m_code_buffer[k].opinfo->num_cycles;
      // Log ONCE that only this exact shape is covered (no silent cap; stw/other shapes are future work).
      static bool logged_once = false;
      if (!logged_once)
      {
        logged_once = true;
        INFO_LOG_FMT(DYNA_REC,
                     "iCube CIR store-loop fast-path: recognized memset loop at {:#010x} "
                     "(M={} stb, rS=r{}, rB=r{}); only this exact stb+addi+bdnz shape is covered.",
                     js.blockStart, store_loop.stride, store_loop.reg_s, store_loop.reg_b);
      }
    }
  }

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
      // iCube: emit the counted-store-loop fill callback ALONGSIDE the records, immediately before the
      // first stb (i == 0). The unchanged stb/addi/bdnz records that follow run the FINAL iteration; the
      // handler bulk-fills the first count-1 strides and reconciles CTR/rB/downcount (see StoreLoopFill).
      if (store_loop.matched && i == 0)
      {
        Write(StoreLoopFill, {interpreter, store_loop.reg_s, store_loop.reg_b, store_loop.stride,
                              js.compilerPC, store_loop_per_iter});
      }
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

          // iCube: dead CR-flag elimination inside the fusion packer. The fused path bakes the
          // record-bit decision into MicroOp.rc at EMIT time (the runtime ExecuteMicroOps reads mu.rc, not
          // inst.Rc), so the "clear Rc in the instruction word" mechanism the generic/specialized paths use
          // does NOT reach it — we instead clear mu.rc here. When the flag is on AND this specific packed
          // op's ENTIRE crOut is discardable AND its CR write is Rc-gated (DeadFlagElimApplies), the fused
          // handler skips the dead CR0 exactly as the generic path would. Keyed on the per-op CodeOp (each
          // packed original has its own liveness), NOT the outer op. When the flag is off this is byte-
          // identical to `static_cast<u8>(c.inst.Rc)`. NOTE: the fusion validate harness masks these out of
          // its CR compare (see emit_fused) so the two stay compatible. The packer carries no validate of
          // its own for the elimination — the fusion validate already double-runs the real interpreter for
          // the ORIGINAL (Rc-set) ops, which catches a wrongly-skipped live flag as a CR mismatch.
          auto rc_of = [&](const PPCAnalyst::CodeOp& c) -> u8 {
            if (s_dead_flag_elim && DeadFlagElimApplies(c))
              return 0;
            return static_cast<u8>(c.inst.Rc);
          };
          // Union of crOut fields the packer eliminated across this run; fed to the fusion validate so its
          // all-8-field CR compare excludes the (proven-dead) eliminated fields and does not false-fire.
          BitSet8 packed_elim_cr{};

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
            // iCube: exclude the dead-flag-eliminated CR fields from the validate CR compare (the fused
            // run skipped them; the generic reference computed them). Empty when dead-flag-elim is off.
            vop.elim_cr_mask = static_cast<u32>(static_cast<u8>(packed_elim_cr.m_val));
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
                mu.rc = rc_of(next);
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
                mu.rc = rc_of(next);
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
                mu.rc = rc_of(next);
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
                  mu.rc = rc_of(next);
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
                  mu.rc = rc_of(next);
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
                  mu.rc = rc_of(next);
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
                  mu.rc = rc_of(next);
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
                  mu.rc = rc_of(next);
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
                  mu.rc = rc_of(next);
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
                  mu.rc = rc_of(next);
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
                  mu.rc = rc_of(next);
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
                  mu.rc = rc_of(next);
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
                  mu.rc = rc_of(next);
                  mu.imm = (next.inst.SUBOP10 == 712) ? 1u : 0u;
                  goto end_pack_switch;
                }
                case 26:  // cntlzwx
                  mu.op = MicroOpCode::CNTLZW;
                  mu.rd = next.inst.RA;
                  mu.ra = next.inst.RS;
                  mu.rb = 0;
                  mu.rc = rc_of(next);
                  mu.imm = 0;
                  goto end_pack_switch;
                case 954:  // extsbx
                  mu.op = MicroOpCode::EXTSB;
                  mu.rd = next.inst.RA;
                  mu.ra = next.inst.RS;
                  mu.rb = 0;
                  mu.rc = rc_of(next);
                  mu.imm = 0;
                  goto end_pack_switch;
                case 922:  // extshx
                  mu.op = MicroOpCode::EXTSH;
                  mu.rd = next.inst.RA;
                  mu.ra = next.inst.RS;
                  mu.rb = 0;
                  mu.rc = rc_of(next);
                  mu.imm = 0;
                  goto end_pack_switch;
                case 24:  // slwx
                  mu.op = MicroOpCode::SLW_VAR;
                  mu.rd = next.inst.RA;
                  mu.ra = next.inst.RS;
                  mu.rb = next.inst.RB;
                  mu.rc = rc_of(next);
                  mu.imm = 0;
                  goto end_pack_switch;
                case 536:  // srwx
                  mu.op = MicroOpCode::SRW_VAR;
                  mu.rd = next.inst.RA;
                  mu.ra = next.inst.RS;
                  mu.rb = next.inst.RB;
                  mu.rc = rc_of(next);
                  mu.imm = 0;
                  goto end_pack_switch;
                case 792:  // srawx
                  mu.op = MicroOpCode::SRAW_VAR;
                  mu.rd = next.inst.RA;
                  mu.ra = next.inst.RS;
                  mu.rb = next.inst.RB;
                  mu.rc = rc_of(next);
                  mu.imm = 0;
                  goto end_pack_switch;
                case 824:  // srawix
                  mu.op = MicroOpCode::SRAWI_IMM;
                  mu.rd = next.inst.RA;
                  mu.ra = next.inst.RS;
                  mu.rb = 0;
                  mu.rc = rc_of(next);
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
                mu.rc = rc_of(next);
                mu.imm = 0;
                break;
              }
              default:
                --mop.count;
                j = code_block.m_num_instructions;  // force stop
                break;
              }
            end_pack_switch:

              // iCube: record the CR fields this packed op had its record bit eliminated on (rc_of cleared
              // mu.rc), so the fusion validate can exclude them from its all-8-field CR compare. Keyed on
              // the per-op CodeOp (`next` == op[j_start]); only when the op was actually committed
              // (j < num: the force-stop default sets j = num and backed the op out). When the flag is off
              // DeadFlagElimApplies is bypassed and this stays empty — byte-identical to before.
              if (s_dead_flag_elim && j < code_block.m_num_instructions && DeadFlagElimApplies(next))
                packed_elim_cr |= next.crOut;

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

        // iCube: dead CR-flag elimination (MAIN_CIR_DEAD_FLAG_ELIM). The generic Interpret and the
        // specialized dispatch both decide "set CR0/CR1" by reading inst.Rc at RUNTIME (the specialized
        // switch calls the SAME opcode-keyed Interpreter::name handler the generic path would), so clearing
        // the Rc bit in the LOCAL operand instruction word makes BOTH skip the dead CR with the identical
        // battle-tested handler — no new handlers, no flag math. We NEVER mutate op.inst / m_code_buffer
        // (that would corrupt analysis/fusion/disasm); only this local copy is touched. func is keyed on
        // the ORIGINAL op.inst (opcode-identical for Rc 0/1). DeadFlagElimApplies enforces the FL_RC_BIT/
        // FL_RC_BIT_F guard, so always-record ops (andi./compares, whose bit 0 is immediate data, not Rc)
        // are excluded — clearing their "Rc" would corrupt the immediate AND not skip the CR. The PIC path
        // below is load/store-only (DeadFlagElimApplies is false for it), so it is unaffected. This op is
        // NOT on the InterpretAndCheckExceptions path (that branch is taken earlier, above the fusion
        // block) — and crDiscardable is reset at every canCauseException op anyway, so deadCR is false
        // there by construction. When the flag is off, dead is always false and inst == op.inst -> the
        // emitted stream is byte-identical to the flag-off baseline.
        const bool dead = s_dead_flag_elim && DeadFlagElimApplies(op);
        UGeckoInstruction elim_inst = op.inst;
        if (dead)
          elim_inst.Rc = 0;
        const auto func = Interpreter::GetInterpreterOp(op.inst);
        const InterpretOperands operands = {interpreter, func, js.compilerPC, elim_inst};
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
        // iCube: dead CR-flag elimination VALIDATE harness (MAIN_CIR_DEAD_FLAG_ELIM_VALIDATE). When BOTH
        // the elim flag and its validate flag are on, every eliminated op is emitted as a
        // InterpretDeadFlagValidate callback that double-runs (reference Rc-set inst vs the eliminated
        // Rc-cleared inst, the latter committed last = shipping behavior) and asserts every LIVE (non-
        // crOut) CR field matches — catching a wrongly-eliminated live flag. This supersedes the
        // specialized/generic emission for the op so the validation actually runs. Gated on `dead`, so
        // only the ops the shipping path would have eliminated pay the double-run; everything else takes
        // the unchanged paths below. Default OFF: when the validate flag is off this branch is never taken
        // and the eliminated op flows through the specialized/generic Interpret path with elim_inst.
        if (!emitted && dead && s_dead_flag_elim_validate)
        {
          // Aggregate-init the InterpretOperands base (copy-constructs its reference member) plus the two
          // added fields, mirroring SpecializedInterpretOperands' {operands, op_id} pattern. operands
          // carries the ELIMINATED (Rc-cleared) inst (the shipping run); ref_inst is the original Rc-set
          // inst (the CR reference); elim_cr_mask = op.crOut, the fields allowed to differ (all dead).
          const InterpretDeadFlagValidateOperands vop = {operands, op.inst,
                                                         static_cast<u32>(op.crOut.m_val)};
          Write(op.canEndBlock ? CallbackCast(InterpretDeadFlagValidate<true>) :
                                 CallbackCast(InterpretDeadFlagValidate<false>),
                vop);
          emitted = true;
        }
        // iCube: dead-FPRF elimination (MAIN_CIR_DEAD_FPRF_ELIM). For an arithmetic FP/PS op whose FPRF is
        // proven dead (FPRFElimApplies), emit InterpretFPRFElim — identical to the generic Interpret but
        // the handler runs inside the dead-FPRF hint window so UpdateFPRF*'s classify is skipped. `operands`
        // already carries elim_inst (with the Rc bit cleared if dead-CR elim also applied), so the two
        // eliminations COMPOSE: a `.`-form FP op with both CR1 and FPRF dead skips both. FP arithmetic ops
        // are never on the specialized whitelist or the integer-only PIC path, so this would otherwise fall
        // through to the generic Interpret below; emitting here supersedes that. When the validate flag is
        // on, route to the double-run harness instead (committed-last shipping run = the eliminated form).
        // Default OFF: when s_dead_fprf_elim is false no FP op is ever wrapped, so the stream is byte-
        // identical to the flag-off baseline AND the hint is never set true (the helpers never early-return).
        if (!emitted && s_dead_fprf_elim && FPRFElimApplies(op))
        {
          if (s_dead_fprf_elim_validate)
          {
            Write(op.canEndBlock ? CallbackCast(InterpretFPRFElimValidate<true>) :
                                   CallbackCast(InterpretFPRFElimValidate<false>),
                  operands);
          }
          else
          {
            Write(op.canEndBlock ? CallbackCast(InterpretFPRFElim<true>) :
                                   CallbackCast(InterpretFPRFElim<false>),
                  operands);
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
