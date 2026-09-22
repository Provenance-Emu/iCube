# Reaching the on-device debug bench

A runbook for "the MCP/debug API won't answer". Written 2026-09-22 after a long
session where every layer got blamed except the one that was wrong.

## The connection path, and what each layer can break

```
Mac curl/MCP → 127.0.0.1:8723 → iproxy → usbmuxd → USB → device → app's NWListener
```

The server is **loopback-only by design** (`NativeWebServer.swift:12-13`): it binds
`127.0.0.1` via `requiredLocalEndpoint` *and* rejects any connection whose remote
endpoint is not loopback. **A LAN IP address will never work.** USB is the only route.

## Diagnose in this order

Each step distinguishes a different failure. Do not skip ahead.

### 1. Is the server actually up? Read the app's own log line.

This is the single most informative check and it was left until last, which cost
hours. Run from Xcode (or Console.app) and filter `DebugServer`:

```
[DebugServer] listening on http://127.0.0.1:8723/ (loopback only; iproxy to reach over USB)
[DebugServer] failed to start: <reason>
```

* **Neither line** → `isEnabled` was false at launch. See §2.
* **"failed to start"** → the reason is the whole answer; stop here.
* **"listening"** → the app is fine. The problem is below it, §3 onward.

`idevicesyslog` returned *zero* lines on iOS 26 in this session — don't rely on it.

### 2. Is the bench enabled for this build?

```swift
private var isEnabled: Bool {
  #if DEBUG
  return true
  #else
  return UserDefaults.standard.bool(forKey: "ICubeBenchServerEnabled")
  #endif
}
```

* **Debug configs** (`Debug (Non-Jailbroken)` → `com.joemattiello.iCube-debug`): always on.
* **Every Release config**: needs Settings → Debug → **Perf Test Bench (HTTP)**,
  and it is read at **scene connect and game boot** — its caption says "takes
  effect at the next game boot" for that reason. Toggling it mid-game does nothing
  until you reboot the title or force-quit and relaunch.
* A **delete-and-reinstall** wipes the data container and with it the toggle. An
  Xcode *replace* normally preserves it. If the switch looks on but the server
  never starts, check it in this install rather than assuming.

### 3. Which device are you actually tunnelling to?

`Release (AppStore)`, `Release (Non-Jailbroken)` and `Debug (AppStore)` **all
produce bundle id `com.joemattiello.iCube`**, so the bundle id does not tell you
which config is installed, and a process listing does not tell you which device
Xcode deployed to. With several devices attached, `iproxy` with no `-u` picks one
for you.

```bash
xcrun devicectl list devices | grep -v simulated          # UDIDs, and which are 'connected'
xcrun devicectl device info processes --device <UDID> | grep -i icube
```

An `iCube.app/iCube` line means the app is running on *that* device.

### 4. Start the tunnel, pinned

```bash
iproxy 8723 8723 -u <UDID>
curl -s http://127.0.0.1:8723/api/health
```

Read `iproxy`'s own stderr — it is explicit and people ignore it:

| Symptom | Means |
| --- | --- |
| `Error connecting to device: Connection refused` | usbmux reached the device; **nothing is accepting on 8723 there**. Go back to §1. |
| curl exit **56** (reset by peer), no iproxy error | The tunnel is up but the device closed the connection. Stale tunnel across a reinstall — kill and restart `iproxy`. |
| curl exit **7** / connection refused locally | `iproxy` is not running or not bound to that local port. |
| Empty body, exit 0 | The socket answered but the app returned nothing — usually a crashed request handler, not a transport problem. |

**Always restart `iproxy` after an app reinstall.** The container UUID changes and
the old tunnel goes stale; this produced exit 56 repeatedly in this session.

## Things that wasted time here, recorded so they don't again

* **Giving a LAN IP.** Loopback-only, by design. See the top.
* **Blaming the EINVAL bind bug.** Real, but already fixed: passing the port via
  *both* `requiredLocalEndpoint` and `NWListener(using:on:)` makes Network.framework
  reject the listener with NWError 22 on iOS 26 (`NativeWebServer.swift:124-127`).
  The upload server uses `NWListener(using:on:)` **without** `requiredLocalEndpoint`,
  so it is not affected. Neither server has this bug today.
* **Assuming a suspended app held the port.** It can (see the memory note), but
  check first: `devicectl device info processes` shows one line per running iCube.
* **Profiling the wrong configuration.** `Release (AppStore)` can *never* use JIT
  (no `get-task-allow`, TXM hard-off). Measuring a CPU-bound title there measures
  the Cached Interpreter by construction. `Release (Non-Jailbroken)` has the same
  bundle id, is equally non-debug, and can take a JIT broker.

## Once it answers

```bash
curl -s http://127.0.0.1:8723/api/health        # fps, vps, game_id, thermal, config
curl -s http://127.0.0.1:8723/api/settings      # the key list the bench can sweep
```

`fps` and `vps` are different questions and the distinction matters: **`vps` is
throttle-relative speed** (what the UI's "100%" tracks), **`fps` is what the game
actually renders**. `vps 60 / fps 25` means emulation is keeping up while the
*game* starves — usually an underclocked emulated CPU. See
`PerformanceMetrics.cpp`'s `CPU:nn%` overlay line and the adaptive-clock notes in
`EmulationCoordinator.mm`.

To find where guest CPU time goes:

```bash
# cirProfile is boot-time: set it, then reboot the title (counters reset at boot too).
curl -s -X POST http://127.0.0.1:8723/api/settings/cirProfile -d '{"value":true}'
curl -s "http://127.0.0.1:8723/api/debug/hot-blocks?top=40"
```
