# JIT & Performance (iOS 26)

## What JIT does

iCube emulates a GameCube/Wii PowerPC CPU. The fastest way to do that is a
**JIT (Just-In-Time) recompiler**, which translates PowerPC code into native
ARM64 instructions on the fly. Without JIT, iCube falls back to a **Cached
Interpreter** — still fully playable, but noticeably slower on demanding games.

## Why iOS 26 needs a debugger

Starting with iOS 26, Apple's **Trusted Execution Monitor (TXM)** will not
execute a freshly written code page until a debugger has written to that page
at least once. iCube works around this by asking an attached debugger
("broker") to touch every page of its JIT code region — about 288 MB — once
at startup. After that one-time pass, the broker can detach and the region
stays usable for the rest of the process's life. This is a one-time cost per
launch, not a permanent tether: iCube does not need to stay attached to a
debugger while you play.

You do **not** need a jailbreak for this. Any of the brokers below work on a
stock, non-jailbroken device.

## Turning JIT on

You need one of the following attached the first time iCube launches after
being installed or updated:

* **StikDebug** (recommended for most users) — a free, App Store–adjacent
  sideloading tool that can also act as a JIT broker. In iCube, go to
  **Settings → Debug → Environment** and tap **"Enable JIT via StikDebug"**.
  iCube hands StikDebug its bundled broker script and StikDebug relaunches
  the app; reopen a game afterward to run with JIT.
* **Xcode** — build and run iCube from Xcode with a device attached. Xcode's
  LLDB automatically installs the JIT bless hook the first time it launches
  the app, no extra setup required.
* **Command-line `lldb`** — same mechanism as Xcode, useful for CI or
  scripted testing.

If none of these are attached at boot, iCube automatically falls back to the
Cached Interpreter. It never *requires* JIT to run — you'll just get lower
performance in CPU-bound games.

## Checking status

**Settings → Debug → Environment** shows live status:

| Row | Meaning |
| --- | --- |
| JIT | Whether the runtime acquired a JIT entitlement this launch |
| Debugger | Whether a debugger is currently attached |
| TXM JIT Region | (iOS 26+ devices only) Whether the JIT code region has been authorized |
| JIT Error | The last JIT-related error, if any |
| Fastmem | Whether fast memory access is available (improves performance further) |

## Troubleshooting StikDebug

If StikDebug doesn't attach after tapping "Enable JIT via StikDebug", try
these three checks — they resolve most failures:

1. In StikDebug, run **"Reset Developer Disk Image"**.
2. Confirm StikDebug's VPN is connected (it uses a local VPN to talk to the
   device).
3. Re-import your pairing file if it was removed or expired.

On a Mac, Xcode or `lldb` works as an alternative broker with none of the
above steps.

### "Retry JIT Authorization" button

If a previous attempt to authorize the JIT region never finished — for
example, the app was killed mid-handshake — iCube deliberately won't retry
on its own, to avoid repeating a crash. A **"Retry JIT Authorization"**
button appears in Settings when this happens; tapping it re-arms JIT for the
next time you open a game with a debugger attached.

## App Store note

TestFlight and App Store builds of iCube can never use JIT — Apple does not
grant the `get-task-allow` entitlement to App Store builds, and TXM is
hard-disabled for them regardless. If you want JIT, install iCube via
sideloading (StikDebug, Xcode, or a similar tool) rather than through
TestFlight or the App Store.
