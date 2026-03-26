// Copyright 2024 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <cstddef>
#include <iosfwd>
#include <type_traits>

#include "Common/CodeBlock.h"
#include "Common/CommonTypes.h"

namespace PowerPC
{
struct PowerPCState;
}

class CachedInterpreterEmitter
{
protected:
  // The return value of most callbacks is the distance in memory to the next callback.
  // If a callback returns 0, the block will be exited. The return value is signed to
  // support block-linking. 32-bit return values seem to perform better than 64-bit ones.
  template <class Operands>
  using Callback = s32 (*)(PowerPC::PowerPCState& ppc_state, const Operands& operands);
  using AnyCallback = s32 (*)(PowerPC::PowerPCState& ppc_state, const void* operands);

  template <class Operands>
  static consteval Callback<Operands> CallbackCast(Callback<Operands> callback)
  {
    return callback;
  }
  template <class Operands>
  static AnyCallback AnyCallbackCast(Callback<Operands> callback)
  {
    return reinterpret_cast<AnyCallback>(callback);
  }
  static consteval AnyCallback AnyCallbackCast(AnyCallback callback) { return callback; }

  // Disassemble callbacks will always return the distance to the next callback.
  template <class Operands>
  using Disassemble = s32 (*)(std::ostream& stream, const Operands& operands);
  using AnyDisassemble = s32 (*)(std::ostream& stream, const void* operands);

  template <class Operands>
  static AnyDisassemble AnyDisassembleCast(Disassemble<Operands> disassemble)
  {
    return reinterpret_cast<AnyDisassemble>(disassemble);
  }
  static consteval AnyDisassemble AnyDisassembleCast(AnyDisassemble disassemble)
  {
    return disassemble;
  }

public:
  CachedInterpreterEmitter() = default;
  explicit CachedInterpreterEmitter(u8* begin, u8* end) : m_code(begin), m_code_end(end) {}

  // Minimal callback IDs for id-dispatch mode. The header size remains sizeof(AnyCallback)
  // to keep existing callbacks' return distances correct.
  enum class CallbackId : u16
  {
    Poison = 0,
    InterpretFalse = 1,
    InterpretTrue = 2,
    EndBlockUnprofiled = 3,
    EndBlockProfiled = 4,
    // Hot path memory helpers (PIC addressing): register both write-pc variants
    LoadStoreDFormPICFalse = 5,
    LoadStoreDFormPICTrue = 6,
    LoadStoreXFormPICFalse = 7,
    LoadStoreXFormPICTrue = 8,
    // HLE entry
    HLEFunction = 9,
    // Placeholder for future ID-only link macro
    LinkToBlockEndDistance = 10,
    // Small control callbacks
    CheckIdle = 11,
    CheckBreakpoint = 12,
    CheckFPU = 13,
    WriteBrokenBlockNPC = 14,
  };

  // Public constant: size of the callback header (either pointer or ID+tag+pad)
  static constexpr std::size_t kHeaderSize = sizeof(AnyCallback);

  // Operands for ID-only link macro: return precomputed distance to next callback.
  struct LinkToBlockDistanceOperands
  {
    // Signed distance (in bytes) to add to the current callback address to reach the target.
    s32 distance;
  };

  template <class Operands>
  void Write(Callback<Operands> callback, const Operands& operands)
  {
    // I would use std::is_trivial_v, but almost every operands struct uses
    // references instead of pointers to make the callback functions nicer.
    static_assert(
        std::is_trivially_copyable_v<Operands> && std::is_trivially_destructible_v<Operands> &&
        alignof(Operands) <= alignof(AnyCallback) && sizeof(Operands) % alignof(AnyCallback) == 0);
    Write(AnyCallbackCast(callback), &operands, sizeof(Operands));
  }
  void Write(AnyCallback callback) { Write(callback, nullptr, 0); }

  // Write callback and return the address where the callback pointer was stored.
  // This is useful for later patching (e.g., block linking). Only used by the
  // cached interpreter internals; normal code should use Write above.
  template <class Operands>
  u8* WriteGetPtr(Callback<Operands> callback, const Operands& operands)
  {
    static_assert(
        std::is_trivially_copyable_v<Operands> && std::is_trivially_destructible_v<Operands> &&
        alignof(Operands) <= alignof(AnyCallback) && sizeof(Operands) % alignof(AnyCallback) == 0);
    return WriteReturningAddress(AnyCallbackCast(callback), &operands, sizeof(Operands));
  }

  // Reserve space for N callbacks + operands to avoid bounds checks per Write.
  void Reserve(std::size_t bytes)
  {
    if (static_cast<std::size_t>(m_code_end - m_code) < bytes)
      m_write_failed = true;
  }

  const u8* GetCodePtr() const { return m_code; }
  u8* GetWritableCodePtr() { return m_code; }
  const u8* GetCodeEnd() const { return m_code_end; }
  u8* GetWritableCodeEnd() { return m_code_end; }
  // Should be checked after a block of code has been generated to see if the code has been
  // successfully written to memory. Do not call the generated code when this returns true!
  bool HasWriteFailed() const { return m_write_failed; }

  // No-op stubs for cross-platform CodeBlock<T> interface (writable region is iOS/ARM64 only)
  ptrdiff_t GetWritableRegionDiff() { return 0; }
  void SetWritableRegionDiff(ptrdiff_t) {}

  void SetCodePtr(u8* begin, u8* end)
  {
    m_code = begin;
    m_code_end = end;
    m_write_failed = false;
  }

  // Enable or disable opcode-id dispatch emission. When enabled, Write() will emit
  // a 16-bit CallbackId followed by padding to sizeof(AnyCallback), then operands.
  // This keeps callback return distances unchanged.
  static void SetUseIdDispatch(bool enabled) { s_use_id_dispatch = enabled; }
  static bool IsIdDispatchEnabled() { return s_use_id_dispatch; }

  static s32 PoisonCallback(PowerPC::PowerPCState& ppc_state, const void* operands);
  static s32 PoisonCallback(std::ostream& stream, const void* operands);

private:
  void Write(AnyCallback callback, const void* operands, std::size_t size);
  // Same as Write but returns the address where the callback pointer was stored.
  u8* WriteReturningAddress(AnyCallback callback, const void* operands, std::size_t size);

public:
  // Registration API: allow clients (e.g., CachedInterpreter) to register IDs for callbacks.
  // When id-dispatch is enabled, registered callbacks will be emitted as CallbackId headers
  // rather than function pointers. Unregistered callbacks fall back to pointer emission.
  static void RegisterIdForCallback(AnyCallback callback, CallbackId id);
  template <class Operands>
  static void RegisterIdForCallback(Callback<Operands> callback, CallbackId id)
  {
    RegisterIdForCallback(AnyCallbackCast(callback), id);
  }

  // Stats: number of headers emitted as ID vs function pointer
  static inline u64 GetIdHeaderCount() { return s_id_headers_emitted; }
  static inline u64 GetPtrHeaderCount() { return s_ptr_headers_emitted; }

  // Pointer to memory where code will be emitted to.
  u8* m_code = nullptr;
  // Pointer past the end of the memory region we're allowed to emit to.
  // Writes that would reach this memory are refused and will set the m_write_failed flag instead.
  u8* m_code_end = nullptr;
  // Set to true when a write request happens that would write past m_code_end.
  // Must be cleared with SetCodePtr() afterwards.
  bool m_write_failed = false;

  // Global toggle: when true, emitter writes ID-based headers instead of function pointers.
  inline static bool s_use_id_dispatch = false;

  inline static u64 s_id_headers_emitted = 0;
  inline static u64 s_ptr_headers_emitted = 0;
};

class CachedInterpreterCodeBlock : public Common::CodeBlock<CachedInterpreterEmitter, false>
{
private:
  void PoisonMemory() override;
};
