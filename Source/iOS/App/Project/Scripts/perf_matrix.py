#!/usr/bin/env python3
"""One-factor-at-a-time perf matrix over the iCube debug bench.

usage: perf_matrix.py [--base http://127.0.0.1:8726] [--slot 1] [--seconds 20] [--out results.json]
                      [--factors KEY=v1,v2[,v3] ...] [--pair KEY=v ...]

Requires the DEV app with "Perf Test Bench (HTTP)" on, a game booted, and a save state in --slot
taken in a representative scene (busy 3D, not a menu). Over USB: `iproxy 8726 8723 -u <udid>`.

Per factor it POSTs /api/bench/sweep with the values in PALINDROME order (A,B,B,A or A,B,C,C,B,A):
this cancels a linear thermal drift exactly (docs: icube-device-ab-method). Boot-time keys make the
bench stop -> boot -> load-state per value; hot keys just load the state. Speed is uncapped and the
adaptive clock is off for the whole run via /api/bench/preset benchmarkBase, restored at the end.

Default factors are the 2026-09-26 default-settings evaluation:
  gfxShaderCompilationMode=0,2,1   (specialized, hybrid uber, exclusive uber)
  mainCachedInterpreterPrefetch=false,true
  cirPsNeon=false,true
  gfxHackNeonTextureDecode=true,false
  vertexLoaderMode=1,0             (NEON, software)
--pair KEY=v ... runs one extra ABBA of "all overrides applied" vs current settings.
"""
import argparse, json, sys, time, urllib.request, urllib.error

DEFAULT_FACTORS = [
    "gfxShaderCompilationMode=0,2,1",
    "mainCachedInterpreterPrefetch=false,true",
    "cirPsNeon=false,true",
    "gfxHackNeonTextureDecode=true,false",
    "vertexLoaderMode=1,0",
]


def call(base, path, body=None, timeout=15):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method="POST" if body is not None else "GET",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def coerce(v):
    if v in ("true", "false"):
        return v == "true"
    try:
        return int(v)
    except ValueError:
        return v


def normalize(v):
    """The device echoes booleans back as "0"/"1"; use that form everywhere so tables line up."""
    return {"true": "1", "false": "0"}.get(str(v).lower(), str(v))


def palindrome(values):
    return values + list(reversed(values))


def wait_sweep(base, key, previous, poll=5, limit=3600, grace=90):
    """Block until /api/bench/sweep/result holds a FINISHED result for `key` that differs from
    `previous`. Right after POST /api/bench/sweep the endpoint still returns "no-result" or the
    previous sweep's finished result for a moment, so neither may be taken as this sweep's."""
    t0 = time.time()
    while time.time() - t0 < limit:
        try:
            r = call(base, "/api/bench/sweep/result")["data"]
        except (urllib.error.URLError, TimeoutError, OSError):
            time.sleep(poll)
            continue
        status = r.get("status")
        if status == "running":
            time.sleep(poll)
            continue
        # Finished form: {"status": "done", "result": {key, hotSwappable, runs: [...]}}
        r = r.get("result") or {}
        if status == "no-result" or r.get("key") != key or r == previous:
            if time.time() - t0 > grace and status != "running":
                sys.exit(f"sweep for {key} never started (endpoint shows {status or r.get('key')})")
            time.sleep(poll)
            continue
        return r
    sys.exit("sweep did not finish in time")


def summarize(sweep):
    """Group the palindrome runs by value; report mean of each metric and per-pair deltas vs the first value."""
    by = {}
    for run in sweep.get("runs", []):
        if run.get("error") or not run.get("result"):
            by.setdefault(normalize(run["value"]), []).append(None)
            continue
        by.setdefault(normalize(run["value"]), []).append(run["result"]["summary"])
    rows = {}
    for value, sums in by.items():
        ok = [s for s in sums if s]
        if not ok:
            rows[value] = None
            continue
        rows[value] = {k: sum(s[k] for s in ok) / len(ok)
                       for k in ("meanSpeed", "meanFps", "meanMs", "p95Ms", "onePercentLowMs")}
        rows[value]["n"] = len(ok)
        rows[value]["speeds"] = [s["meanSpeed"] for s in ok]
    return rows


def print_rows(key, rows, base_value):
    print(f"\n== {key}")
    print(f"{'value':>8} {'n':>2} {'speed':>7} {'fps':>6} {'mean ms':>8} {'p95 ms':>7} {'1% low':>7} {'d speed':>8}")
    ref = rows.get(base_value)
    for value, r in rows.items():
        if r is None:
            print(f"{value:>8}  failed (see json)")
            continue
        delta = "" if not ref or value == base_value else f"{(r['meanSpeed'] / ref['meanSpeed'] - 1) * 100:+.1f}%"
        print(f"{value:>8} {r['n']:>2} {r['meanSpeed']:>7.3f} {r['meanFps']:>6.1f} {r['meanMs']:>8.2f} "
              f"{r['p95Ms']:>7.2f} {r['onePercentLowMs']:>7.2f} {delta:>8}")
        if len(r["speeds"]) >= 2 and ref and value != base_value and len(ref["speeds"]) >= 2:
            # First-half vs second-half deltas: if their signs disagree the drift was not linear.
            d1 = r["speeds"][0] / ref["speeds"][0] - 1
            d2 = r["speeds"][-1] / ref["speeds"][-1] - 1
            if (d1 > 0) != (d2 > 0):
                print(f"         ! pair deltas disagree ({d1 * 100:+.1f}% / {d2 * 100:+.1f}%): drift not linear, repeat")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:8726")
    ap.add_argument("--slot", type=int, default=1)
    ap.add_argument("--seconds", type=float, default=20)
    ap.add_argument("--out", default="perf_matrix_results.json")
    ap.add_argument("--factors", nargs="*", default=DEFAULT_FACTORS)
    ap.add_argument("--pair", nargs="*", default=[], help="KEY=v overrides for a final all-on vs current ABBA")
    ap.add_argument("--capped", action="store_true",
                    help="keep the 100%% throttle (stutter runs: read p95/1%% low, speed saturates at 1.00)")
    ap.add_argument("--pre", nargs="*", default=[],
                    help="KEY=v applied before the factors and restored after (e.g. gfxShaderCache=false for a cold cache)")
    args = ap.parse_args()

    h = call(args.base, "/api/health")["data"]
    if h.get("core_state") not in ("running", "paused"):
        sys.exit(f"no game running (core_state={h.get('core_state')}); boot one and take a state in slot {args.slot}")
    print(f"build {h.get('build_sha', '?')} game {h.get('game_id', '?')} thermal {h.get('thermal_state', '?')}")

    known = call(args.base, "/api/settings")["data"]
    results = {"health": h, "factors": {}}
    call(args.base, "/api/bench/preset", {"preset": "benchmarkBase"})
    # The preset pins the adaptive clock; speed must be uncapped separately or `speed`
    # saturates at 1.00 on any scene the core can keep up with. Hot key, persisted, so it
    # survives the per-value reboots; restored in `finally`.
    if not args.capped:
        call(args.base, "/api/settings/mainEmulationSpeedPercent", {"value": 0})
    pre = {k: coerce(normalize(v)) for k, v in (p.partition("=")[::2] for p in args.pre)}
    pre_before = {k: known[k]["value"] for k in pre if k in known}
    for k, v in pre.items():
        call(args.base, f"/api/settings/{k}", {"value": v})
    restore_after = {}
    last_sweep = None
    try:
        for spec in args.factors:
            key, _, raw = spec.partition("=")
            values = [normalize(v) for v in raw.split(",")]
            if key not in known:
                print(f"skip {key}: unknown to this build")
                continue
            order = palindrome(values)
            # The sweep leaves the device on the LAST value it applied (the list's first value),
            # not on what was set before; remember the original and put it back afterwards.
            restore_after[key] = known[key]["value"]
            call(args.base, "/api/bench/sweep",
                 {"key": key, "values": [coerce(v) for v in order], "slot": args.slot, "seconds": args.seconds})
            sweep = wait_sweep(args.base, key, last_sweep)
            last_sweep = sweep
            rows = summarize(sweep)
            results["factors"][key] = {"order": order, "sweep": sweep, "rows": rows}
            print_rows(key, rows, values[0])
            call(args.base, f"/api/settings/{key}", {"value": restore_after[key]})
            json.dump(results, open(args.out, "w"), indent=1)
        if args.pair:
            # "All overrides" vs "current": apply the bundle, sweep a no-op hot key so the bench
            # measures A, then restore and measure B, palindrome-wise.
            overrides = dict(p.partition("=")[::2] for p in args.pair)
            before = {k: known[k]["value"] for k in overrides if k in known}
            legs = []
            for leg in ("current", "all", "all", "current"):
                vals = overrides if leg == "all" else before
                call(args.base, "/api/settings/bulk", {"values": {k: coerce(str(v)) for k, v in vals.items()}, "mode": "merge"})
                call(args.base, "/api/bench/sweep",
                     {"key": "gfxHackNeonTextureDecode", "values": [known["gfxHackNeonTextureDecode"]["value"]],
                      "slot": args.slot, "seconds": args.seconds})
                sweep = wait_sweep(args.base, "gfxHackNeonTextureDecode", last_sweep)
                last_sweep = sweep
                run = sweep["runs"][0]
                legs.append({"leg": leg, "summary": run.get("result", {}).get("summary"), "error": run.get("error")})
                print(leg, legs[-1]["summary"])
            results["pair"] = legs
            call(args.base, "/api/settings/bulk", {"values": {k: coerce(str(v)) for k, v in before.items()}, "mode": "merge"})
    finally:
        for k, v in restore_after.items():
            try:
                call(args.base, f"/api/settings/{k}", {"value": v})
            except Exception as e:  # noqa: BLE001 - best-effort restore
                print(f"restore {k} failed: {e}")
        for k, v in pre_before.items():
            call(args.base, f"/api/settings/{k}", {"value": v})
        call(args.base, "/api/settings/mainEmulationSpeedPercent", {"value": 100})
        call(args.base, "/api/bench/preset", {"preset": "restore"})
        json.dump(results, open(args.out, "w"), indent=1)
        print(f"\nwrote {args.out}")


if __name__ == "__main__":
    main()
