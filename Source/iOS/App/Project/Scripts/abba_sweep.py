#!/usr/bin/env python3
"""One long ABBA sweep of a bool settings key on the booted game, every leg kept, drift-corrected fit.

usage: abba_sweep.py <gameID> <key> <blocks> [seconds]
Needs the DEV app with the bench on, <gameID> booted and a save in slot 1 (`iproxy 8726 8723`).
Issues ONE /api/bench/sweep of OFF,ON,ON,OFF x <blocks> (perf_matrix.py keeps only the last sweep
per key, so repeated palindromes there lose data), uncapped under benchmarkBase, then fits
speed = a + b*leg + c*ON and prints c as a percentage with its 1-sigma error. Resets <key> to its
code default afterwards.
"""
import json, sys, time, urllib.request
import numpy as np
B = "http://127.0.0.1:8726"
def call(p, body=None, t=20):
    req = urllib.request.Request(B + p, data=json.dumps(body).encode() if body is not None else None,
                                 method="POST" if body is not None else "GET", headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=t) as r: return json.load(r)
game, key, blocks = sys.argv[1], sys.argv[2], int(sys.argv[3]); secs = float(sys.argv[4]) if len(sys.argv) > 4 else 30
order = [False, True, True, False] * blocks
prev = call("/api/bench/sweep/result")["data"].get("result")
call("/api/bench/preset", {"preset": "benchmarkBase"})
call("/api/settings/mainEmulationSpeedPercent", {"value": 0})
try:
    call("/api/bench/sweep", {"key": key, "values": order, "slot": 1, "seconds": secs})
    t0 = time.time()
    while True:
        time.sleep(10)
        try: d = call("/api/bench/sweep/result")["data"]
        except Exception: continue
        r = d.get("result")
        if d.get("status") != "running" and r and r != prev and r.get("key") == key and len(r.get("runs", [])) == len(order): break
        if time.time() - t0 > 3600: sys.exit("timeout")
finally:
    call("/api/settings/mainEmulationSpeedPercent", {"value": 100})
    call("/api/bench/preset", {"preset": "restore"})
    call("/api/settings/reset", {"keys": [key]})  # back to the code default, no Base-layer value
json.dump(r, open(f"abba_{game}_{key}.json", "w"), indent=1)
y = np.array([(run.get("result") or {}).get("summary", {}).get("meanSpeed", np.nan) for run in r["runs"]])
on = np.array([1.0 if o else 0.0 for o in order]); x = np.arange(len(y)); m = ~np.isnan(y)
A = np.c_[np.ones(m.sum()), x[m], on[m]]; c, *_ = np.linalg.lstsq(A, y[m], rcond=None)
res = y[m] - A @ c; cov = (res @ res / (m.sum() - 3)) * np.linalg.inv(A.T @ A)
th = [(run.get("result") or {}).get("thermalState", "?")[0] for run in r["runs"]]
print(f"{game} {key}: legs={m.sum()}/{len(y)} thermal={''.join(th)}")
print("  speeds", " ".join(f"{'B' if o else 'A'}{v:.3f}" for o, v in zip(on, y)))
blk = [(y[i+1]+y[i+2])/(y[i]+y[i+3]) - 1 for i in range(0, len(y), 4)]
print(f"  per-ABBA-block ON delta: {' '.join(f'{100*b:+.1f}%' for b in blk)}")
print(f"  fit ON {100*c[2]/c[0]:+.2f}% +/- {100*np.sqrt(cov[2,2])/c[0]:.2f}% (1 sigma), drift {100*c[1]/c[0]:+.2f}%/leg")
