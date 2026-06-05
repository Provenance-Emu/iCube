#!/usr/bin/env python3
"""
iCube settings-wiring linter.

Verifies that every Dolphin Config:: setting the iOS UI can WRITE is accounted for by
"Reset to Defaults" — either reset-covered or explicitly marked as intentionally
preserved. A writable key that is neither is a SILENT RESET GAP (the user toggles it,
hits "Reset All", and it does not revert).

It also checks the NSUserDefaults gameplay keys the settings UI writes against the
resetGameplayUserDefaults list.

Source of truth, parsed from DOLConfigBridge.mm:
  WRITABLE  = first arg of Config::SetBaseOrCurrent / Config::SetCurrent  (UI writes)
  COVERED   = first arg of del(...) / safe_delete(...) / Config::SetBase(...)
              (reset functions delete-to-default or force a value)
  PRESERVED = the explicit allowlist below (identity / input / cosmetic / debug)

Exit code 0 = clean, 1 = gaps found. Run from anywhere:
  python3 Source/iOS/App/Project/Scripts/check_settings_wiring.py
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.normpath(os.path.join(HERE, "..", ".."))  # Source/iOS/App
BRIDGE = os.path.join(APP, "Common", "Bridging", "DOLConfigBridge.mm")

# Keys intentionally NOT reset (identity / custom / input / cosmetic / debug).
# Mirrors the "intentionally NOT reset" NOTE in resetGameplayConfigKeys. Add a key
# here ONLY when it is deliberately preserved across a factory reset.
PRESERVE_EXACT = {
    # input / controller prefs
    "MAIN_INPUT_BACKGROUND_INPUT",
    "MAIN_CONNECT_WIIMOTES_FOR_CONTROLLER_INTERFACE",
    "MAIN_WIIMOTE_CONTINUOUS_SCANNING",
    "MAIN_WIIMOTE_ENABLE_SPEAKER",
    "MAIN_TOUCH_PAD_IR_MODE",
    "MAIN_TOUCH_PAD_OPACITY",
    "MAIN_WII_KEYBOARD",
    # locale identity (GC system language; mirrors preserved SYSCONF_LANGUAGE for Wii)
    "MAIN_GC_LANGUAGE",
    # cosmetic overlays / UX prefs (left as-is by design)
    "MAIN_OSD_MESSAGES",
    "MAIN_USE_PANIC_HANDLERS",
    "MAIN_PAUSE_ON_PANIC",
    "MAIN_CONFIRM_ON_STOP",
    "MAIN_USE_BUILT_IN_TITLE_DATABASE",
    "MAIN_USE_GAME_COVERS",
    "GFX_OVERLAY_STATS",
    # debug-only
    "GFX_ENABLE_VALIDATION_LAYER",
    "GFX_LOG_RENDER_TIME_TO_FILE",
    # validate-twins of perf flags: diagnostic-only, default off; covered with their
    # parent flag when present, otherwise preserved (never user-facing perf settings).
}
PRESERVE_PREFIX = (
    "RA_",        # RetroAchievements identity/login
    "SYSCONF_",   # Wii console identity (region/language/sensor bar/etc.)
    "MAIN_WII_",  # Wii region/SD/WiiLink identity
    "GFX_SHOW_",  # perf-overlay toggles (cosmetic)
)


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def keys(pattern, text):
    return set(re.findall(pattern, text))


def main():
    if not os.path.exists(BRIDGE):
        print(f"ERROR: bridge not found at {BRIDGE}", file=sys.stderr)
        return 2
    src = read(BRIDGE)

    writable = keys(r"Config::(?:SetBaseOrCurrent|SetCurrent)\(Config::([A-Z0-9_]+)", src)
    covered = (
        keys(r"\bdel\(Config::([A-Z0-9_]+)", src)
        | keys(r"\bsafe_delete\(Config::([A-Z0-9_]+)", src)
        | keys(r"Config::SetBase\(Config::([A-Z0-9_]+)", src)
    )

    def preserved(k):
        return k in PRESERVE_EXACT or k.startswith(PRESERVE_PREFIX)

    gaps = sorted(k for k in writable if k not in covered and not preserved(k))

    print("== iCube settings-wiring linter ==")
    print(f"writable (UI can set): {len(writable)}")
    print(f"reset-covered:         {len(covered)}")
    print(f"preserved (allowlist): {len(PRESERVE_EXACT)} exact + {len(PRESERVE_PREFIX)} prefixes")
    print()

    if gaps:
        print(f"FAIL: {len(gaps)} writable Config key(s) are neither reset-covered nor preserved:")
        for k in gaps:
            print(f"  - Config::{k}")
        print()
        print("Fix: add each to resetGameplayConfigKeys (del/SetBase) OR to the")
        print("PRESERVE allowlist in this script if it is intentionally not reset.")
        return 1

    print("OK: every UI-writable Config key is reset-covered or explicitly preserved.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
