// Copyright 2008 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Core/PowerPC/Interpreter/Interpreter.h"

#include <algorithm>
#include <array>
#include <mutex>
#include <string>

#include <fmt/format.h>

#include "Common/Assert.h"
#include "Common/CommonTypes.h"
#include "Common/GekkoDisassembler.h"
#include "Common/Logging/Log.h"
#include "Common/MsgHandler.h"
#include "Core/Config/MainSettings.h"
#include "Core/ConfigManager.h"
#include "Core/Core.h"
#include "Core/CoreTiming.h"
#include "Core/Debugger/Debugger_SymbolMap.h"
#include "Core/HLE/HLE.h"
#include "Core/HW/CPU.h"
#include "Core/PowerPC/Interpreter/ExceptionUtils.h"
#include "Core/PowerPC/MMU.h"
#include "Core/PowerPC/PPCTables.h"
#include "Core/PowerPC/PowerPC.h"
#include "Core/System.h"

namespace
{
// Determines whether or not the given instruction is one where its execution
// validity is determined by whether or not HID2's LSQE bit is set.
// In other words, if the instruction is psq_l, psq_lu, psq_st, or psq_stu
bool IsPairedSingleQuantizedNonIndexedInstruction(UGeckoInstruction inst)
{
  const u32 opcode = inst.OPCD;
  return opcode == 0x38 || opcode == 0x39 || opcode == 0x3C || opcode == 0x3D;
}

bool IsPairedSingleInstruction(UGeckoInstruction inst)
{
  return inst.OPCD == 4 || IsPairedSingleQuantizedNonIndexedInstruction(inst);
}
}  // namespace

// Checks if a given instruction would be illegal to execute if it's a paired single instruction.
//
// Paired single instructions are illegal to execute if HID2.PSE is not set.
// It's also illegal to execute psq_l, psq_lu, psq_st, and psq_stu if HID2.PSE is enabled,
// but HID2.LSQE is not set.
bool Interpreter::IsInvalidPairedSingleExecution(UGeckoInstruction inst)
{
  if (!HID2(m_ppc_state).PSE && IsPairedSingleInstruction(inst))
    return true;

  return HID2(m_ppc_state).PSE && !HID2(m_ppc_state).LSQE &&
         IsPairedSingleQuantizedNonIndexedInstruction(inst);
}

void Interpreter::UpdatePC()
{
  m_last_pc = m_ppc_state.pc;
  m_ppc_state.pc = m_ppc_state.npc;
}

Interpreter::Interpreter(Core::System& system, PowerPC::PowerPCState& ppc_state, PowerPC::MMU& mmu,
                         Core::BranchWatch& branch_watch, PPCSymbolDB& ppc_symbol_db)
    : m_system(system), m_ppc_state(ppc_state), m_mmu(mmu), m_branch_watch(branch_watch),
      m_ppc_symbol_db(ppc_symbol_db)
{
}

Interpreter::~Interpreter() = default;

void Interpreter::Init()
{
  m_end_block = false;
  // iCube: refresh the NEON paired-single fast-path flags per game-boot for the plain interpreter too
  // (the CIR / IR engines do the same in their own Init()).
  RefreshNeonPairedConfig();
}

void Interpreter::Shutdown()
{
}

void Interpreter::Trace(const UGeckoInstruction& inst)
{
  std::string regs;
  for (size_t i = 0; i < std::size(m_ppc_state.gpr); i++)
  {
    regs += fmt::format("r{:02d}: {:08x} ", i, m_ppc_state.gpr[i]);
  }

  std::string fregs;
  for (size_t i = 0; i < std::size(m_ppc_state.ps); i++)
  {
    const auto& ps = m_ppc_state.ps[i];
    fregs += fmt::format("f{:02d}: {:08x} {:08x} ", i, ps.PS0AsU64(), ps.PS1AsU64());
  }

  const std::string ppc_inst = Common::GekkoDisassembler::Disassemble(inst.hex, m_ppc_state.pc);
  DEBUG_LOG_FMT(POWERPC,
                "INTER PC: {:08x} SRR0: {:08x} SRR1: {:08x} CRval: {:016x} "
                "FPSCR: {:08x} MSR: {:08x} LR: {:08x} {} {:08x} {}",
                m_ppc_state.pc, SRR0(m_ppc_state), SRR1(m_ppc_state), m_ppc_state.cr.fields[0],
                m_ppc_state.fpscr.Hex, m_ppc_state.msr.Hex, m_ppc_state.spr[SPR_LR], regs, inst.hex,
                ppc_inst);
}

bool Interpreter::HandleFunctionHooking(u32 address)
{
  const auto result =
      HLE::TryReplaceFunction(m_ppc_symbol_db, address, PowerPC::CoreMode::Interpreter);
  if (!result)
    return false;

  HLEFunction(*this, result.hook_index);

  return result.type != HLE::HookType::Start;
}

int Interpreter::SingleStepInner()
{
  if (HandleFunctionHooking(m_ppc_state.pc))
  {
    UpdatePC();
    // TODO: Does it make sense to use m_prev_inst here?
    // It seems like we should use the num_cycles for the instruction at PC instead
    // (m_prev_inst has not yet been updated)
    return PPCTables::GetOpInfo(m_prev_inst, m_ppc_state.pc)->num_cycles;
  }

  m_ppc_state.npc = m_ppc_state.pc + sizeof(UGeckoInstruction);
  m_prev_inst.hex = m_mmu.Read_Opcode(m_ppc_state.pc);

  const GekkoOPInfo* opinfo = PPCTables::GetOpInfo(m_prev_inst, m_ppc_state.pc);

  // Uncomment to trace the interpreter
  // if ((m_ppc_state.pc & 0x00FFFFFF) >= 0x000AB54C &&
  //     (m_ppc_state.pc & 0x00FFFFFF) <= 0x000AB624)
  // {
  //   m_start_trace = true;
  // }
  // else
  // {
  //   m_start_trace = false;
  // }

  if (m_start_trace)
  {
    Trace(m_prev_inst);
  }

  if (m_prev_inst.hex != 0)
  {
    if (IsInvalidPairedSingleExecution(m_prev_inst))
    {
      GenerateProgramException(m_ppc_state, ProgramExceptionCause::IllegalInstruction);
      CheckExceptions();
    }
    else if (m_ppc_state.msr.FP)
    {
      RunInterpreterOp(*this, m_prev_inst);
      if ((m_ppc_state.Exceptions & EXCEPTION_DSI) != 0)
      {
        CheckExceptions();
      }
    }
    else
    {
      // check if we have to generate a FPU unavailable exception or a program exception.
      if ((opinfo->flags & FL_USE_FPU) != 0)
      {
        m_ppc_state.Exceptions |= EXCEPTION_FPU_UNAVAILABLE;
        CheckExceptions();
      }
      else
      {
        RunInterpreterOp(*this, m_prev_inst);
        if ((m_ppc_state.Exceptions & EXCEPTION_DSI) != 0)
        {
          CheckExceptions();
        }
      }
    }
  }
  else
  {
    // Memory exception on instruction fetch
    CheckExceptions();
  }

  UpdatePC();

  PowerPC::UpdatePerformanceMonitor(opinfo->num_cycles, (opinfo->flags & FL_LOADSTORE) != 0,
                                    (opinfo->flags & FL_USE_FPU) != 0, m_ppc_state);
  return opinfo->num_cycles;
}

void Interpreter::SingleStep()
{
  auto& core_timing = m_system.GetCoreTiming();
  auto& core_timing_globals = core_timing.GetGlobals();

  // Declare start of new slice
  core_timing.Advance();

  SingleStepInner();

  // The interpreter ignores instruction timing information outside the 'fast runloop'.
  core_timing_globals.slice_length = 1;
  m_ppc_state.downcount = 0;

  if (m_ppc_state.Exceptions != 0)
  {
    m_system.GetPowerPC().CheckExceptions();
    m_ppc_state.pc = m_ppc_state.npc;
  }
}

// #define SHOW_HISTORY
#ifdef SHOW_HISTORY
static std::vector<u32> s_pc_vec;
static std::vector<u32> s_pc_block_vec;
constexpr u32 s_show_blocks = 30;
constexpr u32 s_show_steps = 300;
#endif

// FastRun - inspired by GCemu (to imitate the JIT so that they can be compared).
void Interpreter::Run()
{
  auto& core_timing = m_system.GetCoreTiming();
  auto& cpu = m_system.GetCPU();
  auto& power_pc = m_system.GetPowerPC();
  while (cpu.GetState() == CPU::State::Running)
  {
    // CoreTiming Advance() ends the previous slice and declares the start of the next
    // one so it must always be called at the start. At boot, we are in slice -1 and must
    // advance into slice 0 to get a correct slice length before executing any cycles.
    core_timing.Advance();

    // we have to check exceptions at branches apparently (or maybe just rfi?)
    if (Config::IsDebuggingEnabled())
    {
#ifdef SHOW_HISTORY
      s_pc_block_vec.push_back(m_ppc_state.pc);
      if (s_pc_block_vec.size() > s_show_blocks)
        s_pc_block_vec.erase(s_pc_block_vec.begin());
#endif

      // Debugging friendly version of inner loop. Tries to do the timing as similarly to the
      // JIT as possible. Does not take into account that some instructions take multiple cycles.
      while (m_ppc_state.downcount > 0)
      {
        m_end_block = false;
        int cycles = 0;
        while (!m_end_block)
        {
#ifdef SHOW_HISTORY
          s_pc_vec.push_back(m_ppc_state.pc);
          if (s_pc_vec.size() > s_show_steps)
            s_pc_vec.erase(s_pc_vec.begin());
#endif

          if (power_pc.CheckAndHandleBreakPoints())
            return;
          cycles += SingleStepInner();
        }
        m_ppc_state.downcount -= cycles;
      }
    }
    else
    {
      // "fast" version of inner loop. well, it's not so fast.
      while (m_ppc_state.downcount > 0)
      {
        m_end_block = false;

        int cycles = 0;
        while (!m_end_block)
        {
          cycles += SingleStepInner();
        }
        m_ppc_state.downcount -= cycles;
      }
    }
  }
}

namespace
{
// iCube (ICUBE-AW): the full callstack/register dump and the telemetry breadcrumb are emitted for at
// most this many distinct (pc, opcode) pairs per game. A guest handler that returns to the same word
// would otherwise log and breadcrumb once per executed instruction.
constexpr std::size_t MAX_REPORTED_UNKNOWN_INSTRUCTIONS = 8;

struct UnknownInstructionReports
{
  std::mutex mutex;
  std::string game_id;
  std::array<u64, MAX_REPORTED_UNKNOWN_INSTRUCTIONS> keys{};
  std::size_t num_keys = 0;
  u64 total = 0;
};

// True when this (pc, opcode) pair is new and still under the cap, i.e. it should be reported in
// full. `total` is the running count of unknown instructions executed in this game.
bool ShouldReportUnknownInstruction(const std::string& game_id, u32 pc, u32 opcode, u64* total)
{
  static UnknownInstructionReports s_reports;
  std::lock_guard lock(s_reports.mutex);
  if (s_reports.game_id != game_id)
  {
    s_reports.game_id = game_id;
    s_reports.num_keys = 0;
    s_reports.total = 0;
  }
  *total = ++s_reports.total;

  const u64 key = (u64{pc} << 32) | opcode;
  const auto end = s_reports.keys.begin() + s_reports.num_keys;
  if (std::find(s_reports.keys.begin(), end, key) != end ||
      s_reports.num_keys == s_reports.keys.size())
  {
    return false;
  }
  s_reports.keys[s_reports.num_keys++] = key;
  return true;
}
}  // namespace

// iCube (ICUBE-AW, iCube#81): an opcode no table decodes. This used to end in ASSERT_MSG, whose
// "No" answer (or a dismissed alert) called Crash() and killed the app. Real Gekko hardware raises
// a program exception with SRR1[IllegalInstruction] for an illegal opcode, so do that and let the
// game's own exception handler deal with it. Every engine reaches this function: the interpreter
// tables are filled with it, and the CachedInterpreter, the IR engine and the JIT fall back to
// Interpreter::GetInterpreterOp for anything they do not compile. The unknown op is FL_ENDBLOCK,
// so those engines write pc/npc before the call and SRR0 is the faulting instruction everywhere.
// The exception is delivered here (pc = npc = 0x700), the same way SingleStepInner delivers an
// invalid paired-single; the JITs then exit to npc and, because the op info carries FL_SET_MSR,
// reload the memory base for the MSR the exception installed.
void Interpreter::unknown_instruction(Interpreter& interpreter, UGeckoInstruction inst)
{
  DEBUG_ASSERT(Core::IsCPUThread());
  auto& system = interpreter.m_system;
  auto& ppc_state = interpreter.m_ppc_state;
  // ppc_state.pc is the faulting instruction in every engine; m_last_pc is only kept by the plain
  // interpreter's UpdatePC (it is the previous instruction there, and stale under CIR/JIT).
  const u32 pc = ppc_state.pc;
  const u32 lr = LR(ppc_state);
  const std::string game_id = SConfig::GetInstance().GetGameID();

  u64 total = 0;
  if (ShouldReportUnknownInstruction(game_id, pc, inst.hex, &total))
  {
    const std::string disasm = Common::GekkoDisassembler::Disassemble(inst.hex, pc);
    ERROR_LOG_FMT(POWERPC,
                  "IntCPU: Unknown instruction {:08x} at PC = {:08x}  last_PC = {:08x}  LR = {:08x} "
                  "({}), game {}; raising a program exception",
                  inst.hex, pc, interpreter.m_last_pc, lr, disasm, game_id);
    {
      Core::CPUThreadGuard guard(system);
      Dolphin_Debugger::PrintCallstack(guard, Common::Log::LogType::POWERPC,
                                       Common::Log::LogLevel::LNOTICE);
    }
    for (int i = 0; i < 32; i += 4)
    {
      NOTICE_LOG_FMT(POWERPC, "r{}: {:#010x} r{}: {:#010x} r{}: {:#010x} r{}: {:#010x}", i,
                     ppc_state.gpr[i], i + 1, ppc_state.gpr[i + 1], i + 2, ppc_state.gpr[i + 2],
                     i + 3, ppc_state.gpr[i + 3]);
    }

    const std::string crumb =
        fmt::format("unknown instruction {:08x} at pc {:08x} lr {:08x} game {} cpu_core {}",
                    inst.hex, pc, lr, game_id.empty() ? "?" : game_id,
                    static_cast<int>(Config::Get(Config::MAIN_CPU_CORE)));
    Common::RecordBreadcrumb("dolphin.cpu", crumb.c_str());
  }
  else if ((total & (total - 1)) == 0)
  {
    // Past the cap, keep a trace that this is still happening without one line per instruction.
    ERROR_LOG_FMT(POWERPC, "IntCPU: {} unknown instructions so far (latest {:08x} at PC = {:08x})",
                  total, inst.hex, pc);
  }

  GenerateProgramException(ppc_state, ProgramExceptionCause::IllegalInstruction);
  system.GetPowerPC().CheckExceptions();
  interpreter.m_end_block = true;

  if (system.IsPauseOnPanicMode())
    system.GetCPU().Break();
}

void Interpreter::ClearCache()
{
  // Do nothing.
}

void Interpreter::CheckExceptions()
{
  m_system.GetPowerPC().CheckExceptions();
  m_end_block = true;
}

const char* Interpreter::GetName() const
{
#ifdef _ARCH_64
  return "Interpreter64";
#else
  return "Interpreter32";
#endif
}
