// Copyright 2014 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Core/PowerPC/CachedInterpreter/CachedInterpreter.h"

#include <span>
#include <sstream>
#include <utility>
#include <cstring>

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
#include "Common/Swap.h"

CachedInterpreter::CachedInterpreter(Core::System& system) : JitBase(system), m_block_cache(*this)
{
}

template <bool write_pc>
s32 CachedInterpreter::LoadStoreDFormPIC(PowerPC::PowerPCState& ppc_state,
                                         const LoadStoreDFormPICOperands& operands)
{
  const auto& [interpreter, func, current_pc, inst, power_pc, mem1_base, mem1_mask, exram_base,
               exram_mask] = operands;

  // Always set PC/NPC like other callbacks: write_pc variant is selected at emission time.
  // We mirror Interpret<write_pc> behavior by writing both; NPC will be updated by branch logic.
  if constexpr (write_pc)
  {
    ppc_state.pc = current_pc;
    ppc_state.npc = current_pc + 4;
  }

  // Decode effective address
  // - D-form: ea = (RA ? GPR[RA] : 0) + SIMM_16
  // - X-form: ea = (RA ? GPR[RA] : 0) + GPR[RB]
  const u32 ra = inst.RA;
  u32 ea;
  if (inst.OPCD == 31)
  {
    const u32 rb = inst.RB;
    ea = (ra ? ppc_state.gpr[ra] : 0) + ppc_state.gpr[rb];
  }
  else
  {
    ea = ra ? (ppc_state.gpr[ra] + static_cast<u32>(inst.SIMM_16))
            : static_cast<u32>(inst.SIMM_16);
  }

  // Compute direct pointer if EA lies in MEM1 or EXRAM logical regions
  u8* base_ptr = nullptr;
  u32 offset = 0;
  if (ea >= Memory::MEM1_BASE_ADDR && ea - Memory::MEM1_BASE_ADDR <= mem1_mask)
  {
    base_ptr = mem1_base;
    offset = (ea - Memory::MEM1_BASE_ADDR) & mem1_mask;
  }
  else if (ea >= Memory::MEM2_BASE_ADDR && ea - Memory::MEM2_BASE_ADDR <= exram_mask)
  {
    base_ptr = exram_base;
    offset = (ea - Memory::MEM2_BASE_ADDR) & exram_mask;
  }

  if (base_ptr)
  {
    // offset already computed as (ea - base) & mask above; do not recompute with (ea & mask)
    // which would be incorrect for EXRAM and MEM1 logical addresses.
    // Handle D-form by primary opcode, X-form by SUBOP10 under OPCD=31
    switch (inst.OPCD)
    {
    case 32: // lwz
    {
      if ((ea & 0b11) != 0)
        break; // misaligned -> fallback
      u32 raw;
      std::memcpy(&raw, base_ptr + offset, sizeof(raw));
      const u32 val = Common::FromBigEndian(raw);
      ppc_state.gpr[inst.RD] = val;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 33: // lwzu (update)
    {
      if (ra == 0 || (ea & 0b11) != 0)
        break; // illegal or misaligned -> fallback
      u32 raw;
      std::memcpy(&raw, base_ptr + offset, sizeof(raw));
      const u32 val = Common::FromBigEndian(raw);
      ppc_state.gpr[inst.RD] = val;
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 34: // lbz
    {
      const u8 val = *(base_ptr + offset);
      ppc_state.gpr[inst.RD] = static_cast<u32>(val);
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 35: // lbzu (update)
    {
      if (ra == 0)
        break; // illegal -> fallback
      const u8 val = *(base_ptr + offset);
      ppc_state.gpr[inst.RD] = static_cast<u32>(val);
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 40: // lhz
    {
      if ((ea & 0b1) != 0)
        break; // misaligned -> fallback
      u16 raw;
      std::memcpy(&raw, base_ptr + offset, sizeof(raw));
      const u16 val = Common::FromBigEndian(raw);
      ppc_state.gpr[inst.RD] = static_cast<u32>(val);
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 41: // lhzu (update)
    {
      if (ra == 0 || (ea & 0b1) != 0)
        break; // illegal or misaligned -> fallback
      u16 raw;
      std::memcpy(&raw, base_ptr + offset, sizeof(raw));
      const u16 val = Common::FromBigEndian(raw);
      ppc_state.gpr[inst.RD] = static_cast<u32>(val);
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 42: // lha
    {
      if ((ea & 0b1) != 0)
        break; // misaligned -> fallback
      u16 raw;
      std::memcpy(&raw, base_ptr + offset, sizeof(raw));
      const u16 be = Common::FromBigEndian(raw);
      ppc_state.gpr[inst.RD] = static_cast<u32>(static_cast<s16>(be));
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 43: // lhau (update)
    {
      if (ra == 0 || (ea & 0b1) != 0)
        break; // illegal or misaligned -> fallback
      u16 raw;
      std::memcpy(&raw, base_ptr + offset, sizeof(raw));
      const u16 be = Common::FromBigEndian(raw);
      ppc_state.gpr[inst.RD] = static_cast<u32>(static_cast<s16>(be));
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 36: // stw
    {
      if ((ea & 0b11) != 0)
        break; // misaligned -> fallback
      const u32 val = ppc_state.gpr[inst.RS];
      const u32 raw = Common::swap32(val);
      std::memcpy(base_ptr + offset, &raw, sizeof(raw));
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 37: // stwu (update)
    {
      if (ra == 0 || (ea & 0b11) != 0)
        break; // illegal or misaligned -> fallback
      const u32 val = ppc_state.gpr[inst.RS];
      const u32 raw = Common::swap32(val);
      std::memcpy(base_ptr + offset, &raw, sizeof(raw));
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 38: // stb
    {
      const u8 val = static_cast<u8>(ppc_state.gpr[inst.RS]);
      *(base_ptr + offset) = val;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 39: // stbu (update)
    {
      if (ra == 0)
        break; // illegal -> fallback
      const u8 val = static_cast<u8>(ppc_state.gpr[inst.RS]);
      *(base_ptr + offset) = val;
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 44: // sth
    {
      if ((ea & 0b1) != 0)
        break; // misaligned -> fallback
      const u16 val = static_cast<u16>(ppc_state.gpr[inst.RS]);
      const u16 raw = Common::swap16(val);
      std::memcpy(base_ptr + offset, &raw, sizeof(raw));
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 45: // sthu (update)
    {
      if (ra == 0 || (ea & 0b1) != 0)
        break; // illegal or misaligned -> fallback
      const u16 val = static_cast<u16>(ppc_state.gpr[inst.RS]);
      const u16 raw = Common::swap16(val);
      std::memcpy(base_ptr + offset, &raw, sizeof(raw));
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 31: // X-form indexed load/store
    {
      switch (inst.SUBOP10)
      {
      // Loads (indexed)
      case 23: // lwzx
      case 55: // lwzux (update)
      {
        const bool update = (inst.SUBOP10 == 55);
        if ((ea & 0b11) != 0 || (update && ra == 0))
          break; // misaligned or illegal
        u32 raw;
        std::memcpy(&raw, base_ptr + offset, sizeof(raw));
        const u32 val = Common::FromBigEndian(raw);
        ppc_state.gpr[inst.RD] = val;
        if (update)
          ppc_state.gpr[ra] = ea;
        return sizeof(AnyCallback) + sizeof(operands);
      }
      case 87:  // lbzx
      case 119: // lbzux (update)
      {
        const bool update = (inst.SUBOP10 == 119);
        if (update && ra == 0)
          break; // illegal
        const u8 val = *(base_ptr + offset);
        ppc_state.gpr[inst.RD] = static_cast<u32>(val);
        if (update)
          ppc_state.gpr[ra] = ea;
        return sizeof(AnyCallback) + sizeof(operands);
      }
      case 279: // lhzx
      case 311: // lhzux (update)
      {
        const bool update = (inst.SUBOP10 == 311);
        if ((ea & 0b1) != 0 || (update && ra == 0))
          break; // misaligned or illegal
        u16 raw;
        std::memcpy(&raw, base_ptr + offset, sizeof(raw));
        const u16 val = Common::FromBigEndian(raw);
        ppc_state.gpr[inst.RD] = static_cast<u32>(val);
        if (update)
          ppc_state.gpr[ra] = ea;
        return sizeof(AnyCallback) + sizeof(operands);
      }
      case 343: // lhax
      case 375: // lhaux (update)
      {
        const bool update = (inst.SUBOP10 == 375);
        if ((ea & 0b1) != 0 || (update && ra == 0))
          break; // misaligned or illegal
        u16 raw;
        std::memcpy(&raw, base_ptr + offset, sizeof(raw));
        const u16 be = Common::FromBigEndian(raw);
        ppc_state.gpr[inst.RD] = static_cast<u32>(static_cast<s16>(be));
        if (update)
          ppc_state.gpr[ra] = ea;
        return sizeof(AnyCallback) + sizeof(operands);
      }

      // Stores (indexed)
      case 151: // stwx
      case 183: // stwux (update)
      {
        const bool update = (inst.SUBOP10 == 183);
        if ((ea & 0b11) != 0 || (update && ra == 0))
          break; // misaligned or illegal
        const u32 val = ppc_state.gpr[inst.RS];
        const u32 raw = Common::swap32(val);
        std::memcpy(base_ptr + offset, &raw, sizeof(raw));
        if (update)
          ppc_state.gpr[ra] = ea;
        return sizeof(AnyCallback) + sizeof(operands);
      }
      case 215: // stbx
      case 247: // stbux (update)
      {
        const bool update = (inst.SUBOP10 == 247);
        if (update && ra == 0)
          break; // illegal
        const u8 val = static_cast<u8>(ppc_state.gpr[inst.RS]);
        *(base_ptr + offset) = val;
        if (update)
          ppc_state.gpr[ra] = ea;
        return sizeof(AnyCallback) + sizeof(operands);
      }
      case 407: // sthx
      case 439: // sthux (update)
      {
        const bool update = (inst.SUBOP10 == 439);
        if ((ea & 0b1) != 0 || (update && ra == 0))
          break; // misaligned or illegal
        const u16 val = static_cast<u16>(ppc_state.gpr[inst.RS]);
        const u16 raw = Common::swap16(val);
        std::memcpy(base_ptr + offset, &raw, sizeof(raw));
        if (update)
          ppc_state.gpr[ra] = ea;
        return sizeof(AnyCallback) + sizeof(operands);
      }

      // Byte-reverse indexed variants
      case 534: // lwbrx
      {
        if ((ea & 0b11) != 0)
          break; // misaligned
        u32 raw;
        std::memcpy(&raw, base_ptr + offset, sizeof(raw));
        const u32 val = Common::swap32(Common::FromBigEndian(raw));
        ppc_state.gpr[inst.RD] = val;
        return sizeof(AnyCallback) + sizeof(operands);
      }
      case 790: // lhbrx
      {
        if ((ea & 0b1) != 0)
          break; // misaligned
        u16 raw;
        std::memcpy(&raw, base_ptr + offset, sizeof(raw));
        const u16 val = Common::swap16(Common::FromBigEndian(raw));
        ppc_state.gpr[inst.RD] = static_cast<u32>(val);
        return sizeof(AnyCallback) + sizeof(operands);
      }
      case 662: // stwbrx
      {
        if ((ea & 0b11) != 0)
          break; // misaligned
        // Write bytes in reverse order relative to normal big-endian store.
        const u32 raw = ppc_state.gpr[inst.RS];
        std::memcpy(base_ptr + offset, &raw, sizeof(raw));
        return sizeof(AnyCallback) + sizeof(operands);
      }
      case 918: // sthbrx
      {
        if ((ea & 0b1) != 0)
          break; // misaligned
        const u16 raw = static_cast<u16>(ppc_state.gpr[inst.RS]);
        std::memcpy(base_ptr + offset, &raw, sizeof(raw));
        return sizeof(AnyCallback) + sizeof(operands);
      }

      default:
        break; // unsupported X-form in PIC
      }
      break; // end case 31
    }
    default:
      break; // Unsupported D-form opcode in fast path; fall back below.
    }
  }

  // Slow path or unsupported opcodes: delegate to interpreter implementation.
  func(interpreter, inst);
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
s32 CachedInterpreter::LoadStoreDFormPIC(std::ostream& stream,
                                         const LoadStoreDFormPICOperands& operands)
{
  fmt::print(stream, "PIC D-Form LS at PC={:#010x}, OPCD={}\n", operands.current_pc,
             operands.inst.OPCD);
  return sizeof(AnyCallback) + sizeof(operands);
}

CachedInterpreter::~CachedInterpreter() = default;

void CachedInterpreter::Init()
{
  RefreshConfig();

  AllocCodeSpace(CODE_SIZE);
  ResetFreeMemoryRanges();

  // Enable block linking on ARM64 to reduce dispatch overhead.
  // Safe on iOS/tvOS and provides measurable speedups.
  #if defined(__aarch64__)
  jo.enableBlocklink = true;
  #else
  jo.enableBlocklink = false;
  #endif

  m_block_cache.Init();

  code_block.m_stats = &js.st;
  code_block.m_gpa = &js.gpa;
  code_block.m_fpa = &js.fpa;
}

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

  for (u32 i = 0; i < count; ++i)
  {
    const MicroOp& m = ops[i];
    switch (m.op)
    {
    case MicroOpCode::ADDI:
    {
      const u32 ra_val = (m.ra == 0) ? 0u : ppc_state.gpr[m.ra];
      // imm treated as signed 16 per ADDI semantics
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
      // For ORI, rd holds the destination (RA field in instruction), ra holds RS (source)
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 ui = m.imm & 0xFFFFu;
      ppc_state.gpr[m.rd] = rs_val | ui;
      break;
    }
    case MicroOpCode::NOP:
    default:
      break;
    }
  }

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

void CachedInterpreter::Shutdown()
{
  m_block_cache.Shutdown();
}

#if defined(__GNUC__) || defined(__clang__)
__attribute__((hot))
#endif
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
    if (const auto distance = callback(ppc_state, normal_entry + sizeof(callback))) [[likely]]
      normal_entry += distance;
    else
      break;
  }
}

#if defined(__GNUC__) || defined(__clang__)
__attribute__((hot))
#endif
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
  if (PowerPC::PerformanceMonitorActive(ppc_state))
  {
    PowerPC::UpdatePerformanceMonitor(operands.downcount, operands.num_load_stores,
                                      operands.num_fp_inst, ppc_state);
  }
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
        // Try to pack a small run of simple immediate ALU ops into micro-ops
        auto is_simple_imm = [](const UGeckoInstruction& ins) -> bool {
          switch (ins.OPCD)
          {
          case 14: // addi
          case 15: // addis
          case 24: // ori
            return true;
          default:
            return false;
          }
        };

        bool used_micro_ops = false;
        if (is_simple_imm(op.inst))
        {
          ExecuteMicroOpsOperands mop{};
          mop.count = 0;
          mop.current_pc = js.compilerPC;

          // Pack up to kMaxOps or until encountering a non-simple op
          for (u32 j = i; j < code_block.m_num_instructions && mop.count < ExecuteMicroOpsOperands::kMaxOps; ++j)
          {
            PPCAnalyst::CodeOp& next = m_code_buffer[j];
            if (next.skip || (next.opinfo->flags & (FL_LOADSTORE | FL_USE_FPU)) != 0 ||
                !is_simple_imm(next.inst))
            {
              break;
            }

            MicroOp& mu = mop.ops[mop.count++];
            switch (next.inst.OPCD)
            {
            case 14: // addi
              mu.op = MicroOpCode::ADDI;
              mu.rd = next.inst.RD; // RT
              mu.ra = next.inst.RA; // RA (0 allowed)
              mu.imm = static_cast<u32>(next.inst.SIMM_16);
              break;
            case 15: // addis
              mu.op = MicroOpCode::ADDIS;
              mu.rd = next.inst.RD;
              mu.ra = next.inst.RA;
              mu.imm = static_cast<u32>(next.inst.SIMM_16);
              break;
            case 24: // ori
              mu.op = MicroOpCode::ORI;
              mu.rd = next.inst.RA; // destination is RA
              mu.ra = next.inst.RS; // source is RS
              mu.imm = static_cast<u32>(next.inst.UIMM);
              break;
            default:
              // Should not reach
              mop.count--;
              j = code_block.m_num_instructions; // force stop
              break;
            }

            // Advance i when packing
            if (j != i)
              js.downcountAmount += next.opinfo->num_cycles;

            // Stop packing if this instruction ends the block
            if (next.canEndBlock)
            {
              // Emit what we have and ensure end block is handled after the loop
              i = j; // The for-loop will ++i; we want to stop at j
              break;
            }

            // Prepare to consume this op; the outer loop will ++i
            i = j;
          }

          if (mop.count > 0)
          {
            used_micro_ops = true;
            Write(op.canEndBlock ? CallbackCast(ExecuteMicroOps<true>) :
                                   CallbackCast(ExecuteMicroOps<false>),
                  mop);
          }
        }

        if (!used_micro_ops)
        {
          // Use PIC fast path for load/store instructions when possible
          if ((op.opinfo->flags & FL_LOADSTORE) != 0)
          {
            auto& mm = m_system.GetMemory();
            const LoadStoreDFormPICOperands operands = {interpreter,
                                                        Interpreter::GetInterpreterOp(op.inst),
                                                        js.compilerPC,
                                                        op.inst,
                                                        power_pc,
                                                        mm.GetRAM(),
                                                        mm.GetRamMask(),
                                                        mm.GetEXRAM(),
                                                        mm.GetExRamMask()};
            Write(op.canEndBlock ? CallbackCast(LoadStoreDFormPIC<true>) :
                                   CallbackCast(LoadStoreDFormPIC<false>),
                  operands);
          }
          else
          {
            const InterpretOperands operands = {interpreter, Interpreter::GetInterpreterOp(op.inst),
                                                js.compilerPC, op.inst};
            Write(op.canEndBlock ? CallbackCast(Interpret<true>) : CallbackCast(Interpret<false>),
                  operands);
          }
        }
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
