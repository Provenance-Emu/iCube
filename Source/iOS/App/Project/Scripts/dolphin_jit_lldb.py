"""
dolphin_jit_lldb.py — LLDB helper for Dolphin iOS JIT debugging on iOS 26 TXM devices.

The LuckTXM path in AllocateExecutableMemoryRegion_LuckTXM issues sentinel
breakpoints (`brk #0x69` legacy and/or `brk #0xf00d` universal) that StikDebug
intercepts to authorize TXM.  Under Xcode's LLDB those same brks cause
EXC_BREAKPOINT instead.

This script installs a breakpoint on each sentinel brk that:
  1. Skips the brk by advancing PC by 4 bytes.
  2. Writes 0 to `dolphin_txm_auth_status` to signal "Xcode mode, TXM not authorized".
     AllocateExecutableMemoryRegion_LuckTXM checks this flag and returns early
     (skipping vm_remap) so IsTXMAvailable() returns false and EmulationCoordinator
     falls back to CachedInterpreter + Software VertexLoader.

Under StikDebug the brks are intercepted by StikDebug before LLDB sees them, so
this script's callback never fires — dolphin_txm_auth_status stays 1 and the full
LuckTXM JIT path proceeds normally.

Usage (in Xcode scheme → Run → "LLDB Init File", or in ~/.lldbinit):
    command script import /path/to/dolphin_jit_lldb.py

Or add this to the Xcode scheme's "LLDB Init File":
    command script import $(SOURCE_ROOT)/Source/iOS/App/Project/Scripts/dolphin_jit_lldb.py
"""

import lldb
import struct

# ARM64 brk encodings:  0xD4200000 | (imm16 << 5)
#   brk #0x69   -> 0xD4200D20  (legacy sentinel)
#   brk #0xf00d -> 0xD43E01A0  (universal sentinel: prepare x16=1 / detach x16=0)
_BRK_SENTINELS = (
    struct.pack("<I", 0xD4200D20),
    struct.pack("<I", 0xD43E01A0),
)

_FUNC_NAME = "Common::AllocateExecutableMemoryRegion_LuckTXM"
_AUTH_FLAG = "dolphin_txm_auth_status"
_MAX_SCAN_BYTES = 512  # scan at most this many bytes looking for the brks


def _find_brks_in_function(target: lldb.SBTarget, process: lldb.SBProcess) -> list:
    """Return load addresses of every sentinel brk inside the LuckTXM function."""
    sym_ctxs = target.FindSymbols(_FUNC_NAME)
    if sym_ctxs.GetSize() == 0:
        return []

    sym = sym_ctxs.GetContextAtIndex(0).GetSymbol()
    start = sym.GetStartAddress().GetLoadAddress(target)
    if start == lldb.LLDB_INVALID_ADDRESS:
        return []

    err = lldb.SBError()
    data = process.ReadMemory(start, _MAX_SCAN_BYTES, err)
    if err.Fail() or not data:
        return []

    addrs = []
    for offset in range(0, len(data) - 3, 4):
        if data[offset : offset + 4] in _BRK_SENTINELS:
            addrs.append(start + offset)

    return addrs


def _write_auth_flag_zero(target: lldb.SBTarget, process: lldb.SBProcess):
    """Write 0 to dolphin_txm_auth_status so the C++ code detects Xcode mode."""
    sym_ctxs = target.FindSymbols(_AUTH_FLAG)
    if sym_ctxs.GetSize() == 0:
        print(f"[DolphinJIT] WARNING: symbol '{_AUTH_FLAG}' not found; "
              "interpreter fallback may not trigger automatically")
        return

    addr = sym_ctxs.GetContextAtIndex(0).GetSymbol().GetStartAddress().GetLoadAddress(target)
    if addr == lldb.LLDB_INVALID_ADDRESS:
        print(f"[DolphinJIT] WARNING: '{_AUTH_FLAG}' has invalid load address")
        return

    err = lldb.SBError()
    # Write int 0 (4 bytes, little-endian) — matches `volatile int dolphin_txm_auth_status`
    process.WriteMemory(addr, b'\x00\x00\x00\x00', err)
    if err.Fail():
        print(f"[DolphinJIT] WARNING: failed to clear auth flag: {err.GetCString()}")
    else:
        print(f"[DolphinJIT] Cleared {_AUTH_FLAG} → interpreter fallback will activate")


def _skip_brk_handler(frame: lldb.SBFrame, bp_loc, extra_args, internal_dict) -> bool:
    """Breakpoint callback: advance PC past the sentinel brk and signal Xcode mode."""
    thread = frame.GetThread()
    process = thread.GetProcess()
    target = process.GetTarget()
    pc = frame.GetPC()

    err = lldb.SBError()
    for reg_set in frame.GetRegisters():
        for reg in reg_set:
            if reg.GetName() == "pc":
                reg.SetValueFromCString(hex(pc + 4), err)
                break

    if err.Fail():
        print(f"[DolphinJIT] WARNING: failed to advance PC: {err.GetCString()}")
    else:
        print(f"[DolphinJIT] Skipped sentinel brk at {hex(pc)}, resuming at {hex(pc + 4)}")

    # Signal Xcode mode so AllocateExecutableMemoryRegion_LuckTXM bails out early
    # and EmulationCoordinator falls back to interpreter + software vertex loader.
    _write_auth_flag_zero(target, process)

    # Return False = don't stop the debugger; auto-continue handles the resume.
    return False


def _install(target: lldb.SBTarget, process: lldb.SBProcess) -> bool:
    brk_addrs = _find_brks_in_function(target, process)
    if not brk_addrs:
        return False

    for brk_addr in brk_addrs:
        bp = target.BreakpointCreateByAddress(brk_addr)
        bp.SetAutoContinue(True)
        bp.SetScriptCallbackFunction("dolphin_jit_lldb._skip_brk_handler")
        print(f"[DolphinJIT] Installed sentinel-brk skip-handler at {hex(brk_addr)}")
    return True


# --- stop-hook so we can (re-)install after a fresh library load ---------------

class _LoadHook:
    """SBTarget stop-hook: install the breakpoint once the symbol is visible."""

    def __init__(self):
        self._installed = False

    def handle_stop(self, exe_ctx: lldb.SBExecutionContext, stream: lldb.SBStream) -> bool:
        if self._installed:
            return False  # nothing more to do

        target = exe_ctx.GetTarget()
        process = exe_ctx.GetProcess()
        if not target.IsValid() or not process.IsValid():
            return False

        if _install(target, process):
            self._installed = True

        return False  # don't stop the process


_hook_instance = _LoadHook()


def __lldb_init_module(debugger: lldb.SBDebugger, internal_dict: dict):
    """Entry point called by `command script import`."""
    # Try immediate install if a target/process already exists.
    target = debugger.GetSelectedTarget()
    if target and target.IsValid():
        process = target.GetProcess()
        if process and process.IsValid():
            _install(target, process)

    # Register a stop-hook so we catch the symbol after dylib load.
    target = debugger.GetSelectedTarget()
    if target and target.IsValid():
        target.SetStopHookScriptCode("dolphin_jit_lldb._hook_instance.handle_stop")

    print("[DolphinJIT] Loaded. Sentinel brks (0x69 / 0xf00d) in "
          "AllocateExecutableMemoryRegion_LuckTXM will be skipped automatically under "
          "Xcode's LLDB; interpreter fallback activates when TXM is not authorized by StikDebug.")
