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

// iCube: skip the per-block PowerPC performance-monitor (PMC) update on the CIR hot path.
// Most titles never configure the PMC (MMCRn SELECT = 0 -> the update is pure overhead), so
// skipping it saves ~4% on CPU-bound games. Default OFF (PMC emulated for correctness); the
// MAIN_CIR_SKIP_PERF_MONITOR setting opts in. Read once in Init (cheap per-block bool check).
static bool s_skip_perf_monitor = false;

// iCube: when true, the emission site routes whitelisted hot integer-ALU ops to a specialized,
// directly-dispatched callback (see InterpretSpecialized) instead of the generic Interpret
// trampoline. Read once in Init (cheap per-op bool check at compile time). Default OFF.
static bool s_specialized_ops = false;
// iCube: when true, each specialized callback re-derives and asserts the dispatch bookkeeping
// against the generic Interpret<write_pc> contract before committing the real handler.
static bool s_specialized_ops_validate = false;

// iCube: whitelist of hot integer-ALU ops eligible for specialized dispatch. Defined once as an
// X-macro so the emission site, the ExecuteOneBlock dispatch compare-chain, and the eligibility
// check all stay in lockstep — adding an op is a single line here.
//
// Membership criteria (ALL must hold; verified against the 2509 Interpreter_Integer.cpp bodies):
//   - NOT FL_LOADSTORE and NOT FL_USE_FPU  => emission site always routes via Interpret<write_pc>
//     (never InterpretAndCheckExceptions), and never via CheckFPU.
//   - Side effects confined to the register file (GPR/CR/XER); never raises an exception, never
//     touches the MMU, never sets m_end_block, never calls CheckExceptions.
// Each X(handler) expands for the caller's purpose. Keep this set SMALL: every entry adds two
// branches (write_pc false/true) to the hottest dispatch loop.
#define CIR_SPECIALIZED_OP_LIST(X)                                                                 \
  X(addi)    /* D-form: gpr[RD] = (RA?gpr[RA]:0) + SIMM_16; pure GPR write */                       \
  X(addis)   /* D-form: gpr[RD] = (RA?gpr[RA]:0) + (SIMM_16<<16); pure GPR write */                 \
  X(ori)     /* D-form: gpr[RA] = gpr[RS] | UIMM; pure GPR write */                                 \
  X(oris)    /* D-form: gpr[RA] = gpr[RS] | (UIMM<<16); pure GPR write */                           \
  X(orx)     /* X-form: gpr[RA] = gpr[RS] | gpr[RB]; +CR0 if Rc; no XER, no exceptions */           \
  X(rlwinmx) /* M-form: gpr[RA] = rotl(gpr[RS],SH) & mask; +CR0 if Rc; no XER, no exceptions */

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

void CachedInterpreter::Init()
{
  RefreshConfig();
  s_skip_perf_monitor = Config::Get(Config::MAIN_CIR_SKIP_PERF_MONITOR);
  s_specialized_ops = Config::Get(Config::MAIN_CIR_SPECIALIZED_OPS);
  s_specialized_ops_validate = Config::Get(Config::MAIN_CIR_SPECIALIZED_OPS_VALIDATE);

  AllocCodeSpace(CODE_SIZE);
  ResetFreeMemoryRanges();

  jo.enableBlocklink = false;

  m_block_cache.Init();

  code_block.m_stats = &js.st;
  code_block.m_gpa = &js.gpa;
  code_block.m_fpa = &js.fpa;
}

void CachedInterpreter::Shutdown()
{
  m_block_cache.Shutdown();
}

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
// iCube: direct dispatch for specialized hot ops (only emitted when MAIN_CIR_SPECIALIZED_OPS is on;
// when off these branches are never taken because no specialized callback is ever written). Each
// matched branch makes BOTH the dispatch AND the handler call direct (handler inlines under
// ThinLTO), collapsing the two indirect calls of the generic path. The payload layout is the same
// InterpretOperands, so advancement is identical to the generic Interpret branches above. Reaching
// here means the two (hotter) generic compares already failed, so these are only paid by ops that
// are themselves specialized or that fall through to the cold indirect tail below.
#define CIR_DISPATCH(name)                                                                         \
  else if (callback ==                                                                             \
           reinterpret_cast<AnyCallback>(CallbackCast(InterpretSpecialized<&Interpreter::name,     \
                                                                           false>)))               \
  {                                                                                                \
    InterpretSpecialized<&Interpreter::name, false>(                                               \
        ppc_state, *reinterpret_cast<const InterpretOperands*>(payload));                          \
    normal_entry = payload + sizeof(InterpretOperands);                                            \
  }                                                                                                \
  else if (callback ==                                                                             \
           reinterpret_cast<AnyCallback>(CallbackCast(InterpretSpecialized<&Interpreter::name,     \
                                                                           true>)))                \
  {                                                                                                \
    InterpretSpecialized<&Interpreter::name, true>(                                                \
        ppc_state, *reinterpret_cast<const InterpretOperands*>(payload));                          \
    normal_entry = payload + sizeof(InterpretOperands);                                            \
  }
    CIR_SPECIALIZED_OP_LIST(CIR_DISPATCH)
#undef CIR_DISPATCH
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
  if (!s_skip_perf_monitor)
    PowerPC::UpdatePerformanceMonitor(operands.downcount, operands.num_load_stores,
                                      operands.num_fp_inst, ppc_state);
  if constexpr (profiled)
    JitBlock::ProfileData::EndProfiling(operands.profile_data, operands.downcount);
  return 0;
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

// iCube: specialized counterpart to Interpret<write_pc>. See header for contract. The ONLY
// behavioral difference from Interpret<write_pc> is that the per-op handler is invoked by its
// compile-time-constant pointer Func (direct/inlinable) instead of operands.func (indirect).
// Everything else — the write_pc pc/npc writes and the return distance — is reproduced verbatim.
template <Interpreter::Instruction Func, bool write_pc>
s32 CachedInterpreter::InterpretSpecialized(PowerPC::PowerPCState& ppc_state,
                                            const InterpretOperands& operands)
{
  // The whitelist (see CIR_SPECIALIZED_OP_LIST) is integer-ALU only: pure register math, never
  // FL_LOADSTORE/FL_USE_FPU, so these never raise exceptions and never touch the MMU. That is why
  // this mirrors Interpret<write_pc> (the non-exception trampoline) and NOT
  // InterpretAndCheckExceptions: the emission site (DoJit) only routes such ops through Interpret.
  if (s_specialized_ops_validate) [[unlikely]]
  {
    // Strongest feasible self-check (see header / report): handler math is identical by
    // construction (Func == operands.func for whitelisted ops), so we validate the BOOKKEEPING and
    // dispatch integration that a specialized callback could get subtly wrong: the write_pc pc/npc
    // writes and the returned advance distance. We run the generic Interpret<write_pc> on a scratch
    // copy of the register state, then the specialized path on the real state, and assert the
    // resulting architectural state (GPR/CR/XER/PC/NPC) and return distance match. Safe to
    // double-run because whitelisted ops are side-effect-free outside the register file.
    // gpr/cr.fields are C arrays; snapshot via std::array copies so we can compare with ==.
    std::array<u32, 32> saved_gpr;
    std::array<u64, 8> saved_cr;
    std::copy(std::begin(ppc_state.gpr), std::end(ppc_state.gpr), saved_gpr.begin());
    std::copy(std::begin(ppc_state.cr.fields), std::end(ppc_state.cr.fields), saved_cr.begin());
    // XER lives in the split fields xer_ca / xer_so_ov, NOT spr[SPR_XER] (which is only
    // reconstructed on mfspr). Watch the live fields so this check is correct for future ops that
    // affect carry/overflow (addic/addx/subfic/...). The current 6-op whitelist never writes them.
    const u8 saved_xer_ca = ppc_state.xer_ca;
    const u8 saved_xer_so_ov = ppc_state.xer_so_ov;
    const u32 saved_pc = ppc_state.pc;
    const u32 saved_npc = ppc_state.npc;

    // Generic reference run on the live state (this is exactly what the unspecialized block would
    // have done, using the same operands.func the emission site captured).
    const s32 generic_distance = Interpret<write_pc>(ppc_state, operands);

    std::array<u32, 32> generic_gpr;
    std::array<u64, 8> generic_cr;
    std::copy(std::begin(ppc_state.gpr), std::end(ppc_state.gpr), generic_gpr.begin());
    std::copy(std::begin(ppc_state.cr.fields), std::end(ppc_state.cr.fields), generic_cr.begin());
    const u8 generic_xer_ca = ppc_state.xer_ca;
    const u8 generic_xer_so_ov = ppc_state.xer_so_ov;
    const u32 generic_pc = ppc_state.pc;
    const u32 generic_npc = ppc_state.npc;

    // Restore and run the specialized path.
    std::copy(saved_gpr.begin(), saved_gpr.end(), std::begin(ppc_state.gpr));
    std::copy(saved_cr.begin(), saved_cr.end(), std::begin(ppc_state.cr.fields));
    ppc_state.xer_ca = saved_xer_ca;
    ppc_state.xer_so_ov = saved_xer_so_ov;
    ppc_state.pc = saved_pc;
    ppc_state.npc = saved_npc;

    if constexpr (write_pc)
    {
      ppc_state.pc = operands.current_pc;
      ppc_state.npc = operands.current_pc + 4;
    }
    Func(operands.interpreter, operands.inst);
    const s32 specialized_distance = sizeof(AnyCallback) + sizeof(operands);

    std::array<u32, 32> spec_gpr;
    std::array<u64, 8> spec_cr;
    std::copy(std::begin(ppc_state.gpr), std::end(ppc_state.gpr), spec_gpr.begin());
    std::copy(std::begin(ppc_state.cr.fields), std::end(ppc_state.cr.fields), spec_cr.begin());

    ASSERT_MSG(DYNA_REC, specialized_distance == generic_distance,
               "CIR specialized op return distance mismatch: {} vs generic {}",
               specialized_distance, generic_distance);
    ASSERT_MSG(DYNA_REC, spec_gpr == generic_gpr, "CIR specialized op GPR mismatch at pc {:#x}",
               operands.current_pc);
    ASSERT_MSG(DYNA_REC, spec_cr == generic_cr, "CIR specialized op CR mismatch at pc {:#x}",
               operands.current_pc);
    ASSERT_MSG(DYNA_REC,
               ppc_state.xer_ca == generic_xer_ca && ppc_state.xer_so_ov == generic_xer_so_ov,
               "CIR specialized op XER mismatch at pc {:#x}", operands.current_pc);
    ASSERT_MSG(DYNA_REC, ppc_state.pc == generic_pc && ppc_state.npc == generic_npc,
               "CIR specialized op PC/NPC mismatch at pc {:#x}", operands.current_pc);
    return specialized_distance;
  }

  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  Func(operands.interpreter, operands.inst);
  return sizeof(AnyCallback) + sizeof(operands);
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

void CachedInterpreter::WriteEndBlock()
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
        // iCube: route whitelisted hot integer-ALU ops to the specialized, directly-dispatched
        // callback when MAIN_CIR_SPECIALIZED_OPS is on. The payload is the identical
        // InterpretOperands struct, so dispatch advancement is unchanged; only the emitted callback
        // pointer differs. write_pc == op.canEndBlock, matching the generic Interpret selection.
        // Cold/non-whitelisted ops fall through to the unchanged generic emission below.
        bool emitted = false;
        if (s_specialized_ops && IsSpecializedOp(func))
        {
#define CIR_EMIT(name)                                                                             \
  if (!emitted && func == &Interpreter::name)                                                      \
  {                                                                                                \
    Write(op.canEndBlock ? CallbackCast(InterpretSpecialized<&Interpreter::name, true>) :          \
                           CallbackCast(InterpretSpecialized<&Interpreter::name, false>),          \
          operands);                                                                               \
    emitted = true;                                                                                \
  }
          CIR_SPECIALIZED_OP_LIST(CIR_EMIT)
#undef CIR_EMIT
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
        WriteEndBlock();
    }
  }
  if (code_block.m_broken)
  {
    Write(WriteBrokenBlockNPC, {nextPC});
    WriteEndBlock();
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
