#!/usr/bin/env python3
"""List TestFlight feedback (screenshots + crash submissions) for an app.

Reuses the App Store Connect client from the vendored TestFlight distribute action,
so it takes the same env: ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_CONTENT,
BUNDLE_ID (default com.joemattiello.iCube). Optional: DAYS (default 14), LIMIT (default 50),
CRASH_LOG_DIR (download crash logs there).

Usage: source ~/.config/provenance-dev/asc.sh; python3 scripts/asc_feedback.py [--json]
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DISTRIBUTE = ROOT / ".github" / "actions" / "testflight-distribute" / "distribute.py"


def load_distribute():
    spec = importlib.util.spec_from_file_location("distribute", DISTRIBUTE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def page(client, path: str, **query: str):
    """Yield every item across pagination."""
    data = client.get(path, **query)
    while True:
        yield from data.get("data", [])
        nxt = data.get("links", {}).get("next")
        if not nxt:
            return
        data = client.call("GET", nxt[len(client_api()):]) if nxt.startswith(client_api()) else client.call("GET", nxt)


def client_api() -> str:
    return load_distribute().API


def included_index(payload: dict) -> dict:
    return {(i["type"], i["id"]): i for i in payload.get("included", [])}


def main() -> int:
    mod = load_distribute()
    os.environ.setdefault("BUNDLE_ID", "com.joemattiello.iCube")
    days = int(os.environ.get("DAYS", "14"))
    limit = int(os.environ.get("LIMIT", "50"))
    since = datetime.now(timezone.utc) - timedelta(days=days)
    as_json = "--json" in sys.argv

    client = mod.Client()
    app_id = mod.find_app(client, os.environ["BUNDLE_ID"])
    out: dict[str, list] = {"screenshots": [], "crashes": []}

    def collect(kind: str, path: str, fields: str | None = None):
        query = {"limit": str(limit), "sort": "-createdDate", "include": "build",
                 "fields[builds]": "version,uploadedDate"}
        if fields:
            query[f"fields[{path}]"] = fields
        payload = client.get(f"/v1/apps/{app_id}/{path}", **query)
        inc = included_index(payload)
        for item in payload.get("data", []):
            a = item["attributes"]
            created = datetime.fromisoformat(a["createdDate"].replace("Z", "+00:00"))
            if created < since:
                continue
            build_ref = item.get("relationships", {}).get("build", {}).get("data")
            build = inc.get(("builds", build_ref["id"]), {}).get("attributes", {}) if build_ref else {}
            out[kind].append({
                "id": item["id"],
                "created": created.isoformat(timespec="minutes"),
                "build": build.get("version"),
                "device": a.get("deviceModel"),
                "os": a.get("osVersion"),
                "platform": a.get("appPlatform"),
                "email": a.get("email"),
                "comment": (a.get("comment") or "").strip(),
                "crash_type": a.get("crashType"),
            })

    collect("screenshots", "betaFeedbackScreenshotSubmissions",
            "createdDate,comment,email,deviceModel,osVersion,appPlatform,build")
    collect("crashes", "betaFeedbackCrashSubmissions")

    log_dir = os.environ.get("CRASH_LOG_DIR")
    if log_dir:
        Path(log_dir).mkdir(parents=True, exist_ok=True)
        for c in out["crashes"]:
            try:
                log = client.get(f"/v1/betaFeedbackCrashSubmissions/{c['id']}/crashLog")
                url = log["data"]["attributes"].get("url")
                if url:
                    import urllib.request
                    dest = Path(log_dir) / f"{c['created'][:10]}-{c['id']}.crash"
                    urllib.request.urlretrieve(url, dest)
                    c["crash_log"] = str(dest)
            except Exception as exc:  # noqa: BLE001
                c["crash_log_error"] = str(exc)

    if as_json:
        print(json.dumps(out, indent=2))
        return 0

    for kind, label in (("crashes", "Crash submissions"), ("screenshots", "Screenshot feedback")):
        items = out[kind]
        print(f"== {label}: {len(items)} in the last {days} days")
        for c in items:
            head = f"{c['created']}  build {c['build']}  {c['device']} {c['os']}"
            if c.get("crash_type"):
                head += f"  {c['crash_type']}"
            print(head)
            if c["comment"]:
                print("   " + c["comment"].replace("\n", "\n   "))
            if c.get("crash_log"):
                print(f"   log: {c['crash_log']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
