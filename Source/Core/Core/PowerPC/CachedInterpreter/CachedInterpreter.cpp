// Copyright 2014 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Core/PowerPC/CachedInterpreter/CachedInterpreter.h"

#include <span>
#include <sstream>
#include <utility>

#include <fmt/format.h>
#include <fmt/ostream.h>

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
#include "Core/PowerPC/Jit64Common/Jit64Constants.h"
#include "Core/PowerPC/PPCAnalyst.h"
#include "Core/PowerPC/PowerPC.h"
#include "Core/System.h"
#include "Core/HW/Memmap.h"

#ifdef __aarch64__
#include <arm_neon.h>
#include "Common/Intrinsics.h"
#endif

// ARM64-specific optimizations for iOS
#ifdef __aarch64__
namespace ARM64Optimizations
{
/// ARM64-optimized instruction execution with reduced overhead
static inline bool FastPathExecute(PowerPC::PowerPCState& ppc_state, UGeckoInstruction inst, u32 pc)
{
  const u32 op = inst.OPCD;

  // Fast path for most common instructions (addi, lwz, stw, add, etc.)
  switch (op)
  {
    case 14: // addi - Add Immediate (very common)
    {
      if (inst.RA == 0)
        ppc_state.gpr[inst.RD] = inst.SIMM_16;
      else
        ppc_state.gpr[inst.RD] = ppc_state.gpr[inst.RA] + inst.SIMM_16;
      return true;
    }

    case 15: // addis - Add Immediate Shifted (common)
    {
      if (inst.RA == 0)
        ppc_state.gpr[inst.RD] = inst.SIMM_16 << 16;
      else
        ppc_state.gpr[inst.RD] = ppc_state.gpr[inst.RA] + (inst.SIMM_16 << 16);
      return true;
    }

    case 32: // lwz - Load Word Zero (very common)
    {
      // Fall back to normal interpreter path for memory access
      return false;
    }

    case 36: // stw - Store Word (very common)
    {
      // Fall back to normal interpreter path for memory access
      return false;
    }

    case 31: // Extended opcodes
    {
      switch (inst.SUBOP10)
      {
        case 266: // add
        {
          ppc_state.gpr[inst.RD] = ppc_state.gpr[inst.RA] + ppc_state.gpr[inst.RB];
          return true;
        }
        case 40: // subf
        {
          ppc_state.gpr[inst.RD] = ppc_state.gpr[inst.RB] - ppc_state.gpr[inst.RA];
          return true;
        }
        case 316: // xor
        {
          ppc_state.gpr[inst.RD] = ppc_state.gpr[inst.RA] ^ ppc_state.gpr[inst.RB];
          return true;
        }
        case 444: // or
        {
          ppc_state.gpr[inst.RD] = ppc_state.gpr[inst.RA] | ppc_state.gpr[inst.RB];
          return true;
        }
        case 28: // and
        {
          ppc_state.gpr[inst.RD] = ppc_state.gpr[inst.RA] & ppc_state.gpr[inst.RB];
          return true;
        }
      }
      return false;
    }

    case 16: // bc - Branch Conditional (common in loops)
    {
      // Simple branch condition check - avoid complex condition logic for common cases
      const u32 ctr_ok = (inst.BO & 4) != 0 || (--ppc_state.spr[SPR_CTR] != 0) == ((inst.BO & 2) != 0);
      const u32 cond_ok = (inst.BO & 16) != 0 || ((ppc_state.cr.fields[inst.BI >> 2] >> (3 - (inst.BI & 3))) & 1) == ((inst.BO & 8) != 0);

      if (ctr_ok && cond_ok)
      {
        if (inst.LK)
          ppc_state.spr[SPR_LR] = pc + 4;
        ppc_state.npc = inst.AA ? inst.BD << 2 : pc + (inst.BD << 2);
      }
      return true;
    }
  }

  return false; // No fast path, use normal interpreter
}

/// ARM64 NEON optimized paired single operations
static inline void FastPairedSingleMath(PowerPC::PowerPCState& ppc_state, UGeckoInstruction inst)
{
  // Use NEON for paired single operations when possible
  const u32 fa = inst.FA;
  const u32 fb = inst.FB;
  const u32 fd = inst.FD;

  // Load paired singles into NEON registers
  float32x2_t va = vld1_f32(reinterpret_cast<const float*>(&ppc_state.ps[fa]));
  float32x2_t vb = vld1_f32(reinterpret_cast<const float*>(&ppc_state.ps[fb]));
  float32x2_t result;

  switch (inst.SUBOP5)
  {
    case 21: // ps_add
      result = vadd_f32(va, vb);
      break;
    case 20: // ps_sub
      result = vsub_f32(va, vb);
      break;
    case 25: // ps_mul
      result = vmul_f32(va, vb);
      break;
    default:
      return; // Not optimized, fall back
  }

  // Store result back
  vst1_f32(reinterpret_cast<float*>(&ppc_state.ps[fd]), result);
}

/// ARM64 optimized memory block operations
static inline void FastMemoryCopy(void* dst, const void* src, size_t size)
{
  // Use ARM64 optimized memory copy for large blocks
  if (size >= 64 && ((uintptr_t)dst & 15) == 0 && ((uintptr_t)src & 15) == 0)
  {
    // 128-bit aligned copy using NEON
    const uint8x16_t* src_vec = reinterpret_cast<const uint8x16_t*>(src);
    uint8x16_t* dst_vec = reinterpret_cast<uint8x16_t*>(dst);
    size_t vec_count = size / 16;

    for (size_t i = 0; i < vec_count; ++i)
    {
      vst1q_u8(reinterpret_cast<uint8_t*>(&dst_vec[i]), vld1q_u8(reinterpret_cast<const uint8_t*>(&src_vec[i])));
    }

    // Handle remaining bytes
    size_t remaining = size & 15;
    if (remaining > 0)
    {
      std::memcpy(reinterpret_cast<uint8_t*>(dst) + (vec_count * 16),
                  reinterpret_cast<const uint8_t*>(src) + (vec_count * 16),
                  remaining);
    }
  }
  else
  {
    std::memcpy(dst, src, size);
  }
}

} // namespace ARM64Optimizations
#endif

CachedInterpreter::CachedInterpreter(Core::System& system) : JitBase(system), m_block_cache(*this)
{
}

CachedInterpreter::~CachedInterpreter() = default;

void CachedInterpreter::Init()
{
  RefreshConfig();

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

#ifdef __aarch64__
  // ARM64 fast path: try to execute common instruction sequences with reduced overhead
  u32 fast_instructions = 0;
  const u32 max_fast_instructions = 16; // Limit to prevent infinite loops
#endif

  while (true)
  {
    const auto callback = *reinterpret_cast<const AnyCallback*>(normal_entry);

#ifdef __aarch64__
        // ARM64 optimization: check if this is a simple interpret callback that we can optimize
    if (fast_instructions < max_fast_instructions &&
        (callback == AnyCallbackCast(Interpret<true>) || callback == AnyCallbackCast(Interpret<false>)))
    {
      const auto* operands = reinterpret_cast<const InterpretOperands*>(normal_entry + sizeof(callback));

            // Try ARM64 paired single fast path first (most common in GameCube/Wii games)
      if (operands->inst.OPCD == 4) // PowerPC paired single opcode
      {
        // Use ARM64 paired single optimizations if available
        extern bool ARM64PairedSingleOpt_TryFastPath(PowerPC::PowerPCState& ppc_state, UGeckoInstruction inst);
        if (ARM64PairedSingleOpt_TryFastPath(ppc_state, operands->inst))
        {
          // Update PC for instruction that writes PC
          if (callback == AnyCallbackCast(Interpret<true>))
          {
            ppc_state.pc = operands->current_pc;
            ppc_state.npc = operands->current_pc + 4;
          }

          normal_entry += sizeof(callback) + sizeof(InterpretOperands);
          fast_instructions++;
          continue;
        }
      }

      // Try general ARM64 fast path execution
      if (ARM64Optimizations::FastPathExecute(ppc_state, operands->inst, operands->current_pc))
      {
        // Fast path succeeded - update PC and continue
        if (callback == AnyCallbackCast(Interpret<true>))
        {
          ppc_state.pc = operands->current_pc;
          ppc_state.npc = operands->current_pc + 4;
        }

        normal_entry += sizeof(callback) + sizeof(InterpretOperands);
        fast_instructions++;
        continue;
      }
    }
    fast_instructions = 0; // Reset counter if we can't fast path
#endif

    if (const auto distance = callback(ppc_state, normal_entry + sizeof(callback)))
      normal_entry += distance;
    else
      break;
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
        const InterpretOperands operands = {interpreter, Interpreter::GetInterpreterOp(op.inst),
                                            js.compilerPC, op.inst};
        Write(op.canEndBlock ? CallbackCast(Interpret<true>) : CallbackCast(Interpret<false>),
              operands);
      }

      if (op.branchIsIdleLoop)
        Write(CheckIdle, {m_system.GetCoreTiming(), js.blockStart});
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
