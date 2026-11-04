# iCube #76 findings 2 and 3: read-only source report

Date: 2026-11-03. Source baseline: iCube `develop` `49b114f18c`. Scope: finding 2 of
[#76](https://github.com/Provenance-Emu/iCube/issues/76) (fatal `Interpreter::unknown_instruction`,
Sentry ICUBE-AW, tracked in [#81](https://github.com/Provenance-Emu/iCube/issues/81), release
workstream R5 [#56](https://github.com/Provenance-Emu/iCube/issues/56)) and finding 3 (ICUBE-M5 main-thread
hang in the Action Replay code editor, umbrella [#45](https://github.com/Provenance-Emu/iCube/issues/45)).

This report changes no product code. Sentry could not be queried from this session (the CLI call was
refused), so every event fact below is what the #69 and #76 triage reports recorded; everything else is
read from source at the line numbers given.

Owners checked: no open PR or branch on `origin` touches `Interpreter.cpp`, `Assert.h`,
`MsgAlertManager.mm` or the two cheat editors. A proposal branch exists locally
(`fix/aw-unknown-instr`, worktree `~/Workspace/Provenance/_worktrees/icube-aw-unknown-instr`),
not pushed and not merged; it is the implementation candidate for the design in section 2.6 and
section 3.6, to be reviewed by the owner before anything lands.

---

## 1. Classification

| Finding | Sentry | Users / 7d (per #76) | Class | Why |
|---|---|---|---|---|
| 2. `unknown_instruction` traps the process | ICUBE-AW | 27 (78 events since 2026-09-27), App Store, `jit:none` | **Release blocker (R5)** | Deliberate `__builtin_trap()` in a shipping App Store build on a path a game can reach; flagged by two consecutive triages; fix is small and contained. |
| 3. Action Replay editor hang | ICUBE-M5 | 1 (20.6 to 21.4 s hang) | **Deferrable, fix is one-liner-sized** | One user; it is a hang, not a crash; the editor is a niche surface. Worth fixing in the same release because the change is tiny and identical in a second editor, but it does not gate 1.0. |

---

## 2. Finding 2: `Interpreter::unknown_instruction` is fatal

### 2.1 Confirmed from source

**The dispatch table routes every undecoded opcode here, on every engine.**
`Source/Core/Core/PowerPC/Interpreter/Interpreter_Tables.cpp` fills each primary and extended table
with `Interpreter::unknown_instruction` before placing real handlers (lines 342, 352, 387, 397, 407,
417). The cached interpreter resolves handlers through `Interpreter::GetInterpreterOp`
(`Source/Core/Core/PowerPC/CachedInterpreter/CachedInterpreter.cpp:1131`) and the JIT's fallback does the
same (`Source/Core/Core/PowerPC/JitArm64/Jit.cpp:283-300`, `GetInterpreterOp` at :299). One fix in
`unknown_instruction` therefore covers interpreter, cached interpreter and JIT fallback.

**The function logs, then asserts with a yes/no question, and "No" traps.**
`Source/Core/Core/PowerPC/Interpreter/Interpreter.cpp:289-318`: it takes a `CPUThreadGuard`
(:293), reads and disassembles the opcode at `m_last_pc` (:295-297), prints the callstack (:299-300) and
the 32 GPRs (:306-311), then `ASSERT_MSG(POWERPC, 0, ...)` (:312-314), then `CPU().Break()` only when
`IsPauseOnPanicMode()` (:316-317). `ASSERT_MSG` is `Source/Core/Common/Assert.h:11-23`: when
`PanicYesNoFmtAssert` returns false it calls `Crash()`, which is `__builtin_trap()` on non-Windows
(`Source/Core/Common/CommonFuncs.h:18-21`). That is the `EXC_BREAKPOINT` Sentry records.

**Two ways the answer is "No" in iCube, and one of them needs no user.**
`Source/Core/Common/MsgHandler.cpp:119-144` (`ShowMessageAlert`) forwards to the registered handler when
one exists and alerts are enabled or the style is Question/Critical. iCube registers
`MsgAlertManager` (`Source/iOS/App/Common/UI/Alert/MsgAlertManager.mm:71-73`).
`handleAlertWithCaption:...` (:75-212):
- (a) `mainScene == nil` returns `false` immediately (:108-113). A scene that is disconnected or not yet
  attached (background, scene teardown, early boot) therefore answers "No" with no dialog, and the
  assert traps. This is the path that needs no user action.
- (b) With a scene, a blocking `UIAlertController` is shown with "No" and "Yes" (:120-200); the emulation
  thread waits on `_waitEvent` (:203-205). "No" returns false and traps. The dialog text is the raw
  assert ("An error occurred ... Ignore and continue?"), so a player has no basis to choose.

**The core's default handler traps too.** *(Corrected after review: an earlier draft said the core
skips the assert when no handler is registered.)* `s_msg_handler` starts as `DefaultMsgHandler`
(`MsgHandler.cpp:50`), not null. On non-Windows builds that handler prints the text and returns
`false`, with the upstream comment "Return no to any question (which will in general crash the
emulator)" (`MsgHandler.cpp:36-40`). `ShowMessageAlert` returns `true` (ignore and continue) only
when the handler is null, or when alerts are disabled and the style is not Question or Critical
(:136-142). `ASSERT_MSG` goes through `PanicYesNoFmtAssert`, which is `MsgType::Warning`
(`MsgHandler.h:146-147`), so the one non-fatal default is "Use Panic Handlers" turned off.
`SetAbortOnPanicAlert` is false by default (`MsgHandler.cpp:53`). So the trap is the core's own
design: upstream treats an unknown opcode as a developer question whose "No" ends the process.
iCube's no-scene path (a) reproduces the default handler's answer without a user.

**The breadcrumb exists but is not enough to name the instruction.** The handler records a
`dolphin.msgalert` breadcrumb with the alert text (:83-85) and the answer
(`Source/iOS/App/Common/Services/SentryTelemetryService.swift:533-546`). The assert text includes PC,
last PC, LR and the raw opcode (`Interpreter.cpp:312-314`), so the next event already carries opcode+PC
in breadcrumbs. What is missing is the game id and the engine (interpreter vs cached vs JIT fallback)
on the same crumb, and the fact that the dump work (callstack and 32 GPRs) runs before the question
on the emulation thread.

**A safe, hardware-faithful recovery already exists two functions up.** `Interpreter::SingleStepInner`
(`Interpreter.cpp:153-158`) raises `GenerateProgramException(m_ppc_state,
ProgramExceptionCause::IllegalInstruction)` then `CheckExceptions()` for invalid paired-single use.
`GenerateProgramException` is `Source/Core/Core/PowerPC/Interpreter/ExceptionUtils.h:30` with
`IllegalInstruction = 1 << (31 - 12)` (:13), the SRR1 bit real Gekko sets for an illegal opcode.

### 2.2 Unknowns

- Which game and which opcode. No event in the two triages names a title. The opcode and PC are in the
  breadcrumb text but were not extracted in the triage. **First experiment** (below) answers this
  with no code change.
- Whether the opcodes are truly illegal (data executed as code after a guest crash, a bad ROM patch,
  a mod launcher) or valid Gekko instructions the interpreter lacks. The former wants a program
  exception; the latter wants an implementation. The dump of `inst.hex` decides it.
- Whether path (a) (no scene) or path (b) ("No" tapped) dominates. The answer crumb (`answered No`)
  is recorded only on path (b) (`MsgAlertManager.mm:207-209`), so events without it are path (a).

### 2.3 Safe failure and recovery boundaries (what must not happen)

1. Never `__builtin_trap()` from guest-reachable code in a Release build. The App Store build has no
   developer behind the dialog.
2. Never resume by silently skipping the instruction. Skipping executes the next instruction with
   state the game did not expect; the guest may corrupt its own saves or memory cards. Real hardware
   does not skip, it raises a program exception and the guest's handler (or the system menu's) decides.
3. Never block the emulation thread on a dialog during gameplay. The blocking alert is already a
   hang-class defect by itself (the thread holds `CPUThreadGuard` while waiting, :293).
4. The dump work (callstack, GPRs) must not run per occurrence in Release. A guest spinning in a bad
   code region would call this at full speed.

### 2.4 Minimal experiments (no product edit)

1. **Read the existing crumbs.** In Sentry, open the latest ICUBE-AW event, copy the
   `dolphin.msgalert` breadcrumb message: it contains `Unknown instruction XXXXXXXX at PC = ...`.
   Decode `XXXXXXXX` with `Common::GekkoDisassembler` or any PPC disassembler. Also record whether an
   `answered No` crumb follows (path b) or not (path a), and the `game`/`title` tag if present.
   Cost: minutes. Decides illegal-vs-unimplemented and which path.
2. **Confirm the no-scene path in a Debug build.** Background the app during gameplay of any title,
   trigger any `PanicYesNo` (a simulator Debug build can call `PanicYesNoFmt` from the debug menu
   or `lldb expr`), and observe `MsgAlertManager.mm:110-113` return false. Cost: 15 minutes.
3. **Measure the dump cost.** On device, time one call of the callstack+GPR dump (:299-311) at NOTICE
   level; it tells whether rate-limiting is needed or whether the log sink makes it negligible.

### 2.5 Diagnostics to ship (small, no behaviour change)

- A dedicated `dolphin.unknown_instruction` breadcrumb with: `inst.hex`, `pc`, `last_pc`, `LR`,
  engine (`interpreter` / `cached` / `jit-fallback`), game id and title id, and a monotonic count for
  this session. Emitted once per distinct (`pc`, `inst.hex`) pair, max N per session.
- Record whether a scene was attached when a MsgAlert question was asked (one boolean on the existing
  `dolphin.msgalert` crumb), so path (a) is visible without inference.

### 2.6 Narrow design proposal (for owner review, not applied here)

In `Interpreter::unknown_instruction` only:
1. Replace `ASSERT_MSG` with `GenerateProgramException(ppc_state, ProgramExceptionCause::IllegalInstruction)`
   **and deliver it before execution advances**. *(Corrected after review: setting the flag alone is
   not enough.)* `SingleStepInner` checks only `EXCEPTION_DSI` after `RunInterpreterOp` and then calls
   `UpdatePC()` (`Interpreter.cpp:162-192`), and `CheckExceptions` takes SRR0 from the current PC
   (`PowerPC.cpp:480-487`). A pending flag would let the next instructions run and record the wrong
   fault address. So the op must call `CheckExceptions()` itself and set `m_end_block`, exactly as
   `Interpreter::sc` does (`Interpreter_Branch.cpp:172-179`). Each engine then needs its own check:
   - Interpreter: pc = npc = 0x700 after the op, and `UpdatePC` keeps it.
   - Cached interpreter: the op is `FL_ENDBLOCK`, so it runs through `Interpret<true>` (pc written
     first) and the block ends with a plain EndBlock, as `sc` does.
   - JIT: the fallback writes pc/npc first and exits to npc. Because the exception is already
     delivered, `WriteExceptionExit` sees no pending exception and skips its membase reload, so the op
     info must carry `FL_SET_MSR` to reload the memory base for the new MSR.
   - All engines: the op must cost at least one cycle. An illegal word at 0x700 then loops, and a
     zero-cycle loop never lets downcount expire, so pause and stop would never run.

   Keep `if (system.IsPauseOnPanicMode()) system.GetCPU().Break();` so developers who want a stop
   still get one.
2. Keep the NOTICE logging, but gate the callstack and GPR dump behind a per-session rate limit
   (first N distinct pairs), so a guest spinning in bad code cannot flood the log or stall the thread.
3. Emit the breadcrumb of 2.5 through the existing Sentry bridge (`DOLSentryTelemetryBridge`).
4. Do not touch `Assert.h`, `MsgHandler.cpp` or `MsgAlertManager.mm` for this fix; the other asserts
   in the tree keep their current semantics, and the dialog path for genuine panics is unchanged.

Why not "log and skip": see 2.3 item 2. Why not keep the dialog: the dialog is a developer tool on a
path only a game can reach, and it traps with no user when no scene is attached.

Risk: a game that previously "worked" because the player tapped Yes (continue, skipping the
instruction) will now take a program exception. On real hardware that is what it would do. Dolphin
desktop skips only when the player answers Yes or has panic handlers disabled; otherwise it traps
like iCube. If the owner prefers skipping, step 1 becomes "do nothing after logging", which is also
non-fatal; the report recommends the exception because skipping hides the fault from the guest.

**Implemented in #89** with all of the above. A test disc (`Tools/unknown-op-disc`) records SRR0 = the
bad word and SRR1[IllegalInstruction] on the interpreter and the cached interpreter in the simulator.
A variant with an illegal word at 0x700 hung on stop before the one-cycle change and stops in 2 s
after it. The JIT path is unverified there: the simulator has no JIT.

Verification required before merge: the core slices under `build/xcframework` are tracked and must be
rebuilt with the change (the project's convention, see commit `87b3d34ee1`); then a Debug-build
check that a hand-written illegal opcode (e.g. `0x00000001` placed in a test DOL) produces a program
exception rather than a trap.

---

## 3. Finding 3: Action Replay code editor hang (ICUBE-M5)

### 3.1 Confirmed from source

`Source/iOS/App/Common/UI/Cheats/ActionReplay/ActionReplayCodeEditViewController.mm:50-53`:
```objc
- (void)textViewDidChange:(UITextView*)textView {
  [self.tableView beginUpdates];
  [self.tableView endUpdates];
}
```
The same four lines exist in `Source/iOS/App/Common/UI/Cheats/Gecko/GeckoCodeEditViewController.mm:57-60`
(that editor also has a `notesView`, so the Gecko editor fires it for two text views).

Why the pair exists: both editors are static-cell `UITableViewController`s (`ActionReplay.storyboard:14-15`,
`dataMode="static"`, `rowHeight="-1" estimatedRowHeight="-1"`) whose code cell holds a `UITextView`
with `scrollEnabled="NO"` (`ActionReplay.storyboard:63`), so the cell is self-sizing from the text view's
intrinsic height. `beginUpdates`/`endUpdates` is the only thing that makes the row grow when a line is
added; removing it would freeze the row height. The code dates from the original editor commit
`7d1d468c67`.

What one call costs: `endUpdates` re-measures every self-sizing cell in the static table, which asks the
text view for its full content height. With TextKit 2 (`NSTextLayoutManager`,
`NSTextViewportLayoutController`, both present in the ICUBE-M5 stack per #76) a non-scrolling text
view lays out its entire text to answer that question, so the cost is linear in the text length, and the
animation pass makes it worse.

### 3.2 Event evidence versus hypothesis

What the event shows (per #76): one user, one hang of 20.6 to 21.4 s, main thread, app frame
`-[ActionReplayCodeEditViewController textViewDidChange:]` above `beginUpdates`/`endUpdates` and
TextKit 2 layout. That is strong evidence the hang is inside this delegate call.

What the event does not show: whether it was one call (a paste of a long code list, or a long delete)
or a cascade of per-keystroke calls. A single hang of 20 s is more consistent with one call on a very
long text than with typing: a keystroke cascade would produce many short hangs that Sentry reports as
several events, and typing 20 s of text is itself 20 s of input. The "per-keystroke" phrasing in #76
describes the mechanism correctly but the triggering event was most likely a paste or a programmatic
`setText` on a long code. `viewDidLoad` sets `codeView.text` (:37) before the delegate is active, so
opening a long code does not go through this path; editing it does.

### 3.3 Minimal repro to distinguish (device or simulator, Debug build, no product edit)

Open Cheats, Action Replay, edit a code. Measure with Instruments (Time Profiler, main thread) or
`os_signpost` around the delegate:
1. **Short paste**: paste 10 lines of `00000000 00000000`. Expect sub-100 ms.
2. **Long paste**: paste 2,000 lines (16 KB). Expect a single main-thread stall of seconds; this is the
   ICUBE-M5 shape if the hypothesis holds.
3. **Keyboard**: type 50 characters at the end of the 2,000-line code. Expect 50 stalls, each about as
   long as the long-paste stall, because every keystroke re-measures the whole text.
4. Repeat 2 and 3 in the Gecko editor.
Record the stall per call versus line count; if it is linear, the fix in 3.6 is sufficient.

Measured evidence still needed: the per-call cost at 100 / 1,000 / 2,000 lines on a current iPhone and
on an Apple TV (tvOS runs the same controllers), plus one confirmation that case 2 reproduces a Sentry
app-hang report in a Debug build with Sentry enabled.

### 3.4 Unknowns

- The user's text length and whether the input was a paste. Not recoverable from the stack.
- Whether iOS 26's TextKit 2 is slower here than TextKit 1 was (the editor predates TextKit 2
  being the default for `UITextView`). Case 2 on an iOS 17 device would show it.

### 3.5 Safe boundaries

The editor holds a copy of the code text in the text view only; nothing is written to the cheat list
until Save (`savePressed:` :55-125 parses on a background queue). A hang here cannot corrupt the
user's cheats or saves. The Save path has its own main-thread wait (`Common::Event` at :95-120 with a
dialog per bad line), which is a separate, lower-severity issue: a code with many bad lines prompts
once per line.

### 3.6 Narrow design proposal (for owner review, not applied here)

In both editors' `textViewDidChange:`:
- Cache the text view's last measured content height; call `beginUpdates`/`endUpdates` only when the
  new height differs (compute with `sizeThatFits:` on the text view's current width). Typing within a
  line then costs one height query and no table relayout; adding or removing a line still resizes the row.
- Wrap the resize in `[UIView performWithoutAnimation:]` to drop the animation pass.
- Optional, larger: make the code text view scrollable with a fixed-height cell above a threshold of
  lines (e.g. 200), so very long codes never force a full layout. Needs a design decision, so it is out
  of scope for the minimal fix.

This is a UIKit-only change, no core or cheat-data change, testable with the repro in 3.3.

---

## 4. What this report did not do

- No Sentry queries (refused in this session); counts and stacks are quoted from #69 and #76.
- No builds, captures or device runs.
- No product edits. The local proposal branch named in the header is unpushed and waits for the owner.
