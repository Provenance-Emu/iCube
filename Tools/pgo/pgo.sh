#!/usr/bin/env bash
#
# pgo.sh — one-command Profile-Guided Optimization for the iCube core (PVlibDolphin).
#
#   Tools/pgo/pgo.sh record    build + install the INSTRUMENTED app on a connected device, let you
#                              play, pull the .profraw files, merge them into pgo/icube.profdata,
#                              check the result, and rebuild the optimized core.
#   Tools/pgo/pgo.sh merge DIR merge .profraw files you already have (e.g. downloaded from the
#                              in-app web server: Software/pgo/) into pgo/icube.profdata.
#   Tools/pgo/pgo.sh status    what the current profile was recorded from and how stale it is.
#   Tools/pgo/pgo.sh device    which connected device `record` would use.
#   Tools/pgo/pgo.sh clean     remove the instrumented build dirs (build-*-pgogen, build-pgo).
#
# Nothing else to remember: once pgo/icube.profdata exists, EVERY core build (Xcode's
# "Build Dolphin Core" phase, BuildiOSXCFramework.py by hand, CI) uses it automatically;
# see BuildiOSXCFramework.py resolve_pgo(). DOL_PGO=off opts a build out.
#
# How the pieces fit:
#   - DOL_PGO=generate makes BuildiOSXCFramework.py build an instrumented core in its own
#     build dir (build-<platform>-Release-pgogen), so the normal build dir is never thrashed.
#   - The app's PGOFlush shim points the profile runtime at Documents/Software/pgo/icube-%m.profraw
#     and flushes when the app goes to the background and when a game is stopped.
#   - This script pulls that folder with devicectl, merges with llvm-profdata and refuses a
#     profile that does not actually contain the interpreter's hot code.
#
# Env overrides:
#   PGO_DEVICE=<udid | name substring>   default: the first connected physical device
#   PGO_CONFIG="Debug (Non-Jailbroken)"  app configuration to build (its own bundle id, so your
#                                        everyday app is left alone; the CORE is Release either way)
#   PGO_SCHEME="iCube (NJB)"
#   PGO_NO_REBUILD=1                     skip the optimized core rebuild at the end
#   PGO_KEEP_OLD=1                       merge the new run INTO the existing profile instead of
#                                        replacing it
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_DIR="$ROOT/Source/iOS/App"
PGO_DIR="$ROOT/pgo"
PROFDATA="$PGO_DIR/icube.profdata"
META="$PROFDATA.meta.json"
WORK="$ROOT/build-pgo"
CONFIG="${PGO_CONFIG:-Debug (Non-Jailbroken)}"
SCHEME="${PGO_SCHEME:-iCube (NJB)}"
# Symbols the merged profile must cover, or the recording did not exercise the interpreter.
REQUIRED_SYMBOLS=("CachedInterpreter" "MicroOpHandlers")

say()  { printf '\033[1;36m[pgo]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[pgo] %s\033[0m\n' "$*" >&2; exit 1; }

pick_device() {
  local json="$WORK/devices.json"
  mkdir -p "$WORK"
  xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || die "devicectl failed (Xcode 15+ needed)"
  python3 - "$json" "${PGO_DEVICE:-}" <<'PY'
import json, sys
want = sys.argv[2].lower()
devices = json.load(open(sys.argv[1]))["result"]["devices"]
rows = []
for d in devices:
    hw, conn, props = d.get("hardwareProperties", {}), d.get("connectionProperties", {}), d.get("deviceProperties", {})
    if hw.get("reality") != "physical" or conn.get("tunnelState") == "unavailable":
        continue
    rows.append((hw.get("udid", ""), props.get("name", "?"), hw.get("platform", "?")))
if want:
    rows = [r for r in rows if r[0].lower().startswith(want) or want in r[1].lower()]
else:
    # The instrumented build targets iphoneos: never pick an Apple TV / Watch by accident.
    rows = [r for r in rows if r[2] == "iOS"]
if not rows:
    sys.exit("no connected physical device" + (f" matching {want!r}" if want else ""))
if len(rows) > 1:
    print("several devices are connected; using the first. Choose with PGO_DEVICE=<name or udid>:", file=sys.stderr)
    for r in rows:
        print(f"    {r[1]}  ({r[0]})", file=sys.stderr)
print("\t".join(rows[0]))
PY
}

merge_profile() {
  local src="$1"
  local raws=()
  while IFS= read -r -d '' f; do raws+=("$f"); done < <(find "$src" -name '*.profraw' -size +0 -print0)
  [ "${#raws[@]}" -gt 0 ] || die "no .profraw files under $src (did a game run, and was the app sent to the background?)"
  mkdir -p "$PGO_DIR"
  local inputs=("${raws[@]}")
  if [ "${PGO_KEEP_OLD:-0}" = "1" ] && [ -f "$PROFDATA" ]; then
    inputs+=("$PROFDATA")
    say "merging ${#raws[@]} new raw profile(s) into the existing profile"
  else
    say "merging ${#raws[@]} raw profile(s)"
  fi
  xcrun llvm-profdata merge -o "$PROFDATA.new" "${inputs[@]}"

  # Acceptance gate: a profile that never saw the interpreter would silently optimize nothing.
  local functions="$WORK/functions.txt"
  xcrun llvm-profdata show --all-functions "$PROFDATA.new" > "$functions" 2>/dev/null || true
  for sym in "${REQUIRED_SYMBOLS[@]}"; do
    local hits
    hits=$(grep -c "$sym" "$functions" || true)
    [ "$hits" -gt 0 ] || { rm -f "$PROFDATA.new"; die "profile has no '$sym' functions: the interpreter never ran. Play a game, not just the menus."; }
    say "  $sym: $hits profiled functions"
  done
  [ -f "$PROFDATA" ] && cp "$PROFDATA" "$PROFDATA.prev"
  mv "$PROFDATA.new" "$PROFDATA"

  python3 - "$META" "$ROOT" "${2:-unknown}" "${#raws[@]}" <<'PY'
import json, subprocess, sys, datetime
meta, root, device, raws = sys.argv[1:5]
git = lambda *a: subprocess.run(["git", "-C", root, *a], capture_output=True, text=True).stdout.strip()
json.dump({
    "recorded_sha": git("rev-parse", "HEAD"),
    "recorded_subject": git("log", "-1", "--format=%s"),
    "dirty": bool(git("status", "--porcelain", "--", "Source/Core")),
    "iso_ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "device": device,
    "raw_profiles": int(raws),
}, open(meta, "w"), indent=2)
PY
  say "wrote $PROFDATA ($(du -h "$PROFDATA" | cut -f1)) and $(basename "$META")"
}

cmd_status() {
  [ -f "$PROFDATA" ] || { say "no profile yet ($PROFDATA). Run: Tools/pgo/pgo.sh record"; return 0; }
  python3 - "$META" "$ROOT" "$PROFDATA" <<'PY'
import json, os, subprocess, sys, datetime
meta_path, root, profdata = sys.argv[1:4]
meta = json.load(open(meta_path)) if os.path.exists(meta_path) else {}
sha = meta.get("recorded_sha", "")
git = lambda *a: subprocess.run(["git", "-C", root, *a], capture_output=True, text=True).stdout.strip()
behind = git("rev-list", "--count", f"{sha}..HEAD", "--", "Source/Core") if sha else "?"
age = "?"
if meta.get("iso_ts"):
    age = (datetime.datetime.now(datetime.timezone.utc) - datetime.datetime.fromisoformat(meta["iso_ts"])).days
print(f"profile   {profdata} ({os.path.getsize(profdata) // 1024} KiB)")
print(f"recorded  {meta.get('iso_ts', '?')} on {meta.get('device', '?')} from {sha[:10] or '?'} {meta.get('recorded_subject', '')}")
print(f"staleness {behind} core commit(s) behind HEAD, {age} day(s) old" + ("  (recorded from a dirty tree)" if meta.get("dirty") else ""))
try:
    n = int(behind)
    print("verdict   " + ("fresh" if n <= 5 else "getting stale: re-record soon" if n <= 25 else "STALE: re-record (clang ignores functions that changed, so the hot code is probably unoptimized)"))
except ValueError:
    pass
PY
}

cmd_record() {
  command -v xcodebuild >/dev/null || die "xcodebuild not found"
  local row udid name
  row="$(pick_device)" || die "$row"
  udid="$(cut -f1 <<<"$row")"; name="$(cut -f2 <<<"$row")"
  say "device: $name ($udid)"

  if command -v tuist >/dev/null; then
    say "regenerating the Xcode project (tuist generate)"
    (cd "$APP_DIR" && tuist generate --no-open >/dev/null)
  fi

  say "building the INSTRUMENTED app: scheme '$SCHEME', configuration '$CONFIG' (first time: a full core build, ~20-30 min)"
  local log="$WORK/xcodebuild.log"
  mkdir -p "$WORK"
  (cd "$APP_DIR" && xcodebuild build -workspace iCube.xcworkspace -scheme "$SCHEME" \
      -configuration "$CONFIG" -destination "id=$udid" -derivedDataPath "$WORK/DerivedData" \
      -allowProvisioningUpdates DOL_PGO=generate >"$log" 2>&1) \
    || { tail -n 40 "$log"; die "instrumented build failed (full log: $log)"; }

  local app
  app="$(find "$WORK/DerivedData/Build/Products" -maxdepth 2 -name 'iCube.app' -path "*$CONFIG-iphoneos*" | head -n 1)"
  [ -d "$app" ] || die "built app not found under $WORK/DerivedData/Build/Products"
  local core="$app/Frameworks/PVlibDolphin-ios.framework/PVlibDolphin-ios"
  nm -gU "$core" 2>/dev/null | grep -q '___llvm_profile_write_file' \
    || die "the embedded core is NOT instrumented ($core). Stale framework copy? Try: Tools/pgo/pgo.sh clean"
  local bundle
  bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"

  say "installing $bundle"
  xcrun devicectl device install app --device "$udid" "$app" >/dev/null
  # Start from a clean slate so old counters from another build never get merged in.
  xcrun devicectl device process launch --device "$udid" "$bundle" >/dev/null 2>&1 || true

  cat <<EOF

  ------------------------------------------------------------------------------
  The instrumented iCube is on the phone (it is slower than normal: that is fine).

    1. Play the games you care about, a few minutes EACH, in their heavy scenes.
       (Wind Waker, Chibi-Robo, F-Zero GX, NSMBW ... the mix is the profile.)
    2. Exit each game back to the library before starting the next one.
    3. When done, go to the HOME SCREEN (that flushes the counters), then come back here.
  ------------------------------------------------------------------------------

EOF
  read -r -p "  Press Enter once the app is in the background... " _

  local raw="$WORK/profraw"
  rm -rf "$raw"; mkdir -p "$raw"
  say "pulling Documents/Software/pgo from the device"
  xcrun devicectl device copy from --device "$udid" --domain-type appDataContainer \
      --domain-identifier "$bundle" --source Documents/Software/pgo --destination "$raw" >/dev/null \
    || die "could not copy the profiles off the device (is it unlocked?)"
  merge_profile "$raw" "$name"

  if [ "${PGO_NO_REBUILD:-0}" != "1" ]; then
    say "rebuilding the OPTIMIZED core with the new profile"
    (cd "$ROOT" && /usr/bin/python3 BuildiOSXCFramework.py -p OS64 -v >"$WORK/optimized-core.log" 2>&1) \
      || { tail -n 40 "$WORK/optimized-core.log"; die "optimized core build failed (log: $WORK/optimized-core.log)"; }
    say "done. build/xcframework now holds the profile-optimized core; build the app as usual."
  else
    say "done. The next core build picks the profile up automatically."
  fi
  say "commit pgo/icube.profdata(+ .meta.json) so CI and TestFlight builds use it too."
}

cmd_clean() {
  say "removing instrumented build dirs"
  rm -rf "$WORK" "$ROOT"/build-*-pgogen
}

case "${1:-}" in
  record) cmd_record ;;
  merge)  [ -n "${2:-}" ] || die "usage: pgo.sh merge <dir with .profraw files>"; mkdir -p "$WORK"; merge_profile "$2" "manual" ;;
  status) cmd_status ;;
  device) row="$(pick_device)" || die "$row"; say "would use: $(cut -f2 <<<"$row") ($(cut -f1 <<<"$row"), $(cut -f3 <<<"$row"))" ;;
  clean)  cmd_clean ;;
  *) sed -n '3,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
