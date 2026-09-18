"""
dolphin_jit_lldb.py — LLDB JIT page-blessing broker for iCube on iOS 26 TXM devices.

On iOS 26+ TXM devices a page mapped R-X cannot be executed until a debugger has
WRITTEN to it; the debugger write itself is what blesses the page, so every 16 KB
page of the JIT region must be dirtied individually. StikDebug does this from its
JavaScript broker (icube.js / universal.js); this script does the same from LLDB,
so Xcode (or a command-line lldb attached through any debugserver) can stand in
for StikDebug. The approach is RetroArch's pkg/apple/lldb_jit_bless.py.

Protocol serviced (see MemoryUtil_iOS_LuckTXM.cpp):
  * legacy    brk #0x69            x0 = region address, x1 = size   (icube.js)
  * universal brk #0xf00d, x16=1   x0 = region address, x1 = size   (universal.js)
  * universal brk #0xf00d, x16=0   detach request — acknowledged, we stay attached
                                   (DOL_BLESS_HONOR_DETACH=1 detaches for real)
After blessing, x0 is left as the region address (a 0xE0000069 in x0 would tell
the C++ side the legacy sentinel was rejected) and pc advances past the brk, so
AllocateExecutableMemoryRegion_LuckTXM continues into vm_remap with the region
authorized and IsTXMAvailable() reports true.

Matching is on the trapping instruction, not on a symbol, so it works in release
builds and for every call site.

Usage:
  * Xcode: scheme > Run > Options > "LLDB Init File" = the repo's .lldbinit
    (Project.swift sets this on the iCube schemes), or ~/.lldbinit:
        command script import <repo>/Source/iOS/App/Project/Scripts/dolphin_jit_lldb.py
  * command-line lldb attached to the app: same `command script import`.

Tuning:
  DOL_BLESS_PAGES_PER_WRITE (default 1): pages dirtied per debugger write. A write
  spanning k pages blesses all k but transfers (k-1)*16 KB + 1 bytes, so >1 trades
  bytes for round-trips; 1 is what StikDebug does.
"""

import os
import time

import lldb

BRK_0069 = 0xD4200D20   # brk #0x69   (legacy sentinel, icube.js)
BRK_F00D = 0xD43E01A0   # brk #0xf00d (universal sentinel)
CMD_DETACH = 0
CMD_PREPARE_REGION = 1

PAGE_SIZE = 0x4000      # arm64 iOS
FILL_BYTE = 0x69        # the byte StikDebug writes

PAGES_PER_WRITE = max(1, int(os.environ.get("DOL_BLESS_PAGES_PER_WRITE", "1")))
HONOR_DETACH = os.environ.get("DOL_BLESS_HONOR_DETACH") == "1"


def _read_u32(process, addr):
    err = lldb.SBError()
    data = process.ReadMemory(addr, 4, err)
    if not err.Success() or data is None or len(data) != 4:
        return None
    return int.from_bytes(data, "little")


def _bless(process, ptr, size, log):
    """Dirty every page in [ptr, ptr+size) with debugger writes."""
    if size == 0:
        return True, 0

    first = ptr & ~(PAGE_SIZE - 1)
    last = (ptr + size + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1)
    pages = (last - first) // PAGE_SIZE

    started = time.monotonic()
    done = 0
    while done < pages:
        group = min(PAGES_PER_WRITE, pages - done)
        buf = bytes([FILL_BYTE]) * ((group - 1) * PAGE_SIZE + 1)
        err = lldb.SBError()
        addr = first + done * PAGE_SIZE
        process.WriteMemory(addr, buf, err)
        if not err.Success():
            log("[DolphinJIT] bless write failed at 0x%x after %d/%d pages: %s"
                % (addr, done, pages, err.GetCString()))
            return False, done
        done += group

    log("[DolphinJIT] blessed %d pages (%.1f MB) at 0x%x in %.2fs"
        % (pages, pages * PAGE_SIZE / (1024.0 * 1024.0), ptr,
           time.monotonic() - started))
    return True, pages


class JITBlessHook:
    """Stop hook that services the sentinel brks wherever they are executed."""

    def __init__(self, target, extra_args, internal_dict):
        pass

    def handle_stop(self, exe_ctx, stream):
        def log(msg):
            stream.Print(msg + "\n")

        process = exe_ctx.GetProcess()
        frame = exe_ctx.GetFrame()
        if not frame.IsValid():
            return True

        pc = frame.GetPC()
        instr = _read_u32(process, pc)
        if instr == BRK_0069:
            cmd = CMD_PREPARE_REGION
        elif instr == BRK_F00D:
            cmd = frame.FindRegister("x16").GetValueAsUnsigned()
        else:
            return True                  # not ours; stop normally

        if cmd == CMD_PREPARE_REGION:
            ptr = frame.FindRegister("x0").GetValueAsUnsigned()
            size = frame.FindRegister("x1").GetValueAsUnsigned()
            if ptr == 0:
                log("[DolphinJIT] x0=0 asks the debugger to allocate the region; not implemented")
                return True
            ok, _ = _bless(process, ptr, size, log)
            if not ok:
                # Stay stopped at the brk: continuing would report success for
                # pages that were never blessed.
                return True
            frame.FindRegister("x0").SetValueFromCString("0x%x" % ptr)
        elif cmd == CMD_DETACH:
            if HONOR_DETACH:
                log("[DolphinJIT] detaching")
                frame.SetPC(pc + 4)
                process.Detach()
                return False
            log("[DolphinJIT] detach requested; staying attached")
        else:
            log("[DolphinJIT] unknown command x16=%d at 0x%x" % (cmd, pc))
            return True

        if not frame.SetPC(pc + 4):
            log("[DolphinJIT] could not advance pc past brk at 0x%x" % pc)
            return True
        return False                     # handled; auto-continue


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand(
        "target stop-hook add -P %s.JITBlessHook" % __name__)
    print("[DolphinJIT] TXM JIT bless hook installed: brk #0x69 / #0xf00d will be "
          "answered by blessing the region's pages (%d page(s) per write)." % PAGES_PER_WRITE)
