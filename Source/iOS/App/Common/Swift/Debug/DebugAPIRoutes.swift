// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
// TARGET PATH (when integrated):
//   Source/iOS/App/Common/Swift/Debug/DebugAPIRoutes.swift
//
// Registers the debug + benchmark JSON API on a NativeWebServer.
// Every response is { "ok": Bool, "data": ... } or { "ok": false, "error": ... }.
//
// Routes:
//   GET  /api/perf/live              -> live g_perf_metrics snapshot
//   GET  /api/settings[?keys=a,b]    -> all known settings + metadata, or just those keys
//   POST /api/settings/<key>         body {"value": ...} -> set one setting
//   POST /api/settings/bulk          body {"values":{k:v,...},"mode":"merge|replace","atomic":true}
//                                    -> set many at once; replace resets all keys first
//   POST /api/settings/snapshots/<name>/apply  body {"mode":"merge|replace"} -> restore a snapshot
//   GET  /api/savestates             -> list save-state slots present on disk
//   POST /api/bench/start            body {"slot":N,"seconds":S} -> start a run
//   GET  /api/bench/result           -> last finished benchmark result
//   POST /api/bench/sweep            body {"key":K,"values":[...],"slot":N,"seconds":S}
//   GET  /api/bench/sweep/result     -> last finished sweep (per-value results), or running status
//   GET  /api/health                 -> build/game/core-state/perf summary
//   POST /api/debug/boot             body {"gameID":"GZLE01"} -> boot a library title (library must be on screen)
//   POST /api/debug/stop             -> quit the running game back to the library (server stays up)
//   POST /api/debug/pause            -> pause the running core
//   POST /api/debug/resume           -> resume the paused core
//   POST /api/debug/frame-advance    body {"n":N} (required, 1...600) -> step N frames while paused
//   GET  /api/debug/frame-count      -> emulated frame counter
//   POST /api/debug/savestate        body {"slot":N=1} -> save to slot N
//   POST /api/debug/loadstate        body {"slot":N} or {"path":P}, one required -> load a state
//   GET  /api/debug/screenshot       -> current frame as image/png bytes
//   GET  /api/debug/build-info       -> SCM rev/branch/app version/configuration
//   GET  /api/debug/render-state     -> render-relevant config/state snapshot
//   GET  /api/logs                   -> query {"tail":N=200} -> last N log lines
//   GET  /api/debug/mem              -> query {"addr":"0x..","len":N=64} -> raw guest RAM as hex
//   GET  /api/debug/memarena         -> arena mode + alias matrix of the real RAM views
//
// frame-advance/savestate/loadstate bodies are parsed by `parseBody` below: a
// non-JSON-object body (including a missing one) returns nil, which callers
// turn into a 400. Other routes' bodies are parsed inline and predate this
// convention.

import Foundation

/// The error message every `parseBody` caller returns (as a 400) when the
/// request body is missing, empty, or not a JSON object.
private let bodyMustBeJSONObjectError = "body must be a JSON object"
/// iCube: true when a title is loaded, which makes settings writes VOLATILE.
///
/// `Config::SetBaseOrCurrent` (Config.h:131) writes the **CurrentRun** layer whenever a key's active
/// layer is not Base, and CurrentRun is discarded when the run ends. EmulationCoordinator puts a
/// CurrentRun override on MAIN_CPU_CORE at boot (the JIT-availability fallback), so while a game is
/// loaded a write to that key lands in CurrentRun, reads back correctly, and then silently reverts to
/// whatever Base holds the moment the title stops.
///
/// That is how a settings restore put the device on the ARM64 JIT while reporting success: the
/// snapshot had recorded the resolved value 5 (from CurrentRun), the apply wrote CurrentRun again, and
/// stopping the game dropped it back to Base's 4. For a benchmark harness a write that does not
/// survive the next boot is worse than a failed write, because it looks like it worked.
private func aGameIsLoaded() -> Bool {
  let state = Thread.isMainThread
    ? DOLDebugBridge.coreState()
    : DispatchQueue.main.sync { DOLDebugBridge.coreState() }
  return state != "uninitialized" && state != "unknown"
}

/// Keys whose ACTIVE layer is not Base after a write — i.e. whose new value will not survive the run.
private func volatileKeys(_ keys: [String]) -> [String] {
  let layers = DOLSettingsKeyBridge.snapshotAllLayers()
  return keys.filter { k in
    guard let e = layers[k], let l = e["layer"] as? String else { return false }
    return l != "Base"
  }.sorted()
}

/// Settings captured by the first POST /api/bench/preset benchmarkBase, for "restore". Server queue only.
nonisolated(unsafe) private var presetRestoreSnapshot: PerfSnapshot?

/// Parses a request body as a JSON object, or nil for a missing, empty, or
/// non-object body — callers should turn a nil into a 400 with
/// `bodyMustBeJSONObjectError`.
private func parseBody(_ body: Data?) -> [String: Any]? {
  guard let body, !body.isEmpty,
        let obj = try? JSONSerialization.jsonObject(with: body),
        let dict = obj as? [String: Any] else {
    return nil
  }
  return dict
}

/// Parses a request body as a JSON object, returning an empty dict for a
/// missing or empty body, nil for a present-but-non-object body, or the dict
/// for a valid JSON object. Used by routes that want to support optional
/// bodies with sensible defaults.
private func parseOptionalBody(_ body: Data?) -> [String: Any]? {
  guard let body, !body.isEmpty else {
    return [:]
  }
  guard let obj = try? JSONSerialization.jsonObject(with: body),
        let dict = obj as? [String: Any] else {
    return nil
  }
  return dict
}

/// Returns `value` as an `Int` only if it is a JSON number encoding a whole
/// number. Rejects JSON booleans (Foundation bridges `true`/`false` to
/// `NSNumber`, which would otherwise pass an `as? NSNumber` check) and
/// non-integral numbers like `1.5`.
private func asJSONInt(_ value: Any?) -> Int? {
  guard let num = value as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID() else { return nil }
  guard num.doubleValue == num.doubleValue.rounded() else { return nil }
  return num.intValue
}

final class DebugAPIRoutes {
  private var registered = false
  private let snapshots = SettingsSnapshots(directory: SettingsSnapshots.defaultDirectory)

  func registerRoutes(on server: NativeWebServer) {
    guard !registered else { return }

    // GET /api/perf/live — perf getters are any-thread-safe, no MainActor hop.
    server.addCustomHandler(forMethod: "GET", path: "/api/perf/live") { _, _, _, _ in
      var snap = DOLPerfBridge.snapshot() as [String: Any]
      snap["thermal_state"] = DebugBenchmarkManager.thermalStateName()
      return ["ok": true, "data": snap]
    }

    // GET /api/settings[?keys=a,b,c]
    // Without `keys`, every known setting. With it, just those — so a caller checking a handful of
    // flags between benchmark legs does not have to pull and parse the whole table. Unknown names are
    // reported in `unknown` rather than failing the read: a probe of a mixed list still returns what
    // exists, which is what you want when checking whether a build even HAS a key yet.
    server.addCustomHandler(forMethod: "GET", path: "/api/settings") { _, _, query, _ in
      // snapshotAll reads Config (internally synchronized) — safe off-main.
      let all = DOLSettingsKeyBridge.snapshotAll()
      guard let raw = query?["keys"], !raw.isEmpty else {
        return ["ok": true, "data": all]
      }
      let wanted = raw.split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespaces)
      }.filter { !$0.isEmpty }
      var picked: [String: Any] = [:]
      var unknown: [String] = []
      for k in wanted {
        if let v = all[k] { picked[k] = v } else { unknown.append(k) }
      }
      var out: [String: Any] = ["ok": true, "data": picked]
      if !unknown.isEmpty { out["unknown"] = unknown }
      return out
    }

    // POST /api/settings/bulk
    //   body {"values": {"<key>": <value>, ...},
    //         "mode": "merge" | "replace",   // default merge; replace resets ALL keys first
    //         "atomic": true }               // default true: validate everything, apply nothing on error
    //
    // Why this exists: setting N keys meant N round-trips, each independently able to fail, with no way
    // to know the device ended up in the state you asked for. That is fine interactively and wrong for
    // benchmarking — a leg that starts from a half-applied config produces a number that looks valid.
    // `replace` is the strong form: reset every known key to its default, then apply this map, so the
    // resulting state is a function of the request alone and not of whatever was toggled beforehand.
    //
    // `atomic` validates names and value types up front. Type checking matters because setKey coerces:
    // sending a string to an int key can silently land a 0 rather than erroring.
    //
    // The response separates what changed live from what did not: `requiresReboot` lists the applied
    // keys that are boot-time, which is the single easiest thing to forget with the CIR flags.
    server.addCustomHandler(forMethod: "POST", path: "/api/settings/bulk") { _, _, _, body in
      guard let dict = parseBody(body) else {
        return ["ok": false, "status": 400, "error": bodyMustBeJSONObjectError]
      }
      guard let values = dict["values"] as? [String: Any] else {
        return ["ok": false, "status": 400, "error": "missing object 'values' of key -> value"]
      }
      let mode = (dict["mode"] as? String) ?? "merge"
      guard mode == "merge" || mode == "replace" else {
        return ["ok": false, "status": 400, "error": "mode must be \"merge\" or \"replace\""]
      }
      let atomic = (dict["atomic"] as? Bool) ?? true
      // Durability guard. Default ON for `replace` (a full-config write is only meaningful if it
      // sticks) and OFF for `merge` (tweaking a hot-swappable value mid-run is a legitimate thing to
      // do). See aGameIsLoaded() for why a write during a run can silently evaporate.
      let requireDurable = (dict["requireDurable"] as? Bool) ?? (mode == "replace")
      if requireDurable && aGameIsLoaded() {
        return ["ok": false, "status": 409,
                "error": "a title is loaded, so writes land in the volatile CurrentRun layer and are "
                       + "lost when it stops; POST /api/debug/stop first, or pass "
                       + "{\"requireDurable\": false} to write anyway"]
      }

      // Validate first: unknown names, and values whose JSON type cannot represent the setting.
      let meta = DOLSettingsKeyBridge.snapshotAll()
      var errors: [String: String] = [:]
      for (k, v) in values {
        guard let m = meta[k], let type = m["type"] as? String else {
          errors[k] = "unknown key"
          continue
        }
        let num = v as? NSNumber
        let isBoolLiteral = num != nil && CFGetTypeID(num!) == CFBooleanGetTypeID()
        switch type {
        case "bool":
          if !isBoolLiteral && num == nil { errors[k] = "expected bool" }
        case "int":
          if isBoolLiteral || num == nil || num!.doubleValue != num!.doubleValue.rounded() {
            errors[k] = "expected integer"
          }
        case "float":
          if isBoolLiteral || num == nil { errors[k] = "expected number" }
        default:
          if !(v is String) { errors[k] = "expected string" }
        }
      }
      if atomic && !errors.isEmpty {
        return ["ok": false, "status": 400,
                "error": "nothing applied (atomic); \(errors.count) invalid entr\(errors.count == 1 ? "y" : "ies")",
                "data": ["errors": errors, "applied": 0] as [String: Any]]
      }

      // Apply. One hop to main for the whole batch rather than per key.
      let applyList = values.filter { errors[$0.key] == nil }
      let outcome: (results: [String: Any], applied: Int, reboot: [String]) = DispatchQueue.main.sync {
        if mode == "replace" {
          _ = DOLSettingsKeyBridge.resetKeys([])  // empty == all known keys
        }
        var results: [String: Any] = [:]
        var applied = 0
        var reboot: [String] = []
        for (k, v) in applyList {
          let ok = DOLSettingsKeyBridge.setKey(k, value: v)
          let hot = DOLSettingsKeyBridge.isHotSwappable(k)
          if ok {
            applied += 1
            if !hot { reboot.append(k) }
          }
          results[k] = ["ok": ok, "hotSwappable": hot, "value": "\(v)"] as [String: Any]
        }
        return (results, applied, reboot.sorted())
      }
      var data: [String: Any] = [
        "mode": mode,
        "applied": outcome.applied,
        "failed": applyList.count - outcome.applied + errors.count,
        "results": outcome.results,
        "requiresReboot": outcome.reboot,
      ]
      if !errors.isEmpty { data["errors"] = errors }
      let vol = volatileKeys(Array(applyList.keys))
      if !vol.isEmpty {
        data["volatile"] = vol
        data["volatileNote"] = "these landed in a non-Base layer and will revert when the title stops"
      }
      if !outcome.reboot.isEmpty {
        data["note"] = "boot-time keys changed; reload a save state or reboot the title for them to take effect"
      }
      return ["ok": errors.isEmpty, "data": data]
    }

    // GET /api/settings/all — same data as GET /api/settings, but with per-layer
    // (Base/PerGame/CurrentRun) breakdown instead of just the resolved value.
    server.addCustomHandler(forMethod: "GET", path: "/api/settings/all") { _, _, _, _ in
      ["ok": true, "data": DOLSettingsKeyBridge.snapshotAllLayers()]
    }

    // GET /api/settings/pergame — just the PerGame (Local GameINI) layer's overrides,
    // one entry per key that actually HAS a per-game override (others are omitted).
    server.addCustomHandler(forMethod: "GET", path: "/api/settings/pergame") { _, _, _, _ in
      let all = DOLSettingsKeyBridge.snapshotAllLayers()
      let pergame = all.compactMapValues { ($0["layers"] as? [String: Any])?["PerGame"] }
      return ["ok": true, "data": pergame]
    }

    // POST /api/settings/reset  body {"keys":[...]}, optional — a missing/empty body or
    // empty "keys" array resets ALL known keys. Registered before the POST
    // /api/settings/.* regex below so it isn't shadowed by it (routing is first-match).
    server.addCustomHandler(forMethod: "POST", path: "/api/settings/reset") { _, _, _, body in
      guard let dict = parseOptionalBody(body) else {
        return ["ok": false, "status": 400, "error": bodyMustBeJSONObjectError]
      }
      let keys = dict["keys"] as? [String] ?? []
      let ok = DispatchQueue.main.sync { DOLSettingsKeyBridge.resetKeys(keys) }
      return ok ? ["ok": true, "data": ["reset": keys.isEmpty ? "all" : keys] as [String: Any]]
                : ["ok": false, "status": 404, "error": "unknown key in list"]
    }

    // GET /api/settings/snapshots — list saved snapshots (name/taken_at/game_id only).
    server.addCustomHandler(forMethod: "GET", path: "/api/settings/snapshots") { [snapshots] _, _, _, _ in
      ["ok": true, "data": snapshots.list()]
    }

    // POST /api/settings/snapshots  body {"name": "..."} — snapshot every known key's
    // current per-layer state under `name`. Registered before POST /api/settings/.* so
    // it isn't shadowed by it.
    server.addCustomHandler(forMethod: "POST", path: "/api/settings/snapshots") { [snapshots] _, _, _, body in
      guard let dict = parseBody(body) else {
        return ["ok": false, "status": 400, "error": bodyMustBeJSONObjectError]
      }
      guard let name = dict["name"] as? String else {
        return ["ok": false, "status": 400, "error": "missing name"]
      }
      // TVEmulationBridge.currentGameID() reads an unlocked std::string — main-thread only
      // (see the same hop in GET /api/health below).
      let gameID: String = Thread.isMainThread
        ? TVEmulationBridge.currentGameID()
        : DispatchQueue.main.sync { TVEmulationBridge.currentGameID() }
      do {
        try snapshots.save(name: name, snapshot: DOLSettingsKeyBridge.snapshotAllLayers(), gameId: gameID)
        return ["ok": true, "data": ["name": SettingsSnapshots.sanitise(name)]]
      } catch {
        return ["ok": false, "status": 500, "error": "\(error)"]
      }
    }

    // POST /api/settings/snapshots/<name>/apply  body {"mode": "merge"|"replace"} (optional)
    // Restore a saved snapshot. Snapshots could be taken and diffed but never re-applied, which made
    // them a record rather than a tool: the useful move is "put the device back exactly how it was
    // before I started fiddling", and that needed replaying every key by hand.
    //
    // Default mode is `replace`, because that is what restoring a snapshot should mean — every known
    // key reset first, then the snapshot's values applied, so keys ADDED since the snapshot was taken
    // go back to their defaults instead of silently keeping whatever they happen to be now.
    //
    // Registered before the POST /api/settings/.* regex so it is not shadowed by it (first match wins).
    server.addCustomHandler(forMethod: "POST",
                            pathRegex: "/api/settings/snapshots/[^/]+/apply") { [snapshots] _, path, _, body in
      guard let dict = parseOptionalBody(body) else {
        return ["ok": false, "status": 400, "error": bodyMustBeJSONObjectError]
      }
      let mode = (dict["mode"] as? String) ?? "replace"
      guard mode == "merge" || mode == "replace" else {
        return ["ok": false, "status": 400, "error": "mode must be \"merge\" or \"replace\""]
      }
      // Restoring a snapshot must be durable or it is a lie — see aGameIsLoaded().
      if ((dict["requireDurable"] as? Bool) ?? true) && aGameIsLoaded() {
        return ["ok": false, "status": 409,
                "error": "a title is loaded, so restored values land in the volatile CurrentRun layer "
                       + "and revert when it stops (this is how a restore silently left the device on "
                       + "the wrong CPU core); POST /api/debug/stop first, or pass "
                       + "{\"requireDurable\": false}"]
      }
      let parts = path.split(separator: "/").map(String.init)  // api settings snapshots <name> apply
      guard parts.count == 5, let saved = snapshots.load(name: parts[3]) else {
        return ["ok": false, "status": 404, "error": "snapshot not found"]
      }
      // A snapshot stores per-layer state; the resolved `value` is what we replay.
      var values: [String: Any] = [:]
      for (k, entry) in saved {
        guard DOLSettingsKeyBridge.isKnownKey(k) else { continue }  // key retired since the snapshot
        if let e = entry as? [String: Any], let v = e["value"], !(v is NSNull) { values[k] = v }
      }
      let outcome: (applied: Int, failed: Int, reboot: [String]) = DispatchQueue.main.sync {
        if mode == "replace" { _ = DOLSettingsKeyBridge.resetKeys([]) }
        var applied = 0, failed = 0
        var reboot: [String] = []
        for (k, v) in values {
          if DOLSettingsKeyBridge.setKey(k, value: v) {
            applied += 1
            if !DOLSettingsKeyBridge.isHotSwappable(k) { reboot.append(k) }
          } else {
            failed += 1
          }
        }
        return (applied, failed, reboot.sorted())
      }
      var data: [String: Any] = ["snapshot": parts[3], "mode": mode, "applied": outcome.applied,
                                 "failed": outcome.failed, "skipped": saved.count - values.count,
                                 "requiresReboot": outcome.reboot]
      let vol = volatileKeys(Array(values.keys))
      if !vol.isEmpty {
        data["volatile"] = vol
        data["volatileNote"] = "these landed in a non-Base layer and will revert when the title stops"
      }
      return ["ok": outcome.failed == 0, "data": data]
    }

    // GET /api/settings/snapshots/<A>/diff/<B> — diff two saved snapshots by name.
    server.addCustomHandler(forMethod: "GET", pathRegex: "/api/settings/snapshots/[^/]+/diff/[^/]+") { [snapshots] _, path, _, _ in
      let parts = path.split(separator: "/").map(String.init)  // api settings snapshots A diff B
      guard parts.count == 6, let a = snapshots.load(name: parts[3]), let b = snapshots.load(name: parts[5]) else {
        return ["ok": false, "status": 404, "error": "snapshot not found"]
      }
      return ["ok": true, "data": SettingsSnapshots.diff(a, b)]
    }

    // POST /api/settings/<key>  body {"value": ...}
    server.addCustomHandler(forMethod: "POST", pathRegex: "/api/settings/.*") { _, path, _, body in
      let key = (path as NSString).lastPathComponent
      guard DOLSettingsKeyBridge.isKnownKey(key) else {
        return ["ok": false, "error": "unknown key: \(key)"]
      }
      guard let body,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let value = json["value"] else {
        return ["ok": false, "error": "missing JSON body with 'value' key"]
      }
      // Config writes must happen on the main actor.
      let ok: Bool = DispatchQueue.main.sync {
        DOLSettingsKeyBridge.setKey(key, value: value)
      }
      let hot = DOLSettingsKeyBridge.isHotSwappable(key)
      return [
        "ok": ok,
        "data": [
          "key": key,
          "value": "\(value)",
          "hotSwappable": hot,
          "note": hot ? "applied live" : "boot-time: reload save state / reboot to take effect",
        ] as [String: Any],
      ]
    }

    // GET /api/savestates — enumerate the StateSaves directory.
    server.addCustomHandler(forMethod: "GET", path: "/api/savestates") { _, _, _, _ in
      guard let cPath = DolphinGetStateSavesPathC() else {
        return ["ok": true, "data": [] as [Any]]
      }
      let dir = URL(fileURLWithPath: String(cString: cPath))
      let files = (try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
      let iso = ISO8601DateFormatter()
      // Dolphin slot states are "<game>.sNN" (Core/State.cpp MakeStateFilename:
      // fmt "{}.s{:02d}"); there is also a "lastState.sav". Match both and pull
      // the slot number out of the .sNN extension when present.
      let slotRegex = try? NSRegularExpression(pattern: "\\.s([0-9]{2})$")
      let list = files.compactMap { url -> [String: Any]? in
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        var slot: Int? = nil
        if let slotRegex {
          let range = NSRange(name.startIndex..., in: name)
          if let m = slotRegex.firstMatch(in: name, range: range),
             let r = Range(m.range(at: 1), in: name) {
            slot = Int(name[r])
          }
        }
        let isSlot = slot != nil
        let isLast = name == "lastState.sav"
        guard isSlot || (isLast && ext == "sav") else { return nil }
        let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var entry: [String: Any] = [
          "name": name,
          "size": rv?.fileSize ?? 0,
          "modified": (rv?.contentModificationDate).map { iso.string(from: $0) } ?? "",
        ]
        if let slot { entry["slot"] = slot }
        return entry
      }
      return ["ok": true, "data": list]
    }

    // POST /api/bench/start  body {"slot":N,"seconds":S}
    server.addCustomHandler(forMethod: "POST", path: "/api/bench/start") { _, _, _, body in
      var slot = 1
      var seconds: Double = 15
      if let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
        slot = (json["slot"] as? NSNumber)?.intValue ?? slot
        seconds = (json["seconds"] as? NSNumber)?.doubleValue ?? seconds
      }
      Task { @MainActor in
        await DebugBenchmarkManager.shared.runBenchmark(slot: slot, seconds: seconds)
      }
      return ["ok": true, "data": ["started": true, "slot": slot, "seconds": seconds] as [String: Any]]
    }

    // GET /api/bench/result — last finished run, or running status.
    server.addCustomHandler(forMethod: "GET", path: "/api/bench/result") { _, _, _, _ in
      // Hop to main to read manager state (it is @MainActor), then encode.
      let payload: [String: Any] = DispatchQueue.main.sync {
        MainActor.assumeIsolated {
          let mgr = DebugBenchmarkManager.shared
          if mgr.isRunning {
            return ["ok": true, "data": ["status": "running"] as [String: Any]]
          }
          guard let result = mgr.lastResult else {
            return ["ok": true, "data": ["status": "no-result"] as [String: Any]]
          }
          guard let dict = Self.encodeJSONObject(result) else {
            return ["ok": false, "error": "failed to encode result"]
          }
          return ["ok": true, "data": ["status": "done", "result": dict] as [String: Any]]
        }
      }
      return payload
    }

    // POST /api/bench/sweep  body {"key":K,"values":[...],"slot":N,"seconds":S}
    server.addCustomHandler(forMethod: "POST", path: "/api/bench/sweep") { _, _, _, body in
      guard let body,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let key = json["key"] as? String,
            let values = json["values"] as? [Any] else {
        return ["ok": false, "error": "missing key/values in body"]
      }
      guard DOLSettingsKeyBridge.isKnownKey(key) else {
        return ["ok": false, "error": "unknown key: \(key)"]
      }
      let slot = (json["slot"] as? NSNumber)?.intValue ?? 1
      let seconds = (json["seconds"] as? NSNumber)?.doubleValue ?? 15
      let stringValues = values.map { "\($0)" }
      Task { @MainActor in
        _ = await DebugBenchmarkManager.shared.runSweep(
          key: key, values: stringValues, slot: slot, seconds: seconds)
      }
      return ["ok": true, "data": [
        "started": true, "key": key, "values": stringValues, "slot": slot, "seconds": seconds,
      ] as [String: Any]]
    }

    // GET /api/bench/sweep/result — last finished sweep (or running status). A boot-time sweep
    // reboots the title once per value, so this can take minutes; poll this rather than
    // assuming POST /api/bench/sweep's immediate response describes the finished run.
    server.addCustomHandler(forMethod: "GET", path: "/api/bench/sweep/result") { _, _, _, _ in
      let payload: [String: Any] = DispatchQueue.main.sync {
        MainActor.assumeIsolated {
          let mgr = DebugBenchmarkManager.shared
          if mgr.isSweeping {
            return ["ok": true, "data": ["status": "running"] as [String: Any]]
          }
          guard let result = mgr.lastSweepResult else {
            return ["ok": true, "data": ["status": "no-result"] as [String: Any]]
          }
          guard let dict = Self.encodeJSONObject(result) else {
            return ["ok": false, "error": "failed to encode result"]
          }
          return ["ok": true, "data": ["status": "done", "result": dict] as [String: Any]]
        }
      }
      return payload
    }

    // GET /api/health — build/game/core-state/perf summary.
    server.addCustomHandler(forMethod: "GET", path: "/api/health") { _, _, _, _ in
      let perf = DOLPerfBridge.snapshot() as [String: Any]
      let build = DOLDebugBridge.buildInfo()
      // TVEmulationBridge.currentGameID() reads SConfig::GetGameID(), an
      // unlocked std::string — only safe to touch on the main thread (see
      // the same hop used by POST /api/settings/<key> below).
      let gameID: String = Thread.isMainThread
        ? TVEmulationBridge.currentGameID()
        : DispatchQueue.main.sync { TVEmulationBridge.currentGameID() }
      return ["ok": true, "data": [
        "build_sha": build["scm_rev"] ?? "", "config": build["configuration"] ?? "",
        "game_id": gameID, "core_state": DOLDebugBridge.coreState(),
        "fps": perf["fps"] ?? 0, "vps": perf["vps"] ?? 0,
        "thermal_state": DebugBenchmarkManager.thermalStateName(),
      ] as [String: Any]]
    }

    // POST /api/debug/pause
    server.addCustomHandler(forMethod: "POST", path: "/api/debug/pause") { _, _, _, _ in
      DOLDebugBridge.pause() ? ["ok": true, "data": ["state": DOLDebugBridge.coreState()]]
                             : ["ok": false, "status": 409, "error": "core not running"]
    }

    // POST /api/debug/resume
    server.addCustomHandler(forMethod: "POST", path: "/api/debug/resume") { _, _, _, _ in
      DOLDebugBridge.resume() ? ["ok": true, "data": ["state": DOLDebugBridge.coreState()]]
                              : ["ok": false, "status": 409, "error": "core not running"]
    }

    // POST /api/debug/frame-advance  body {"n":N}, n required, 1...600
    server.addCustomHandler(forMethod: "POST", path: "/api/debug/frame-advance") { _, _, _, body in
      guard let dict = parseBody(body) else {
        return ["ok": false, "status": 400, "error": bodyMustBeJSONObjectError]
      }
      guard let n = asJSONInt(dict["n"]), (1...600).contains(n) else {
        return ["ok": false, "status": 400, "error": "n must be an integer 1…600"]
      }
      guard DOLDebugBridge.coreState() == "paused" else {
        return ["ok": false, "status": 409, "error": "core must be paused (state=\(DOLDebugBridge.coreState()))"]
      }
      let done = DOLDebugBridge.frameAdvance(n, timeoutSeconds: 5)
      if done < n { return ["ok": false, "status": 504, "error": "timed out after \(done)/\(n) frames"] }
      return ["ok": true, "data": ["frames_advanced": done, "frame_count": DOLDebugBridge.frameCount()] as [String: Any]]
    }

    // GET /api/debug/frame-count
    server.addCustomHandler(forMethod: "GET", path: "/api/debug/frame-count") { _, _, _, _ in
      ["ok": true, "data": ["frame_count": DOLDebugBridge.frameCount()]]
    }

    // POST /api/debug/savestate  body {"slot":N}, slot optional (defaults to 1) but must be an Int if present
    server.addCustomHandler(forMethod: "POST", path: "/api/debug/savestate") { _, _, _, body in
      guard let dict = parseOptionalBody(body) else {
        return ["ok": false, "status": 400, "error": bodyMustBeJSONObjectError]
      }
      let slot: Int
      if let rawSlot = dict["slot"] {
        guard let parsedSlot = asJSONInt(rawSlot) else {
          return ["ok": false, "status": 400, "error": "slot must be an integer"]
        }
        slot = parsedSlot
      } else {
        slot = 1
      }
      return DOLDebugBridge.saveStateSlot(slot) ? ["ok": true, "data": ["slot": slot]]
                                                 : ["ok": false, "status": 409, "error": "core not running"]
    }

    // POST /api/bench/preset  body {"preset":"benchmarkBase"} -> adaptive clock OFF + 100 % CPU/VI clocks
    // (PerfAB.applyBenchmarkBase: the "honest benchmark" preset) so /api/perf/live `speed` measures
    // raw interpreter throughput; the pre-preset state is captured once. {"preset":"restore"} puts
    // it back. Boot-time: reboot the game after either call.
    server.addCustomHandler(forMethod: "POST", path: "/api/bench/preset") { _, _, _, body in
      guard let dict = parseBody(body), let preset = dict["preset"] as? String else {
        return ["ok": false, "status": 400, "error": "body must contain a string 'preset' (benchmarkBase|restore)"]
      }
      switch preset {
      case "benchmarkBase":
        DispatchQueue.main.sync {
          if presetRestoreSnapshot == nil { presetRestoreSnapshot = PerfAB.capture(name: "pre-benchmark") }
          PerfAB.applyBenchmarkBase()
        }
        return ["ok": true, "data": ["preset": preset, "applied": true] as [String: Any]]
      case "restore":
        guard let snap = presetRestoreSnapshot else {
          return ["ok": false, "status": 404, "error": "no pre-preset snapshot to restore"]
        }
        DispatchQueue.main.sync { PerfAB.apply(snap) }
        presetRestoreSnapshot = nil
        return ["ok": true, "data": ["preset": preset, "restored": true] as [String: Any]]
      default:
        return ["ok": false, "status": 400, "error": "unknown preset '\(preset)'"]
      }
    }

    // POST /api/debug/boot  body {"gameID":"GZLE01"} — boots a library title exactly like the
    // Spotlight deep link (DOLLaunchGameByGameID -> TVLibraryView.spotlightLaunchByGameID), so it
    // needs the library to be on screen: stop a running game first (POST /api/debug/stop). Lets a
    // Mac-side script run settings-A/B legs (set flag -> boot -> sample -> stop) with nobody at the
    // phone. Boot-time flags read at CachedInterpreter::Init apply to the new boot.
    server.addCustomHandler(forMethod: "POST", path: "/api/debug/boot") { _, _, _, body in
      guard let dict = parseBody(body) else {
        return ["ok": false, "status": 400, "error": bodyMustBeJSONObjectError]
      }
      guard let gameID = dict["gameID"] as? String, !gameID.isEmpty else {
        return ["ok": false, "status": 400, "error": "body must contain a string 'gameID'"]
      }
      let state = DOLDebugBridge.coreState()
      if state != "uninitialized" && state != "unknown" {
        return ["ok": false, "status": 409, "error": "a game is \(state); POST /api/debug/stop first"]
      }
      // "noJIT" (default true): answer the "Waiting for JIT" prompt with "Use No JIT Mode" so the
      // boot never blocks on a dialog nobody is there to tap.
      let noJIT = (dict["noJIT"] as? Bool) ?? true
      DispatchQueue.main.async {
        DebugServerManager.skipJITPromptOnce = noJIT
        NotificationCenter.default.post(name: NSNotification.Name("DOLLaunchGameByGameID"), object: nil,
                                        userInfo: ["gameID": gameID])
      }
      return ["ok": true, "data": ["gameID": gameID, "requested": true] as [String: Any]]
    }

    // POST /api/debug/stop — quit the running game and return to the library (the pause menu's
    // "Quit" path: TVEmulationBridge.stop + DOLEmulationRequestExitToLibrary). The server itself
    // stays up, so /api/debug/boot can follow. Poll GET /api/health until core_state leaves
    // running/stopping.
    server.addCustomHandler(forMethod: "POST", path: "/api/debug/stop") { _, _, _, _ in
      let state = DOLDebugBridge.coreState()
      DispatchQueue.main.async {
        TVEmulationBridge.stop()
        NotificationCenter.default.post(name: Notification.Name("DOLEmulationRequestExitToLibrary"), object: nil)
      }
      return ["ok": true, "data": ["was": state, "requested": true] as [String: Any]]
    }

    // POST /api/debug/loadstate  body {"slot":N} or {"path":P}; one of the two is required
    server.addCustomHandler(forMethod: "POST", path: "/api/debug/loadstate") { _, _, _, body in
      guard let dict = parseBody(body) else {
        return ["ok": false, "status": 400, "error": bodyMustBeJSONObjectError]
      }
      let ok: Bool
      if let path = dict["path"] as? String {
        ok = DOLDebugBridge.loadStatePath(path)
      } else if let slot = asJSONInt(dict["slot"]) {
        ok = DOLDebugBridge.loadStateSlot(slot)
      } else {
        return ["ok": false, "status": 400, "error": "body must contain an integer 'slot' or a string 'path'"]
      }
      return ok ? ["ok": true, "data": ["state": DOLDebugBridge.coreState()]]
                : ["ok": false, "status": 409, "error": "core not running or state missing"]
    }

    // POST /api/debug/fifo-record  body {"frames":N=1...600, default 1} -> start a Dolphin FIFO
    // recording; the .dff lands in Dump/Frames/<game>-<utc>.dff when done (poll the GET).
    server.addCustomHandler(forMethod: "POST", path: "/api/debug/fifo-record") { _, _, _, body in
      guard let dict = parseOptionalBody(body) else {
        return ["ok": false, "status": 400, "error": bodyMustBeJSONObjectError]
      }
      var frames = 1
      if let raw = dict["frames"] {
        guard let n = asJSONInt(raw), (1...600).contains(n) else {
          return ["ok": false, "status": 400, "error": "frames must be an integer 1...600"]
        }
        frames = n
      }
      guard let cPath = DolphinGetStateSavesPathC() else {
        return ["ok": false, "status": 500, "error": "user directory unavailable"]
      }
      // StateSaves is <user>/StateSaves; the FIFO logs go next to it in <user>/Dump/Frames.
      let user = URL(fileURLWithPath: String(cString: cPath)).deletingLastPathComponent()
      let dir = user.appendingPathComponent("Dump/Frames", isDirectory: true)
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
      let gameID: String = Thread.isMainThread
        ? TVEmulationBridge.currentGameID()
        : DispatchQueue.main.sync { TVEmulationBridge.currentGameID() }
      let game = gameID.isEmpty ? "game" : gameID
      let path = dir.appendingPathComponent("\(game)-\(stamp).dff").path
      guard DOLDebugBridge.fifoRecordStart(frames, path: path) else {
        return ["ok": false, "status": 409, "error": "core not running or a recording is in progress"]
      }
      return ["ok": true, "data": ["path": path, "frames": frames]]
    }

    // GET /api/debug/fifo-record -> {"state": idle|recording|saving|saved|save_failed, "path", ...}
    server.addCustomHandler(forMethod: "GET", path: "/api/debug/fifo-record") { _, _, _, _ in
      ["ok": true, "data": DOLDebugBridge.fifoRecordStatus()]
    }

    // GET /api/debug/fpu-selftest -> text/plain: interpreter FP primitives on fixed inputs, hex per line.
    server.addRawHandler(forMethod: "GET", path: "/api/debug/fpu-selftest") { _, _ in
      NativeWebServer.RawResponse(status: 200, contentType: "text/plain; charset=utf-8",
                                  body: Data(DOLDebugBridge.fpuSelfTest().utf8))
    }

    // GET /api/debug/gpfifo-selftest -> text/plain: the gather-pipe store oracle. Diffs the shipping
    // fused-copy byte kernel against a transcription of GPFifoManager::Write8 on a scratch pipe.
    server.addRawHandler(forMethod: "GET", path: "/api/debug/gpfifo-selftest") { _, _ in
      NativeWebServer.RawResponse(status: 200, contentType: "text/plain; charset=utf-8",
                                  body: Data(DOLDebugBridge.gatherPipeSelfTest().utf8))
    }

    // GET /api/debug/hot-blocks?top=N -> text/plain: the cached interpreter's top-N guest blocks by
    // emulated cycles (Main.Core.CIRProfile must be true at boot). Finds polling/idle loops.
    server.addRawHandler(forMethod: "GET", path: "/api/debug/hot-blocks") { request, _ in
      let top = Int(request.queryParameters["top"] ?? "") ?? 40
      return NativeWebServer.RawResponse(status: 200, contentType: "text/plain; charset=utf-8",
                                         body: Data(DOLDebugBridge.hotBlocksReport(top).utf8))
    }

    // GET /api/debug/screenshot — raw PNG bytes (not the JSON envelope).
    server.addRawHandler(forMethod: "GET", path: "/api/debug/screenshot") { _, _ in
      guard let png = DOLDebugBridge.screenshotPNG(withTimeout: 3) else {
        return .error("screenshot not produced within 3s (core running?)", status: 504)
      }
      return NativeWebServer.RawResponse(status: 200, contentType: "image/png", body: png)
    }

    // GET /api/debug/build-info
    server.addCustomHandler(forMethod: "GET", path: "/api/debug/build-info") { _, _, _, _ in
      ["ok": true, "data": DOLDebugBridge.buildInfo()]
    }

    // GET /api/debug/jit — JitManager state (fresh CS_DEBUGGED / P_TRACED read)
    server.addCustomHandler(forMethod: "GET", path: "/api/debug/jit") { _, _, _, _ in
      // Handlers run on the server queue; canOpenURL (StikDebug probe) is main-thread only.
      let data: [String: Any] = DispatchQueue.main.sync {
        let manager = JitManager.shared()
        manager.recheckIfJitIsAcquired()
        return [
          "jit_supported": manager.jitSupported,
          "jit_acquired": manager.acquiredJit,
          "device_has_txm": manager.deviceHasTxm,
          "debugger_attached": manager.debuggerAttached,
          "txm_authorized": manager.txmAuthorized,
          "txm_handshake_would_run": manager.shouldAttemptTXMHandshake(),
          "acquisition_error": manager.acquisitionError ?? "",
          "stikdebug_installed": StikDebugLauncher.isStikDebugInstalled,
        ]
      }
      return ["ok": true, "data": data]
    }

    // POST /api/debug/jit/stikdebug — hand iCube's broker script to StikDebug (iOS only)
    server.addCustomHandler(forMethod: "POST", path: "/api/debug/jit/stikdebug") { _, _, _, _ in
      var launched = false
      DispatchQueue.main.sync { launched = StikDebugLauncher.enableJIT() }
      return ["ok": launched, "data": ["launched": launched]]
    }

    // GET /api/debug/render-state
    server.addCustomHandler(forMethod: "GET", path: "/api/debug/render-state") { _, _, _, _ in
      ["ok": true, "data": DOLDebugBridge.renderState()]
    }

    // GET /api/logs  query tail=N, defaults to 200 when absent; N must be a non-negative integer
    // GET /api/debug/mem?addr=0x801aa380&len=64 — raw emulated RAM as hex, read from the host
    // mapping without pausing the CPU (works while a panic alert blocks the CPU thread). Distinguishes
    // "RAM really holds zeros" from "the CPU core fetched the wrong thing".
    server.addCustomHandler(forMethod: "GET", path: "/api/debug/mem") { _, _, query, _ in
      guard let addrRaw = query?["addr"], let addr = UInt32(addrRaw.replacingOccurrences(of: "0x", with: ""), radix: 16) else {
        return ["ok": false, "status": 400, "error": "addr must be a hex guest address"]
      }
      let len = UInt32(query?["len"] ?? "") ?? 64
      guard len > 0, len <= 65536 else {
        return ["ok": false, "status": 400, "error": "len must be 1...65536"]
      }
      guard let data = DOLDebugBridge.readGuestMemory(addr, length: len) else {
        return ["ok": false, "status": 409, "error": "core not running or range is not RAM"]
      }
      let nonZero = data.reduce(0) { $0 + ($1 == 0 ? 0 : 1) }
      return ["ok": true, "data": [
        "addr": String(format: "0x%08x", addr), "len": Int(len), "nonzero_bytes": nonZero,
        "hex": data.map { String(format: "%02x", $0) }.joined(),
      ] as [String: Any]]
    }

    // GET /api/debug/memarena — arena mode + live alias matrix of the real guest RAM views.
    server.addCustomHandler(forMethod: "GET", path: "/api/debug/memarena") { _, _, _, _ in
      ["ok": true, "data": DOLDebugBridge.memArenaReport()]
    }

    // POST /api/debug/memtest — standalone arena self-test in every Darwin mode (no game needed).
    server.addCustomHandler(forMethod: "POST", path: "/api/debug/memtest") { _, _, _, _ in
      ["ok": true, "data": DOLDebugBridge.memArenaSelfTest()]
    }

    server.addCustomHandler(forMethod: "GET", path: "/api/logs") { _, _, query, _ in
      guard let raw = query?["tail"] else {
        return ["ok": true, "data": ["lines": DOLDebugBridge.logTail(200)]]
      }
      guard let n = Int(raw), n >= 0 else {
        return ["ok": false, "status": 400, "error": "tail must be a non-negative integer"]
      }
      return ["ok": true, "data": ["lines": DOLDebugBridge.logTail(n)]]
    }

    registered = true
  }

  // MARK: - Encoding helper

  /// Encode a Codable into a JSON object suitable for JSONSerialization.
  private static func encodeJSONObject<T: Encodable>(_ value: T) -> Any? {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(value) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
  }
}
