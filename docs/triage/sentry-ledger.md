# Sentry triage ledger

What is already known about each Sentry issue in the `icube` project. The weekly triage routine
reads this file before it writes anything, so that a cause someone has verified is not guessed at
again and a known issue is not reported as a new finding every Monday.

Whoever handles a triage report updates this file in the same change as the fix (or the decision
not to fix). A row needs evidence: a commit, a symbolicated frame, or the build an event came from.
A hypothesis that nobody has checked does not belong here.

Last reviewed: 2026-11-24.

## Reading a build

An event's `release` is `<bundle id>@<version>+<dist>`. The `dist` says which build it is.

| `dist` | Build | Date |
|---|---|---|
| A 10-digit number (`1795417420`) | TestFlight / App Store. The number is the Unix time of the build. | `date -u -r <dist>` |
| A small number from `build.yml` (`549`) | Sideload build of `develop`; the number is the workflow run number. | `gh run list --workflow build.yml` |
| `13` | The public `release.yml` build of 2026-09-13. Older than every fix in this file and built without core debug info. It is still installed widely and is the build most repackagers ship. | 2026-09-13 |

Rules that follow from this:

- **An event proves a regression only if its build is at or after the "fixed in" build of the row.**
  For a `MetricKit crash` event the crashed build is the `crash.build` tag; `dist` there is the
  build that delivered the report a day later.
- **Bundle ids.** `com.joemattiello.iCube` is TestFlight, the App Store and the plain sideload
  IPA. `com.joemattiello.iCube-ts` is TrollStore. `com.joemattiello.iCube.<10 characters>` is the
  same IPA re-signed by AltStore or SideStore. Anything else (`com.kdt.livecontainer.*`,
  `com.sonicheroes.appletv`, `local.shirahane.*`, `dev.daveroberts.iCube` and so on) is somebody
  else's repackage or a container host: count its users in one line and do not rank a finding on it.
- **The name in `MetricKit crash: ... in <name>`** is the innermost frame in the app's own code
  (`MetricKitCrashReport.culprit`: a binary whose name starts with `iCube`, `PV` or `Skin`), else
  the innermost frame of any binary. So `in PVlibDolphin-ios` or `in SkinKit` is ours and gets a
  full look, and `in unknown` only means the frames could not be parsed. Set a crash aside as a
  container host's only when it is positively one: the `crash.binary` is a known host (`SideStore`,
  `LiveContainer`) or the `crash.build` is not an iCube build number (`3.8.11` is LiveContainer's
  version). Check `crash.build` on each event, not on the issue: one issue can hold both.

## Dispositions

`fixed`: a fix is merged; report again only from a build at or after "fixed in".
`expected`: the event is working as designed; one line with a count.
`not ours`: caused outside the app's code; one line with a count.
`tracked`: a real open problem with a GitHub issue; report a change in numbers, not the analysis.
`watching`: too little evidence to act on; report only when the listed condition is met.

### Fixed

| Issues | Cause, as verified | Fix | Fixed in |
|---|---|---|---|
| ICUBE-NV `Painter.drawSingle` (MXCPUException) | SkinKit re-rendered the full skin on the main thread during touch changes and press animations. | SkinKit 0.9.0 caches the resting skin and repaints affected regions ([SkinKit #169](https://github.com/Provenance-Emu/SkinKit/pull/169), adopted in [iCube #148](https://github.com/Provenance-Emu/iCube/pull/148)). | sideload 631. For TestFlight, verify the build contains `dc1063726d` before treating recurrence as a regression. |
| ICUBE-Q4, Q5, Q0 | Launch watchdog kill (`0x8BADF00D`, scene-create). Symbolicated with `atos`: `PVWebServer.init(configuration:)` called `ProcessInfo.hostName` on the main thread, which can block on DNS for the whole launch allowance. It is **not** the background resume save of `c6ea204a59`. | PVWebServer 1.3.3 (PVWebServer PR 10), pinned by `6645414db8` | sideload 549, TestFlight 1795417420 |
| ICUBE-BF, 2Y, PT, B1, GV, N7, P1, CZ, D7, 9W, NH, MK, MP | The 2026-11-19 crash sweep: FIFO and shader asserts on guest data, shader and DSU races, Wii Remote null, Apple TV HD launch, Skylander "Clear All". | `471f5ae425` | sideload 539, TestFlight 1795149298 |
| ICUBE-AW | `Interpreter::unknown_instruction` trapped the app when a game ran an invalid opcode. It now raises a guest program exception. | `3f6040f888` | sideload 452, TestFlight 1793831631 |
| ICUBE-KJ, KK, HY, GY, J5 | `CKContainer` raised on a re-signed install whose iCloud entitlement is a wildcard. CloudKit is now probed before a container is built. | `080df117d4`, `cb7d1d0c12` (PR 73) | sideload 416, TestFlight 1793493165 |
| ICUBE-G, FJ | Crash while the process was exiting (`willTerminate` and the `SIGTERM` path): core teardown raced threads still using Config and logging. | `7c6663a6e0`, `9e56197285` | sideload 336, TestFlight 1792039866 |
| ICUBE-FS | `Config::Layer::Set` crash at launch: the audio effects migration ran before the Config layers existed. | `a39f62a8a8` | sideload 327, TestFlight 1791925912 |

A sideload "fixed in" is the first `build.yml` run on `develop` that contains the commit. A
TestFlight "fixed in" is the commit's Unix time: any TestFlight build numbered above it has the fix.

### Expected

| Issues | What it is |
|---|---|
| ICUBE-BM "Previous TXM JIT handshake never returned" | Sent on purpose by `SentryTelemetryService.reportStuckTXMHandshakeIfNeeded` when the previous launch died inside the TXM JIT handshake. Sideload only. |
| ICUBE-6S, events whose last breadcrumb is `[jit] TXM handshake begin` | The other half of ICUBE-BM: the handshake's `brk` with a debugger attached that is not a JIT broker. The process dies once, the cookie stops the next launch from trying again (`EmulationCoordinator.mm`, "Persist a crash cookie first"). Sideload only, `jit:pending`. Older ICUBE-6S events are a core assert dialog answered "No"; read the `dolphin.msgalert` breadcrumbs. |
| MXCPUException / MXDiskWriteException in interpreter, video, hashing or import frames | Normal load for an emulator with no JIT. See the routine's prompt. |

### Not ours

| Issues | Why |
|---|---|
| ICUBE-QJ | SideStore's own process crashing (`crash.binary` SideStore, `crash.build` 3.8.0), reported through iCube's MetricKit payload. |
| ICUBE-P4 `-[UIWindow avDisplayManager]` | Every event is `com.sonicheroes.appletv` build 13, a third-party repackage for Apple TV. |
| ICUBE-2H, latest event 2026-11-21 | The main thread was inside the system's accessibility bundle load (`AXSpringBoardUIServicesGlue`) at launch. ICUBE-2H groups unrelated hangs by duration; read each event's own stack before blaming app code. |

### Tracked

| Issues | Tracker | Standing facts |
|---|---|---|
| ICUBE-3 WatchdogTermination | #56 | A Sentry heuristic (the app ended in the foreground with no crash and no clean exit), not a measured memory kill. It has no stack. An earlier pass found most events were JIT or debugger kills on sideload installs, with real memory kills on devices with 4 GB or less. Do not repeat Seer's Fastmem and texture-cache hypothesis. The `MetricKit app exits` events are the measured counts: quote those. |
| ICUBE-2D, 6H and other main-thread hangs | #45 | See below for single-sample hangs. |
| ICUBE-AA, 60 legacy-JIT write fault | #46 | Sideload legacy JIT only. Recent ICUBE-60 events are build 13. |

### Watching

| Issues | Evidence so far | Report again when |
|---|---|---|
| ICUBE-QD `MetricKit crash: SIGKILL / EXC_CRASH in unknown` | Four events whose frames did not parse. Three are iCube builds 546 and 1795200341, both older than the ICUBE-Q4 launch-watchdog fix and first seen the same day, so probably that kill; unproven without frames. The fourth has `crash.build` 3.8.11, a LiveContainer host. | An event whose `crash.build` is sideload 549 or later, or TestFlight 1795417420 or later. |
| ICUBE-R9 hang, `PlayerScreenModelBuilder.buttonSections` | One event, iPad on iOS 17.2. The frame is a single `String(format:)`; `PlayerScreenView.body` rebuilds the whole menu model on every state change, which is the suspect, unproven. | A second user, or an event with a different top frame under the same `body`. |
| ICUBE-R5 hang, `EmulationScreen.body` | One event, seconds after a cold launch of TestFlight 1794551144, a build that still had the ICUBE-Q4 launch block. Probably the same block seen by the hang detector. | An event from TestFlight 1795417420 or later. |
| ICUBE-MC `ServiceManager.applicationWillTerminate` | Two events in three weeks, both TrollStore with legacy JIT, both while the app was being terminated: `objc_msgSend` jumped to a garbage address during a `respondsToSelector:` check. The user saw nothing. | An event from a build that is not TrollStore, or more than five users. |
| ICUBE-PG, P8, MT, MR, M5, K8 single-user hangs | One event each, none repeated since. ICUBE-M5 was investigated in #69 without a reproduction. | Any of them gains a second user. |
| ICUBE-CB, J2 SwiftUI abort on iOS 17 and 18 | No event since 2026-10-22. | Any new event. |
| ICUBE-G1 `ValueStepper` "max stride must be positive" | No event since 2026-10-19. | Any new event. |

## Symbolicating a `MetricKit crash`

Its frames are `binary +0xoffset`. Do not infer a cause from them or from what merged the same
week: ICUBE-Q4 was blamed on the wrong commit that way. On a Mac:

```bash
sentry api "/projects/provenance-emu/icube/files/dsyms/?debug_id=<uuid>"
sentry api "/projects/provenance-emu/icube/files/dsyms/?id=<file id>" > iCube.dwarf
xcrun atos -arch arm64 -o iCube.dwarf -l 0x100000000 <0x100000000 + offset>
```

The weekly routine runs on Linux and cannot do this. It reports the offsets and the debug id and
says that the issue needs symbolicating.
