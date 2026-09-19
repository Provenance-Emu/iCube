// Copyright 2024 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Core/PowerPC/CachedInterpreter/CachedInterpreter.h"

#include <algorithm>
#include <array>
#include <mutex>
#include <utility>
#include <vector>

#include <fmt/ostream.h>

#include "Core/HLE/HLE.h"

s32 CachedInterpreterEmitter::PoisonCallback(std::ostream& stream, const void* operands)
{
  stream << "PoisonCallback()\n";
  return sizeof(AnyCallback);
}

s32 CachedInterpreter::StartProfiledBlock(std::ostream& stream,
                                          const StartProfiledBlockOperands& operands)
{
  stream << "StartProfiledBlock()\n";
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool profiled>
s32 CachedInterpreter::EndBlock(std::ostream& stream, const EndBlockOperands<profiled>& operands)
{
  fmt::println(stream, "EndBlock<profiled={}>(downcount={}, num_load_stores={}, num_fp_inst={})",
               profiled, operands.downcount, operands.num_load_stores, operands.num_fp_inst);
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
s32 CachedInterpreter::Interpret(std::ostream& stream, const InterpretOperands& operands)
{
  fmt::println(stream, "Interpret<write_pc={:5}>(current_pc=0x{:08x}, inst=0x{:08x})", write_pc,
               operands.current_pc, operands.inst.hex);
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
s32 CachedInterpreter::InterpretAndCheckExceptions(
    std::ostream& stream, const InterpretAndCheckExceptionsOperands& operands)
{
  fmt::println(stream,
               "InterpretAndCheckExceptions<write_pc={:5}>(current_pc=0x{:08x}, inst=0x{:08x}, "
               "downcount={})",
               write_pc, operands.current_pc, operands.inst.hex, operands.downcount);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreter::HLEFunction(std::ostream& stream, const HLEFunctionOperands& operands)
{
  const auto& [system, current_pc, hook_index] = operands;
  fmt::println(stream, "HLEFunction(current_pc=0x{:08x}, hook_index={}) [\"{}\"]", current_pc,
               hook_index, HLE::GetHookNameByIndex(hook_index));
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreter::WriteBrokenBlockNPC(std::ostream& stream,
                                           const WriteBrokenBlockNPCOperands& operands)
{
  const auto& [current_pc] = operands;
  fmt::println(stream, "WriteBrokenBlockNPC(current_pc=0x{:08x})", current_pc);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreter::CheckFPU(std::ostream& stream, const CheckHaltOperands& operands)
{
  const auto& [power_pc, current_pc, downcount] = operands;
  fmt::println(stream, "CheckFPU(current_pc=0x{:08x}, downcount={})", current_pc, downcount);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreter::CheckBreakpoint(std::ostream& stream, const CheckHaltOperands& operands)
{
  const auto& [power_pc, current_pc, downcount] = operands;
  fmt::println(stream, "CheckBreakpoint(current_pc=0x{:08x}, downcount={})", current_pc, downcount);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreter::CheckIdle(std::ostream& stream, const CheckIdleOperands& operands)
{
  const auto& [core_timing, idle_pc] = operands;
  fmt::println(stream, "CheckIdle(idle_pc=0x{:08x})", idle_pc);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreter::FastForwardCtrIdle(std::ostream& stream, const CheckCtrIdleOperands& operands)
{
  const auto& [core_timing, idle_pc, fallthrough_pc] = operands;
  fmt::println(stream, "FastForwardCtrIdle(idle_pc=0x{:08x}, fallthrough_pc=0x{:08x})", idle_pc,
               fallthrough_pc);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreter::MicroOpRecord(std::ostream& stream, const void* payload)
{
  const auto& m = *static_cast<const MicroOpPayload*>(payload);
  fmt::println(stream, "MicroOp(rd={}, ra={}, rb={}, rc={}, imm={:#010x})", m.rd, m.ra, m.rb, m.rc,
               m.imm);
  return sizeof(AnyCallback) + sizeof(MicroOpPayload);
}

s32 CachedInterpreter::InterpretChained(std::ostream& stream, const void* payload)
{
  return Interpret<false>(stream, *static_cast<const InterpretOperands*>(payload));
}

template <bool write_pc>
s32 CachedInterpreter::ExecuteFusedPsqSeq(std::ostream& stream,
                                          const ExecuteFusedPsqSeqOperands& operands)
{
  fmt::print(stream, "FusedPsqSeq (count={}) at PC={:#010x}\n", operands.count,
             operands.current_pc);
  return sizeof(AnyCallback) + sizeof(operands);
}

static std::once_flag s_sorted_lookup_flag;

std::size_t CachedInterpreter::Disassemble(const JitBlock& block, std::ostream& stream)
{
  using LookupKV = std::pair<AnyCallback, AnyDisassemble>;

  // clang-format off
#define LOOKUP_KV(...) {AnyCallbackCast(__VA_ARGS__), AnyDisassembleCast(__VA_ARGS__)}
  // clang-format on

  // Function addresses aren't known at compile-time, so this array is sorted at run-time.
  // Only records the emitter still writes with a typed callback. The chain-capable forms (which
  // replaced EndBlock<false>, Interpret<false>, ExecuteFusedPsqSeq<false>, ...) are added below;
  // naming a template here that nothing emits would leave it uninstantiated at link time.
  static auto base_lookup = std::to_array<LookupKV>({
      LOOKUP_KV(CachedInterpreter::PoisonCallback),
      LOOKUP_KV(CachedInterpreter::StartProfiledBlock),
      LOOKUP_KV(CachedInterpreter::EndBlock<true>),
      LOOKUP_KV(CachedInterpreter::Interpret<true>),
      LOOKUP_KV(CachedInterpreter::InterpretAndCheckExceptions<false>),
      LOOKUP_KV(CachedInterpreter::InterpretAndCheckExceptions<true>),
      LOOKUP_KV(CachedInterpreter::HLEFunction),
      LOOKUP_KV(CachedInterpreter::WriteBrokenBlockNPC),
      LOOKUP_KV(CachedInterpreter::CheckFPU),
      LOOKUP_KV(CachedInterpreter::CheckBreakpoint),
      LOOKUP_KV(CachedInterpreter::CheckIdle),
      LOOKUP_KV(CachedInterpreter::FastForwardCtrIdle),
  });

#undef LOOKUP_KV

  // iCube: chain-capable records (erased signature; one disassembler per record type whichever
  // variant is on the tape). Their callback slot carries CHAIN_TAG, stripped in the loop below.
  static std::vector<LookupKV> sorted_lookup(base_lookup.begin(), base_lookup.end());

  std::call_once(s_sorted_lookup_flag, [] {
    using ErasedDisassemble = s32 (*)(std::ostream&, const void*);
    const auto add = [](AnyCallback callback, ErasedDisassemble disassemble) {
      // Several template forms can share one instantiation (and the linker may fold identical
      // ones), and the table must not hold duplicate keys.
      const bool known = std::ranges::any_of(
          sorted_lookup, [callback](const LookupKV& kv) { return kv.first == callback; });
      if (callback != nullptr && !known)
        sorted_lookup.emplace_back(callback, disassemble);
    };
    for (u32 kind = 0; kind < CI_MEM_KIND_COUNT; ++kind)
    {
      for (u32 form = 0; form < 8; ++form)
      {
        const auto pick = [&](bool checked) {
          return GetLoadStoreFastCallback(static_cast<CIMemKind>(kind), (form & 1) != 0,
                                          (form & 2) != 0, (form & 4) != 0, checked);
        };
        add(pick(false), static_cast<ErasedDisassemble>(CachedInterpreter::LoadStoreFast));
        add(pick(true), static_cast<ErasedDisassemble>(CachedInterpreter::LoadStoreFastChecked));
      }
    }
    for (const AnyCallback handler : GetMicroOpCallbacks())
      add(handler, static_cast<ErasedDisassemble>(MicroOpRecord));
    for (int form = 0; form < 3 * 2 * 2 * 4; ++form)
    {
      add(GetLinkBlockCallback(form % 3, (form / 3) % 2 != 0, (form / 6) % 2 != 0, form / 12),
          static_cast<ErasedDisassemble>(CachedInterpreter::LinkBlock));
    }
    add(AnyCallback{InterpretBcx<false>}, static_cast<ErasedDisassemble>(InterpretBcx));
    add(AnyCallback{InterpretBcx<true>}, static_cast<ErasedDisassemble>(InterpretBcx));
    add(AnyCallback{InterpretBx<false>}, static_cast<ErasedDisassemble>(InterpretBx));
    add(AnyCallback{InterpretBx<true>}, static_cast<ErasedDisassemble>(InterpretBx));
    add(AnyCallback{InterpretBclr<false>}, static_cast<ErasedDisassemble>(InterpretBclr));
    add(AnyCallback{InterpretBclr<true>}, static_cast<ErasedDisassemble>(InterpretBclr));
    add(AnyCallback{InterpretBcctr<false>}, static_cast<ErasedDisassemble>(InterpretBcctr));
    add(AnyCallback{InterpretBcctr<true>}, static_cast<ErasedDisassemble>(InterpretBcctr));
    const ErasedDisassemble check_fpu = +[](std::ostream& stream, const void* payload) -> s32 {
      return CheckFPU(stream, *static_cast<const CheckHaltOperands*>(payload));
    };
    const ErasedDisassemble end_block = +[](std::ostream& stream, const void* payload) -> s32 {
      return EndBlock<false>(stream, *static_cast<const EndBlockOperands<false>*>(payload));
    };
    const ErasedDisassemble psq_seq = +[](std::ostream& stream, const void* payload) -> s32 {
      return ExecuteFusedPsqSeq<false>(stream,
                                       *static_cast<const ExecuteFusedPsqSeqOperands*>(payload));
    };
    add(AnyCallback{CheckFPUChained<false>}, check_fpu);
    add(AnyCallback{CheckFPUChained<true>}, check_fpu);
    add(AnyCallback{EndBlockChained}, end_block);
    add(AnyCallback{ExecuteFusedPsqSeqChained<false>}, psq_seq);
    add(AnyCallback{ExecuteFusedPsqSeqChained<true>}, psq_seq);
    for (u32 form = 0; form < 64; ++form)
    {
      add(GetBranchCondCallback(form & 3, (form & 4) != 0, (form & 8) != 0, (form & 16) != 0,
                                (form & 32) != 0),
          static_cast<ErasedDisassemble>(BranchCond));
    }
    add(AnyCallback{ContinueIfNpc<false>}, static_cast<ErasedDisassemble>(ContinueIfNpc));
    add(AnyCallback{ContinueIfNpc<true>}, static_cast<ErasedDisassemble>(ContinueIfNpc));
    add(AnyCallback{InterpretChained<false>},
        static_cast<ErasedDisassemble>(CachedInterpreter::InterpretChained));
    add(AnyCallback{InterpretChained<true>},
        static_cast<ErasedDisassemble>(CachedInterpreter::InterpretChained));
    for (const AnyCallback direct : GetInterpretDirectCallbacks())
      add(direct, static_cast<ErasedDisassemble>(CachedInterpreter::InterpretChained));
    const auto end = std::ranges::sort(sorted_lookup, {}, &LookupKV::first);
    ASSERT_MSG(DYNA_REC, std::ranges::adjacent_find(sorted_lookup, {}, &LookupKV::first) == end,
               "Sorted lookup should not contain duplicate keys.");
  });

  std::size_t instruction_count = 0;
  for (const u8* normal_entry = block.normalEntry; normal_entry != block.near_end;
       ++instruction_count)
  {
    const auto slot = *reinterpret_cast<const std::uintptr_t*>(normal_entry);
    const auto callback = reinterpret_cast<AnyCallback>(slot & ~CHAIN_TAG);
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
