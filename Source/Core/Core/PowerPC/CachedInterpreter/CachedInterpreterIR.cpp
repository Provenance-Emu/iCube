// Copyright 2026 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Core/PowerPC/CachedInterpreter/CachedInterpreterIR.h"

#include <algorithm>
#include <array>
#include <cstdlib>
#include <mutex>
#include <ranges>
#include <span>
#include <sstream>
#include <utility>

#include <fmt/format.h>
#include <fmt/ostream.h>

#include "Common/Assert.h"
#include "Common/CommonTypes.h"
#include "Common/GekkoDisassembler.h"
#include "Common/Logging/Log.h"
#include "Core/ConfigManager.h"
#include "Core/Core.h"
#include "Core/CoreTiming.h"
#include "Core/HLE/HLE.h"
#include "Core/HW/CPU.h"
#include "Core/Host.h"
#include "Core/PowerPC/Gekko.h"
#include "Core/PowerPC/Interpreter/Interpreter.h"
#include "Core/PowerPC/Jit64Common/Jit64Constants.h"  // CODE_SIZE
#include "Core/PowerPC/PPCAnalyst.h"
#include "Core/PowerPC/PowerPC.h"
#include "Core/System.h"

// ============================================================================
// Self-contained block cache (mirrors CachedInterpreterBlockCache, minus block linking).
// ============================================================================

CachedInterpreterIRBlockCache::CachedInterpreterIRBlockCache(JitBase& jit) : JitBaseBlockCache{jit}
{
}

void CachedInterpreterIRBlockCache::Init()
{
  JitBaseBlockCache::Init();
  ClearRangesToFree();
}

void CachedInterpreterIRBlockCache::DestroyBlock(JitBlock& block)
{
  // Free this block's IR vector from the engine's side table before the block storage goes away.
  static_cast<CachedInterpreterIR&>(m_jit).ReleaseBlockIR(block);

  JitBaseBlockCache::DestroyBlock(block);

  if (block.near_begin != block.near_end)
    m_ranges_to_free_on_next_codegen.emplace_back(block.near_begin, block.near_end);
}

void CachedInterpreterIRBlockCache::ClearRangesToFree()
{
  m_ranges_to_free_on_next_codegen.clear();
}

void CachedInterpreterIRBlockCache::WriteLinkBlock(const JitBlock::LinkData& source,
                                                   const JitBlock* dest)
{
  // M0 never enables block linking (jo.enableBlocklink stays false), so no LinkData is ever pushed and
  // this is never invoked. Implemented as a no-op for completeness; reintroduced as an IR pass later.
}

void CachedInterpreterIRBlockCache::WriteDestroyBlock(const JitBlock& block)
{
  CachedInterpreterEmitter emitter(block.normalEntry, block.near_end);
  emitter.Write(CachedInterpreterEmitter::PoisonCallback);
}

// ============================================================================
// CachedInterpreterIR
// ============================================================================

CachedInterpreterIR::CachedInterpreterIR(Core::System& system)
    : JitBase(system), m_block_cache(*this)
{
}

CachedInterpreterIR::~CachedInterpreterIR() = default;

void CachedInterpreterIR::Init()
{
  RefreshConfig();

  AllocCodeSpace(CODE_SIZE);
  ResetFreeMemoryRanges();

  // M0: block linking off (stock data-interpreted behavior). Reintroduced as an IR pass later.
  jo.enableBlocklink = false;

  m_block_cache.Init();

  code_block.m_stats = &js.st;
  code_block.m_gpa = &js.gpa;
  code_block.m_fpa = &js.fpa;
}

void CachedInterpreterIR::Shutdown()
{
  m_block_cache.Shutdown();
}

s32 CachedInterpreterIR::StartProfiledBlock(PowerPC::PowerPCState& ppc_state,
                                            const StartProfiledBlockOperands& operands)
{
  JitBlock::ProfileData::BeginProfiling(operands.profile_data);
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool profiled>
s32 CachedInterpreterIR::EndBlock(PowerPC::PowerPCState& ppc_state,
                                  const EndBlockOperands<profiled>& operands)
{
  ppc_state.pc = ppc_state.npc;
  ppc_state.downcount -= operands.downcount;
  if (PowerPC::PerformanceMonitorActive(ppc_state))
    PowerPC::UpdatePerformanceMonitor(operands.downcount, operands.num_load_stores,
                                      operands.num_fp_inst, ppc_state);
  if constexpr (profiled)
    JitBlock::ProfileData::EndProfiling(operands.profile_data, operands.downcount);
  return 0;
}

template <bool write_pc>
s32 CachedInterpreterIR::Interpret(PowerPC::PowerPCState& ppc_state,
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

template <bool write_pc>
s32 CachedInterpreterIR::InterpretAndCheckExceptions(
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

s32 CachedInterpreterIR::HLEFunction(PowerPC::PowerPCState& ppc_state,
                                     const HLEFunctionOperands& operands)
{
  const auto& [system, current_pc, hook_index] = operands;
  ppc_state.pc = current_pc;
  HLE::Execute(Core::CPUThreadGuard{system}, current_pc, hook_index);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::WriteBrokenBlockNPC(PowerPC::PowerPCState& ppc_state,
                                             const WriteBrokenBlockNPCOperands& operands)
{
  const auto& [current_pc] = operands;
  ppc_state.npc = current_pc;
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::CheckFPU(PowerPC::PowerPCState& ppc_state,
                                  const CheckHaltOperands& operands)
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

s32 CachedInterpreterIR::CheckBreakpoint(PowerPC::PowerPCState& ppc_state,
                                         const CheckHaltOperands& operands)
{
  const auto& [power_pc, current_pc, downcount] = operands;
  ppc_state.pc = current_pc;
  if (power_pc.CheckAndHandleBreakPoints())
  {
    power_pc.GetPPCState().downcount -= downcount;
    return 0;
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::CheckIdle(PowerPC::PowerPCState& ppc_state,
                                   const CheckIdleOperands& operands)
{
  const auto& [core_timing, idle_pc] = operands;
  if (ppc_state.npc == idle_pc)
    core_timing.Idle();
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::FastForwardCtrIdle(PowerPC::PowerPCState& ppc_state,
                                            const CheckCtrIdleOperands& operands)
{
  const auto& [core_timing, idle_pc, fallthrough_pc] = operands;
  if (ppc_state.npc == idle_pc)
  {
    CTR(ppc_state) = 0;
    ppc_state.pc = idle_pc;
    ppc_state.npc = fallthrough_pc;
    core_timing.Idle();
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

// The single record M0-style plumbing still writes into the emitter buffer per block. It only marks
// the block's storage (so near_begin/near_end/reclamation/Dispatch-by-normalEntry keep working) and
// carries a pointer to that block's IR vector. It is never executed by ExecuteOneBlock (which
// recovers the vector directly), so it just returns "exit block" if ever reached.
s32 CachedInterpreterIR::IRBlockAnchor(PowerPC::PowerPCState& ppc_state,
                                       const IRBlockAnchorOperands& operands)
{
  return 0;
}

// Dispatches one lowered IRInst to the matching static handler with fields unpacked from the union.
// Each handler keeps its exact M0 logic; only the return value's 0-vs-nonzero meaning is used here
// (0 => exit block), so the dispatch contract is preserved exactly. The handlers' nonzero "distance"
// returns are intentionally ignored — iteration advances over the IR vector instead.
s32 CachedInterpreterIR::DispatchIRInst(PowerPC::PowerPCState& ppc_state, const IRInst& inst)
{
  switch (inst.op)
  {
  case IROp::StartProfiledBlock:
    return StartProfiledBlock(ppc_state, inst.u.start_profiled_block);
  case IROp::EndBlock:
    return EndBlock<false>(ppc_state, inst.u.end_block);
  case IROp::EndBlockProfiled:
    return EndBlock<true>(ppc_state, inst.u.end_block_profiled);
  case IROp::Interpret:
    return Interpret<false>(ppc_state, inst.u.interpret);
  case IROp::InterpretPC:
    return Interpret<true>(ppc_state, inst.u.interpret);
  case IROp::InterpretChk:
    return InterpretAndCheckExceptions<false>(ppc_state, inst.u.interpret_chk);
  case IROp::InterpretChkPC:
    return InterpretAndCheckExceptions<true>(ppc_state, inst.u.interpret_chk);
  case IROp::HLEFunction:
    return HLEFunction(ppc_state, inst.u.hle);
  case IROp::WriteBrokenBlockNPC:
    return WriteBrokenBlockNPC(ppc_state, inst.u.broken_npc);
  case IROp::CheckFPU:
    return CheckFPU(ppc_state, inst.u.check_halt);
  case IROp::CheckBreakpoint:
    return CheckBreakpoint(ppc_state, inst.u.check_halt);
  case IROp::CheckIdle:
    return CheckIdle(ppc_state, inst.u.check_idle);
  case IROp::FastForwardCtrIdle:
    return FastForwardCtrIdle(ppc_state, inst.u.ctr_idle);
  }
  return 0;
}

void CachedInterpreterIR::ReleaseBlockIR(const JitBlock& block)
{
  m_block_ir.erase(block.normalEntry);
}

void CachedInterpreterIR::ExecuteOneBlock()
{
  const u8* normal_entry = m_block_cache.Dispatch();
  if (!normal_entry)
  {
    Jit(m_ppc_state.pc);
    return;
  }

  // Recover the block's IR vector from the anchor record at its normalEntry.
  const auto& anchor = *reinterpret_cast<const IRBlockAnchorOperands*>(normal_entry +
                                                                       sizeof(AnyCallback));
  const std::vector<IRInst>& ir = *anchor.ir;

  auto& ppc_state = m_ppc_state;
  for (const IRInst& inst : ir)
  {
    if (DispatchIRInst(ppc_state, inst) == 0)
      break;
  }
}

// DOLPHIN_IR_VALIDATE=1 self-check. The IR vector was lowered 1:1 in DoJit; in parallel, each Emit*
// also wrote the equivalent M0 callback record into m_validate_buffer. Here we walk that independent
// M0 tape and assert, record by record, that the lowered IRInst matches: same count, the IROp maps
// to exactly the callback M0 used (the op<->callback bijection from Disassemble's lookup), and the
// operands are field-wise equal. Any mismatch traps. Default off => zero overhead in normal runs.
void CachedInterpreterIR::ValidateBlockIR(const std::vector<IRInst>& ir) const
{
  const u8* p = m_validate_buffer.data();
  const u8* end = m_validate_emitter.GetCodePtr();

  std::size_t idx = 0;
  for (; p != end; ++idx)
  {
    ASSERT_MSG(DYNA_REC, idx < ir.size(),
               "IR self-check: M0 tape has more records ({}+) than IR vector ({}).", idx + 1,
               ir.size());
    if (idx >= ir.size())
      return;

    const auto callback = *reinterpret_cast<const AnyCallback*>(p);
    const void* m0 = p + sizeof(AnyCallback);
    const IRInst& inst = ir[idx];

    const auto check = [&](IROp expected_op, bool operands_equal, std::size_t operand_size) {
      ASSERT_MSG(DYNA_REC, inst.op == expected_op,
                 "IR self-check: record {} op mismatch (IR={}, M0={}).", idx,
                 static_cast<int>(inst.op), static_cast<int>(expected_op));
      ASSERT_MSG(DYNA_REC, operands_equal, "IR self-check: record {} operand mismatch (op={}).", idx,
                 static_cast<int>(expected_op));
      p += sizeof(AnyCallback) + operand_size;
    };

    // Field-wise operand comparisons (no raw memcmp: EndBlockOperands<false> has an explicit
    // padding bitfield whose bytes are indeterminate and would cause false mismatches).
#define CB(fn) reinterpret_cast<AnyCallback>(AnyCallbackCast(fn))
    if (callback == CB(StartProfiledBlock))
    {
      const auto& o = *reinterpret_cast<const StartProfiledBlockOperands*>(m0);
      const auto& a = inst.u.start_profiled_block;
      check(IROp::StartProfiledBlock, a.profile_data == o.profile_data, sizeof(o));
    }
    else if (callback == CB(EndBlock<false>))
    {
      const auto& o = *reinterpret_cast<const EndBlockOperands<false>*>(m0);
      const auto& a = inst.u.end_block;
      check(IROp::EndBlock,
            a.downcount == o.downcount && a.num_load_stores == o.num_load_stores &&
                a.num_fp_inst == o.num_fp_inst,
            sizeof(o));
    }
    else if (callback == CB(EndBlock<true>))
    {
      const auto& o = *reinterpret_cast<const EndBlockOperands<true>*>(m0);
      const auto& a = inst.u.end_block_profiled;
      check(IROp::EndBlockProfiled,
            a.downcount == o.downcount && a.num_load_stores == o.num_load_stores &&
                a.num_fp_inst == o.num_fp_inst && a.profile_data == o.profile_data,
            sizeof(o));
    }
    else if (callback == CB(Interpret<false>))
    {
      const auto& o = *reinterpret_cast<const InterpretOperands*>(m0);
      const auto& a = inst.u.interpret;
      check(IROp::Interpret,
            &a.interpreter == &o.interpreter && a.func == o.func && a.current_pc == o.current_pc &&
                a.inst.hex == o.inst.hex,
            sizeof(o));
    }
    else if (callback == CB(Interpret<true>))
    {
      const auto& o = *reinterpret_cast<const InterpretOperands*>(m0);
      const auto& a = inst.u.interpret;
      check(IROp::InterpretPC,
            &a.interpreter == &o.interpreter && a.func == o.func && a.current_pc == o.current_pc &&
                a.inst.hex == o.inst.hex,
            sizeof(o));
    }
    else if (callback == CB(InterpretAndCheckExceptions<false>))
    {
      const auto& o = *reinterpret_cast<const InterpretAndCheckExceptionsOperands*>(m0);
      const auto& a = inst.u.interpret_chk;
      check(IROp::InterpretChk,
            &a.interpreter == &o.interpreter && a.func == o.func && a.current_pc == o.current_pc &&
                a.inst.hex == o.inst.hex && &a.power_pc == &o.power_pc && a.downcount == o.downcount,
            sizeof(o));
    }
    else if (callback == CB(InterpretAndCheckExceptions<true>))
    {
      const auto& o = *reinterpret_cast<const InterpretAndCheckExceptionsOperands*>(m0);
      const auto& a = inst.u.interpret_chk;
      check(IROp::InterpretChkPC,
            &a.interpreter == &o.interpreter && a.func == o.func && a.current_pc == o.current_pc &&
                a.inst.hex == o.inst.hex && &a.power_pc == &o.power_pc && a.downcount == o.downcount,
            sizeof(o));
    }
    else if (callback == CB(HLEFunction))
    {
      const auto& o = *reinterpret_cast<const HLEFunctionOperands*>(m0);
      const auto& a = inst.u.hle;
      check(IROp::HLEFunction,
            &a.system == &o.system && a.current_pc == o.current_pc && a.hook_index == o.hook_index,
            sizeof(o));
    }
    else if (callback == CB(WriteBrokenBlockNPC))
    {
      const auto& o = *reinterpret_cast<const WriteBrokenBlockNPCOperands*>(m0);
      const auto& a = inst.u.broken_npc;
      check(IROp::WriteBrokenBlockNPC, a.current_pc == o.current_pc, sizeof(o));
    }
    else if (callback == CB(CheckFPU))
    {
      const auto& o = *reinterpret_cast<const CheckHaltOperands*>(m0);
      const auto& a = inst.u.check_halt;
      check(IROp::CheckFPU,
            &a.power_pc == &o.power_pc && a.current_pc == o.current_pc && a.downcount == o.downcount,
            sizeof(o));
    }
    else if (callback == CB(CheckBreakpoint))
    {
      const auto& o = *reinterpret_cast<const CheckHaltOperands*>(m0);
      const auto& a = inst.u.check_halt;
      check(IROp::CheckBreakpoint,
            &a.power_pc == &o.power_pc && a.current_pc == o.current_pc && a.downcount == o.downcount,
            sizeof(o));
    }
    else if (callback == CB(CheckIdle))
    {
      const auto& o = *reinterpret_cast<const CheckIdleOperands*>(m0);
      const auto& a = inst.u.check_idle;
      check(IROp::CheckIdle, &a.core_timing == &o.core_timing && a.idle_pc == o.idle_pc, sizeof(o));
    }
    else if (callback == CB(FastForwardCtrIdle))
    {
      const auto& o = *reinterpret_cast<const CheckCtrIdleOperands*>(m0);
      const auto& a = inst.u.ctr_idle;
      check(IROp::FastForwardCtrIdle,
            &a.core_timing == &o.core_timing && a.idle_pc == o.idle_pc &&
                a.fallthrough_pc == o.fallthrough_pc,
            sizeof(o));
    }
    else
    {
      ASSERT_MSG(DYNA_REC, false, "IR self-check: unknown M0 callback in record {}.", idx);
      return;
    }
#undef CB
  }

  ASSERT_MSG(DYNA_REC, idx == ir.size(),
             "IR self-check: count mismatch (M0={}, IR={}).", idx, ir.size());
}

void CachedInterpreterIR::Run()
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

void CachedInterpreterIR::SingleStep()
{
  // Enter new timing slice
  m_system.GetCoreTiming().Advance();
  ExecuteOneBlock();
}

bool CachedInterpreterIR::HandleFunctionHooking(u32 address)
{
  // CachedInterpreterIR inherits from JitBase and is considered a JIT by relevant code.
  const auto result = HLE::TryReplaceFunction(m_ppc_symbol_db, address, PowerPC::CoreMode::JIT);
  if (!result)
    return false;

  EmitHLEFunction({m_system, address, result.hook_index});

  if (result.type != HLE::HookType::Replace)
    return false;

  js.downcountAmount += js.st.numCycles;
  WriteEndBlock();
  return true;
}

void CachedInterpreterIR::WriteEndBlock()
{
  if (IsProfilingEnabled())
  {
    EmitEndBlock<true>({{js.downcountAmount, js.numLoadStoreInst, js.numFloatingPointInst},
                        js.curBlock->profile_data.get()});
  }
  else
  {
    EmitEndBlock<false>({js.downcountAmount, js.numLoadStoreInst, js.numFloatingPointInst});
  }
}

// ----------------------------------------------------------------------------
// IR emit helpers. Each appends exactly one IRInst (1:1 with the M0 callback it mirrors). Under
// DOLPHIN_IR_VALIDATE=1 each also writes the equivalent M0 callback record into the scratch buffer
// so ValidateBlockIR can diff the lowered IR against an independent M0 serialization.
// ----------------------------------------------------------------------------
void CachedInterpreterIR::EmitStartProfiledBlock(const StartProfiledBlockOperands& operands)
{
  m_current_ir->push_back(IRInst{IROp::StartProfiledBlock, {.start_profiled_block = operands}});
  if (m_validate) [[unlikely]]
    m_validate_emitter.Write(StartProfiledBlock, operands);
}

template <bool profiled>
void CachedInterpreterIR::EmitEndBlock(const EndBlockOperands<profiled>& operands)
{
  if constexpr (profiled)
    m_current_ir->push_back(IRInst{IROp::EndBlockProfiled, {.end_block_profiled = operands}});
  else
    m_current_ir->push_back(IRInst{IROp::EndBlock, {.end_block = operands}});
  if (m_validate) [[unlikely]]
    m_validate_emitter.Write(EndBlock<profiled>, operands);
}

template <bool write_pc>
void CachedInterpreterIR::EmitInterpret(const InterpretOperands& operands)
{
  m_current_ir->push_back(
      IRInst{write_pc ? IROp::InterpretPC : IROp::Interpret, {.interpret = operands}});
  if (m_validate) [[unlikely]]
    m_validate_emitter.Write(Interpret<write_pc>, operands);
}

template <bool write_pc>
void CachedInterpreterIR::EmitInterpretChk(const InterpretAndCheckExceptionsOperands& operands)
{
  m_current_ir->push_back(
      IRInst{write_pc ? IROp::InterpretChkPC : IROp::InterpretChk, {.interpret_chk = operands}});
  if (m_validate) [[unlikely]]
    m_validate_emitter.Write(InterpretAndCheckExceptions<write_pc>, operands);
}

void CachedInterpreterIR::EmitHLEFunction(const HLEFunctionOperands& operands)
{
  m_current_ir->push_back(IRInst{IROp::HLEFunction, {.hle = operands}});
  if (m_validate) [[unlikely]]
    m_validate_emitter.Write(HLEFunction, operands);
}

void CachedInterpreterIR::EmitWriteBrokenBlockNPC(const WriteBrokenBlockNPCOperands& operands)
{
  m_current_ir->push_back(IRInst{IROp::WriteBrokenBlockNPC, {.broken_npc = operands}});
  if (m_validate) [[unlikely]]
    m_validate_emitter.Write(WriteBrokenBlockNPC, operands);
}

void CachedInterpreterIR::EmitCheckFPU(const CheckHaltOperands& operands)
{
  m_current_ir->push_back(IRInst{IROp::CheckFPU, {.check_halt = operands}});
  if (m_validate) [[unlikely]]
    m_validate_emitter.Write(CheckFPU, operands);
}

void CachedInterpreterIR::EmitCheckBreakpoint(const CheckHaltOperands& operands)
{
  m_current_ir->push_back(IRInst{IROp::CheckBreakpoint, {.check_halt = operands}});
  if (m_validate) [[unlikely]]
    m_validate_emitter.Write(CheckBreakpoint, operands);
}

void CachedInterpreterIR::EmitCheckIdle(const CheckIdleOperands& operands)
{
  m_current_ir->push_back(IRInst{IROp::CheckIdle, {.check_idle = operands}});
  if (m_validate) [[unlikely]]
    m_validate_emitter.Write(CheckIdle, operands);
}

void CachedInterpreterIR::EmitFastForwardCtrIdle(const CheckCtrIdleOperands& operands)
{
  m_current_ir->push_back(IRInst{IROp::FastForwardCtrIdle, {.ctr_idle = operands}});
  if (m_validate) [[unlikely]]
    m_validate_emitter.Write(FastForwardCtrIdle, operands);
}

bool CachedInterpreterIR::SetEmitterStateToFreeCodeRegion()
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

void CachedInterpreterIR::FreeRanges()
{
  for (const auto& [from, to] : m_block_cache.GetRangesToFree())
    m_free_ranges.insert(from, to);
  m_block_cache.ClearRangesToFree();
}

void CachedInterpreterIR::ResetFreeMemoryRanges()
{
  m_free_ranges.clear();
  m_free_ranges.insert(region, region + region_size);
}

void CachedInterpreterIR::Jit(u32 em_address)
{
  Jit(em_address, true);
}

void CachedInterpreterIR::Jit(u32 em_address, bool clear_cache_and_retry_on_failure)
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

bool CachedInterpreterIR::DoJit(u32 em_address, JitBlock* b, u32 nextPC)
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

  // M1: lower this block into an explicit IRInst vector instead of a callback tape. Build into a
  // fresh vector, then attach it to the block via a single anchor record written to the emitter
  // buffer (preserving near_begin/near_end/reclamation/Dispatch-by-normalEntry).
  auto ir = std::make_unique<std::vector<IRInst>>();
  m_current_ir = ir.get();

  static const bool s_validate = [] {
    const char* v = std::getenv("DOLPHIN_IR_VALIDATE");
    return v && v[0] == '1';
  }();
  m_validate = s_validate;
  if (m_validate)
  {
    // Generous scratch buffer for the parallel M0 emission used only for the 1:1 self-check.
    m_validate_buffer.assign(m_code_buffer.size() * 64 + 256, 0);
    m_validate_emitter.SetCodePtr(m_validate_buffer.data(),
                                  m_validate_buffer.data() + m_validate_buffer.size());
  }

  if (IsProfilingEnabled())
    EmitStartProfiledBlock({js.curBlock->profile_data.get()});

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
        EmitCheckBreakpoint({power_pc, js.compilerPC, js.downcountAmount});
      }
      if (!js.firstFPInstructionFound && (op.opinfo->flags & FL_USE_FPU) != 0)
      {
        EmitCheckFPU({power_pc, js.compilerPC, js.downcountAmount});
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
        if (op.canEndBlock)
          EmitInterpretChk<true>(operands);
        else
          EmitInterpretChk<false>(operands);
      }
      else
      {
        const auto func = Interpreter::GetInterpreterOp(op.inst);
        const InterpretOperands operands = {interpreter, func, js.compilerPC, op.inst};
        if (op.canEndBlock)
          EmitInterpret<true>(operands);
        else
          EmitInterpret<false>(operands);
      }

      if (op.branchIsIdleLoop)
        EmitCheckIdle({m_system.GetCoreTiming(), js.blockStart});
      // For simple CTR-controlled tight loops, fast-forward by exiting the loop and yielding.
      if (op.branchIsCtrIdleLoop)
      {
        const u32 fallthrough_pc = op.address + 4;
        EmitFastForwardCtrIdle({m_system.GetCoreTiming(), js.blockStart, fallthrough_pc});
      }
      if (op.canEndBlock)
        WriteEndBlock();
    }
  }
  if (code_block.m_broken)
  {
    EmitWriteBrokenBlockNPC({nextPC});
    WriteEndBlock();
  }

  m_current_ir = nullptr;

  // Opt-in 1:1 self-check against an independent M0 callback emission.
  if (m_validate) [[unlikely]]
    ValidateBlockIR(*ir);

  // Write the single anchor record. This sets b->normalEntry/near_begin..near_end and is the key
  // the side table is indexed by. If the emitter is out of space, fail exactly like M0.
  Write(IRBlockAnchor, {ir.get()});
  if (HasWriteFailed())
  {
    WARN_LOG_FMT(DYNA_REC, "JIT ran out of space in code region during code generation.");
    return false;
  }

  m_block_ir.insert_or_assign(b->normalEntry, std::move(ir));
  return true;
}

void CachedInterpreterIR::EraseSingleBlock(const JitBlock& block)
{
  m_block_cache.EraseSingleBlock(block);
  FreeRanges();
}

std::vector<JitBase::MemoryStats> CachedInterpreterIR::GetMemoryStats() const
{
  return {{"free", m_free_ranges.get_stats()}};
}

std::size_t CachedInterpreterIR::DisassembleNearCode(const JitBlock& block,
                                                     std::ostream& stream) const
{
  return Disassemble(block, stream);
}

std::size_t CachedInterpreterIR::DisassembleFarCode(const JitBlock& block,
                                                    std::ostream& stream) const
{
  stream << "N/A\n";
  return 0;
}

void CachedInterpreterIR::ClearCache()
{
  m_block_ir.clear();
  m_block_cache.Clear();
  m_block_cache.ClearRangesToFree();
  ClearCodeSpace();
  ResetFreeMemoryRanges();
  RefreshConfig();
  Host_JitCacheInvalidation();
}

void CachedInterpreterIR::LogGeneratedCode() const
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

  DEBUG_LOG_FMT(DYNA_REC, "{}", std::move(stream).str());
}

// ============================================================================
// Disassembler (debug) — ostream overloads + the callback->disassembler lookup table.
// ============================================================================

s32 CachedInterpreterIR::StartProfiledBlock(std::ostream& stream,
                                            const StartProfiledBlockOperands& operands)
{
  stream << "StartProfiledBlock()\n";
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool profiled>
s32 CachedInterpreterIR::EndBlock(std::ostream& stream, const EndBlockOperands<profiled>& operands)
{
  fmt::println(stream, "EndBlock<profiled={}>(downcount={}, num_load_stores={}, num_fp_inst={})",
               profiled, operands.downcount, operands.num_load_stores, operands.num_fp_inst);
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
s32 CachedInterpreterIR::Interpret(std::ostream& stream, const InterpretOperands& operands)
{
  fmt::println(stream, "Interpret<write_pc={:5}>(current_pc=0x{:08x}, inst=0x{:08x})", write_pc,
               operands.current_pc, operands.inst.hex);
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
s32 CachedInterpreterIR::InterpretAndCheckExceptions(
    std::ostream& stream, const InterpretAndCheckExceptionsOperands& operands)
{
  fmt::println(stream,
               "InterpretAndCheckExceptions<write_pc={:5}>(current_pc=0x{:08x}, inst=0x{:08x}, "
               "downcount={})",
               write_pc, operands.current_pc, operands.inst.hex, operands.downcount);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::HLEFunction(std::ostream& stream, const HLEFunctionOperands& operands)
{
  const auto& [system, current_pc, hook_index] = operands;
  fmt::println(stream, "HLEFunction(current_pc=0x{:08x}, hook_index={}) [\"{}\"]", current_pc,
               hook_index, HLE::GetHookNameByIndex(hook_index));
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::WriteBrokenBlockNPC(std::ostream& stream,
                                             const WriteBrokenBlockNPCOperands& operands)
{
  const auto& [current_pc] = operands;
  fmt::println(stream, "WriteBrokenBlockNPC(current_pc=0x{:08x})", current_pc);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::CheckFPU(std::ostream& stream, const CheckHaltOperands& operands)
{
  const auto& [power_pc, current_pc, downcount] = operands;
  fmt::println(stream, "CheckFPU(current_pc=0x{:08x}, downcount={})", current_pc, downcount);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::CheckBreakpoint(std::ostream& stream, const CheckHaltOperands& operands)
{
  const auto& [power_pc, current_pc, downcount] = operands;
  fmt::println(stream, "CheckBreakpoint(current_pc=0x{:08x}, downcount={})", current_pc, downcount);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::CheckIdle(std::ostream& stream, const CheckIdleOperands& operands)
{
  const auto& [core_timing, idle_pc] = operands;
  fmt::println(stream, "CheckIdle(idle_pc=0x{:08x})", idle_pc);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::FastForwardCtrIdle(std::ostream& stream,
                                            const CheckCtrIdleOperands& operands)
{
  const auto& [core_timing, idle_pc, fallthrough_pc] = operands;
  fmt::println(stream, "FastForwardCtrIdle(idle_pc=0x{:08x}, fallthrough_pc=0x{:08x})", idle_pc,
               fallthrough_pc);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::IRBlockAnchor(std::ostream& stream, const IRBlockAnchorOperands& operands)
{
  const std::vector<IRInst>& ir = *operands.ir;
  fmt::println(stream, "IRBlockAnchor(ir_inst_count={})", ir.size());
  return sizeof(AnyCallback) + sizeof(operands);
}

static std::once_flag s_ir_sorted_lookup_flag;

std::size_t CachedInterpreterIR::Disassemble(const JitBlock& block, std::ostream& stream)
{
  using LookupKV = std::pair<AnyCallback, AnyDisassemble>;

  // clang-format off
#define LOOKUP_KV(...) {AnyCallbackCast(__VA_ARGS__), AnyDisassembleCast(__VA_ARGS__)}
  // clang-format on

  // Function addresses aren't known at compile-time, so this array is sorted at run-time.
  static auto sorted_lookup = std::to_array<LookupKV>({
      LOOKUP_KV(CachedInterpreterEmitter::PoisonCallback),
      LOOKUP_KV(CachedInterpreterIR::IRBlockAnchor),
      LOOKUP_KV(CachedInterpreterIR::StartProfiledBlock),
      LOOKUP_KV(CachedInterpreterIR::EndBlock<false>),
      LOOKUP_KV(CachedInterpreterIR::EndBlock<true>),
      LOOKUP_KV(CachedInterpreterIR::Interpret<false>),
      LOOKUP_KV(CachedInterpreterIR::Interpret<true>),
      LOOKUP_KV(CachedInterpreterIR::InterpretAndCheckExceptions<false>),
      LOOKUP_KV(CachedInterpreterIR::InterpretAndCheckExceptions<true>),
      LOOKUP_KV(CachedInterpreterIR::HLEFunction),
      LOOKUP_KV(CachedInterpreterIR::WriteBrokenBlockNPC),
      LOOKUP_KV(CachedInterpreterIR::CheckFPU),
      LOOKUP_KV(CachedInterpreterIR::CheckBreakpoint),
      LOOKUP_KV(CachedInterpreterIR::CheckIdle),
      LOOKUP_KV(CachedInterpreterIR::FastForwardCtrIdle),
  });

#undef LOOKUP_KV

  std::call_once(s_ir_sorted_lookup_flag, [] {
    const auto end = std::ranges::sort(sorted_lookup, {}, &LookupKV::first);
    ASSERT_MSG(DYNA_REC, std::ranges::adjacent_find(sorted_lookup, {}, &LookupKV::first) == end,
               "Sorted lookup should not contain duplicate keys.");
  });

  std::size_t instruction_count = 0;
  for (const u8* normal_entry = block.normalEntry; normal_entry != block.near_end;
       ++instruction_count)
  {
    const auto callback = *reinterpret_cast<const AnyCallback*>(normal_entry);
    const auto kv = std::ranges::lower_bound(sorted_lookup, callback, {}, &LookupKV::first);
    if (kv != sorted_lookup.end() && kv->first == callback)
    {
      normal_entry += kv->second(stream, normal_entry + sizeof(AnyCallback));
      continue;
    }
    stream << "UNKNOWN OR ILLEGAL CALLBACK\n";
    break;
  }
  return instruction_count;
}
