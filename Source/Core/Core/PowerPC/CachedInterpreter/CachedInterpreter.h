// Copyright 2014 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <cstddef>

#include <rangeset/rangesizeset.h>

#include "Common/CommonTypes.h"
#include "Core/PowerPC/CachedInterpreter/CachedInterpreterBlockCache.h"
#include "Core/PowerPC/CachedInterpreter/CachedInterpreterEmitter.h"
#include "Core/PowerPC/Interpreter/Interpreter.h"
#include "Core/PowerPC/JitCommon/JitBase.h"
#include "Core/PowerPC/PPCAnalyst.h"

namespace CoreTiming
{
class CoreTimingManager;
}
namespace CPU
{
enum class State;
}

class CachedInterpreter : public JitBase, public CachedInterpreterCodeBlock
{
public:
  explicit CachedInterpreter(Core::System& system);
  CachedInterpreter(const CachedInterpreter&) = delete;
  CachedInterpreter(CachedInterpreter&&) = delete;
  CachedInterpreter& operator=(const CachedInterpreter&) = delete;
  CachedInterpreter& operator=(CachedInterpreter&&) = delete;
  ~CachedInterpreter() override;

  void Init() override;
  void Shutdown() override;

  bool HandleFault(uintptr_t access_address, SContext* ctx) override { return false; }
  void ClearCache() override;

  void Run() override;
  void SingleStep() override;

  void Jit(u32 address) override;
  void Jit(u32 address, bool clear_cache_and_retry_on_failure);
  bool DoJit(u32 address, JitBlock* b, u32 nextPC);

  void EraseSingleBlock(const JitBlock& block) override;
  std::vector<MemoryStats> GetMemoryStats() const override;

  static std::size_t Disassemble(const JitBlock& block, std::ostream& stream);

  std::size_t DisassembleNearCode(const JitBlock& block, std::ostream& stream) const override;
  std::size_t DisassembleFarCode(const JitBlock& block, std::ostream& stream) const override;

  JitBaseBlockCache* GetBlockCache() override { return &m_block_cache; }
  const char* GetName() const override { return "Cached Interpreter"; }
  const CommonAsmRoutinesBase* GetAsmRoutines() override { return nullptr; }

  // iCube: patch the relative link distance inside a LinkBlock trampoline. Called by
  // CachedInterpreterBlockCache::WriteLinkBlock through the upstream link/unlink machinery.
  // exit_ptrs points at the AnyCallback slot of the LinkBlock callback (== LinkData::exitPtrs).
  // rel is the byte distance from exit_ptrs to the target block's normalEntry, or 0 to unlink. The
  // layout (a single trailing s32 rel field) is owned here so the block cache need not see the
  // private operand struct.
  static void PatchLinkBlockRel(u8* exit_ptrs, s32 rel);

private:
  void ExecuteOneBlock();

  bool HandleFunctionHooking(u32 address);
  // iCube: link_target is the STATIC direct-branch destination (op.branchTo) of the terminal, or
  // UINT32_MAX for any non-static terminal (indirect branch, broken block, HLE replace, fall-through).
  // When block linking is enabled and the terminal is a linkable static branch, emits a LinkBlock
  // trampoline (and records the LinkData for upstream patching) instead of a plain EndBlock. Default
  // UINT32_MAX preserves the stock behavior for all the non-static call sites.
  void WriteEndBlock(u32 link_target = 0xFFFFFFFF);

  // Finds a free memory region and sets the code emitter to point at that region.
  // Returns false if no free memory region can be found.
  bool SetEmitterStateToFreeCodeRegion();

  void FreeRanges();
  void ResetFreeMemoryRanges();

  void LogGeneratedCode() const;

  struct StartProfiledBlockOperands;
  template <bool profiled>
  struct EndBlockOperands;
  // iCube: operands for the block-linking trampoline (MAIN_CIR_BLOCK_LINKING). See LinkBlock.
  struct LinkBlockOperands;
  struct InterpretOperands;
  struct InterpretAndCheckExceptionsOperands;
  struct HLEFunctionOperands;
  struct WriteBrokenBlockNPCOperands;
  struct CheckHaltOperands;
  struct CheckIdleOperands;
  struct CheckCtrIdleOperands;

  static s32 StartProfiledBlock(PowerPC::PowerPCState& ppc_state,
                                const StartProfiledBlockOperands& operands);
  static s32 StartProfiledBlock(std::ostream& stream, const StartProfiledBlockOperands& operands);
  template <bool profiled>
  static s32 EndBlock(PowerPC::PowerPCState& ppc_state, const EndBlockOperands<profiled>& operands);
  template <bool profiled>
  static s32 EndBlock(std::ostream& stream, const EndBlockOperands<profiled>& operands);
  // iCube: block-linking trampoline. Does the same end-of-block accounting as EndBlock<false>, then,
  // IFF the slice has budget left (downcount > 0) AND the architectural npc equals the static branch
  // target this exit was compiled for (expected_pc) AND the link has been patched (rel != 0),
  // returns the relative byte distance to the target block's callback stream so ExecuteOneBlock
  // continues into it WITHOUT a dispatcher round-trip. In every other case returns 0 (exit to the
  // dispatcher / Run loop) — fail-safe. rel is patched by CachedInterpreterBlockCache::WriteLinkBlock
  // through the upstream JitBaseBlockCache link/unlink machinery and is cleared (back to 0) whenever
  // the target block is destroyed/recompiled, so a stale link can never be followed.
  static s32 LinkBlock(PowerPC::PowerPCState& ppc_state, const LinkBlockOperands& operands);
  static s32 LinkBlock(std::ostream& stream, const LinkBlockOperands& operands);
  template <bool write_pc>
  static s32 Interpret(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);
  template <bool write_pc>
  static s32 Interpret(std::ostream& stream, const InterpretOperands& operands);
  // iCube: specialized variant of Interpret<write_pc>. Func is a compile-time-constant
  // Interpreter:: handler pointer, so the per-op call is direct (and inlinable under ThinLTO)
  // instead of the indirect operands.func(...) load+call. Reproduces the Interpret<write_pc>
  // bookkeeping contract EXACTLY: write_pc => pc=current_pc, npc=current_pc+4; run handler;
  // return sizeof(AnyCallback)+sizeof(InterpretOperands). Reuses the InterpretOperands payload
  // layout so dispatch advancement is identical. Gated by MAIN_CIR_SPECIALIZED_OPS at emit time.
  template <Interpreter::Instruction Func, bool write_pc>
  static s32 InterpretSpecialized(PowerPC::PowerPCState& ppc_state,
                                  const InterpretOperands& operands);
  template <bool write_pc>
  static s32 InterpretAndCheckExceptions(PowerPC::PowerPCState& ppc_state,
                                         const InterpretAndCheckExceptionsOperands& operands);
  template <bool write_pc>
  static s32 InterpretAndCheckExceptions(std::ostream& stream,
                                         const InterpretAndCheckExceptionsOperands& operands);
  static s32 HLEFunction(PowerPC::PowerPCState& ppc_state, const HLEFunctionOperands& operands);
  static s32 HLEFunction(std::ostream& stream, const HLEFunctionOperands& operands);
  static s32 WriteBrokenBlockNPC(PowerPC::PowerPCState& ppc_state,
                                 const WriteBrokenBlockNPCOperands& operands);
  static s32 WriteBrokenBlockNPC(std::ostream& stream, const WriteBrokenBlockNPCOperands& operands);
  static s32 CheckFPU(PowerPC::PowerPCState& ppc_state, const CheckHaltOperands& operands);
  static s32 CheckFPU(std::ostream& stream, const CheckHaltOperands& operands);
  static s32 CheckBreakpoint(PowerPC::PowerPCState& ppc_state, const CheckHaltOperands& operands);
  static s32 CheckBreakpoint(std::ostream& stream, const CheckHaltOperands& operands);
  static s32 CheckIdle(PowerPC::PowerPCState& ppc_state, const CheckIdleOperands& operands);
  static s32 CheckIdle(std::ostream& stream, const CheckIdleOperands& operands);
  static s32 FastForwardCtrIdle(PowerPC::PowerPCState& ppc_state,
                                const CheckCtrIdleOperands& operands);
  static s32 FastForwardCtrIdle(std::ostream& stream, const CheckCtrIdleOperands& operands);

  HyoutaUtilities::RangeSizeSet<u8*> m_free_ranges;
  CachedInterpreterBlockCache m_block_cache;
};

struct CachedInterpreter::StartProfiledBlockOperands
{
  JitBlock::ProfileData* profile_data;
};

template <>
struct CachedInterpreter::EndBlockOperands<false>
{
  u32 downcount;
  u32 num_load_stores;
  u32 num_fp_inst;
  u32 : 32;
};

template <>
struct CachedInterpreter::EndBlockOperands<true> : CachedInterpreter::EndBlockOperands<false>
{
  JitBlock::ProfileData* profile_data;
};

// iCube: payload for the block-linking trampoline (MAIN_CIR_BLOCK_LINKING). The first three fields
// mirror EndBlockOperands<false> so the accounting in LinkBlock is identical to EndBlock<false>.
// expected_pc is the STATIC branch target (op.branchTo) this exit was compiled for — LinkBlock only
// follows the link when ppc_state.npc == expected_pc (fail-safe deopt otherwise). rel is the patched
// relative distance (bytes) from the start of THIS callback (the AnyCallback slot) to the target
// block's normalEntry; 0 means "not linked / unlinked" and forces a dispatcher exit. rel is the ONLY
// field WriteLinkBlock mutates after emit. Layout is 24 bytes = 3*alignof(AnyCallback) (8 on arm64),
// trivially copyable, satisfying CachedInterpreterEmitter::Write's size/alignment static_assert.
struct CachedInterpreter::LinkBlockOperands
{
  u32 downcount;
  u32 num_load_stores;
  u32 num_fp_inst;
  u32 expected_pc;
  // Reserved: the feature_flags the source block was compiled under. Recorded at emit for parity with
  // the JitBlock and possible future cross-flag checks; validate-mode instead compares the LIVE
  // ppc_state.feature_flags against the resolved target block, which is the authoritative check.
  u32 feature_flags;
  s32 rel;
};

struct CachedInterpreter::InterpretOperands
{
  Interpreter& interpreter;
  void (*func)(Interpreter&, UGeckoInstruction);  // Interpreter::Instruction
  u32 current_pc;
  UGeckoInstruction inst;
};

struct CachedInterpreter::InterpretAndCheckExceptionsOperands : InterpretOperands
{
  PowerPC::PowerPCManager& power_pc;
  u32 downcount;
};

struct CachedInterpreter::HLEFunctionOperands
{
  Core::System& system;
  u32 current_pc;
  u32 hook_index;
};

struct CachedInterpreter::WriteBrokenBlockNPCOperands
{
  u32 current_pc;
  u32 : 32;
};

struct CachedInterpreter::CheckHaltOperands
{
  PowerPC::PowerPCManager& power_pc;
  u32 current_pc;
  u32 downcount;
};

struct CachedInterpreter::CheckIdleOperands
{
  CoreTiming::CoreTimingManager& core_timing;
  u32 idle_pc;
};

struct CachedInterpreter::CheckCtrIdleOperands
{
  CoreTiming::CoreTimingManager& core_timing;
  u32 idle_pc;         // PC of the CTR-branch at loop end
  u32 fallthrough_pc;  // PC after the branch (loop exit)
};
