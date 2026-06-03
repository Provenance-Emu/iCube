// Copyright 2014 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Core/PowerPC/CachedInterpreter/CachedInterpreter.h"

#include <algorithm>
#include <array>
#include <span>
#include <sstream>
#include <utility>

#include <fmt/format.h>
#include <fmt/ostream.h>

#include "Common/Assert.h"
#include "Common/CommonTypes.h"
#include "Common/GekkoDisassembler.h"
#include "Common/Config/Config.h"
#include "Common/Logging/Log.h"
#include "Core/Config/MainSettings.h"
#include "Core/ConfigManager.h"
#include "Core/Core.h"
#include "Core/CoreTiming.h"
#include "Core/HLE/HLE.h"
#include "Core/HW/CPU.h"
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

void CachedInterpreter::Init()
{
  RefreshConfig();
  s_specialized_ops = Config::Get(Config::MAIN_CIR_SPECIALIZED_OPS);
  s_specialized_ops_validate = Config::Get(Config::MAIN_CIR_SPECIALIZED_OPS_VALIDATE);
  s_block_linking = Config::Get(Config::MAIN_CIR_BLOCK_LINKING);
  s_block_linking_validate = Config::Get(Config::MAIN_CIR_BLOCK_LINKING_VALIDATE);
  s_validate_instance = s_block_linking_validate ? this : nullptr;

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

void CachedInterpreter::ExecuteOneBlock()
{
  const u8* normal_entry = m_block_cache.Dispatch();
  if (!normal_entry)
  {
    Jit(m_ppc_state.pc);
    return;
  }

  auto& ppc_state = m_ppc_state;
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
      ExecuteOneBlock();
    } while (m_ppc_state.downcount > 0 && *state_ptr == CPU::State::Running);
  }
}

void CachedInterpreter::SingleStep()
{
  // Enter new timing slice
  m_system.GetCoreTiming().Advance();
  ExecuteOneBlock();
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
    if (IsProfilingEnabled())
    {
      Write(EndBlock<true>, {{js.downcountAmount, js.numLoadStoreInst, js.numFloatingPointInst},
                             js.curBlock->profile_data.get()});
    }
    else
    {
      Write(EndBlock<false>, {js.downcountAmount, js.numLoadStoreInst, js.numFloatingPointInst});
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
                                      0};
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
        const auto func = Interpreter::GetInterpreterOp(op.inst);
        const InterpretOperands operands = {interpreter, func, js.compilerPC, op.inst};
        // iCube: route whitelisted hot ops to the specialized dispatch when MAIN_CIR_SPECIALIZED_OPS
        // is on. We emit ONE of two marker callbacks (write_pc false/true) plus a
        // SpecializedInterpretOperands payload that carries the InterpretOperands prefix verbatim and
        // the compact op-id ExecuteOneBlock jump-tables on. write_pc == op.canEndBlock, matching the
        // generic Interpret selection. Cold/non-whitelisted ops fall through to the unchanged generic
        // emission below — and when the flag is OFF, no marker callback is ever written, so the
        // dispatch never takes the specialized branch (flag-off stream is byte-identical to stock).
        bool emitted = false;
        if (s_specialized_ops && IsSpecializedOp(func))
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
