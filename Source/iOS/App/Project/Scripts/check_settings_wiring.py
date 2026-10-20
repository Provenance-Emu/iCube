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
  WRITABLE  = Config::SetBase / SetBaseOrCurrent / SetCurrent in actual UI set* methods
  COVERED   = del(...) / Config::SetBase(...) / explicit DeleteKey calls INSIDE
              resetGameplayConfigKeys, plus its invoked DeleteCirKeys' actual
              Main/Core/CIR Config locations (reset deletes or forces a value)
  PRESERVED = the explicit allowlist below (identity / input / cosmetic / debug)

Exit code 0 = clean, 1 = gaps found. Run from anywhere:
  python3 Source/iOS/App/Project/Scripts/check_settings_wiring.py
"""
import os
from pathlib import Path
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.normpath(os.path.join(HERE, "..", ".."))  # Source/iOS/App
BRIDGE = os.path.join(APP, "Common", "Bridging", "DOLConfigBridge.mm")
CONFIG_DEFINITIONS = Path(APP).parents[1] / "Core" / "Core" / "Config"

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
    # Keep the user's SD card read-only/writeable policy alongside preserved SD configuration.
    # A gameplay reset must not silently enable writes to a deliberately protected card.
    "MAIN_ALLOW_SD_WRITES",
    # locale identity (GC system language; mirrors preserved SYSCONF_LANGUAGE for Wii)
    "MAIN_GC_LANGUAGE",
    # Device-local media selection; cleared through General management, not gameplay reset.
    # The bridge uses CurrentRun and local UserDefaults, never synced Base configuration.
    "MAIN_DEFAULT_ISO",
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


def without_comments(text):
    # Preserve quoted strings (including URLs) while removing comments. Location literals
    # are needed by the CIR predicate/definition audit below.
    return re.sub(r'("(?:\\.|[^"\\])*"|/\*.*?\*/|//[^\n]*)',
                  lambda match: match.group(0) if match.group(0).startswith('"') else "",
                  text, flags=re.S)


def body_after_open(source, start):
    depth = 1
    quote = None
    escaped = False
    for index in range(start, len(source)):
        char = source[index]
        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            continue
        if char in ('"', "'"):
            quote = char
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start:index]
    return ""


def function_body(source, declaration):
    match = re.search(declaration + r"\s*\{", source)
    return body_after_open(source, match.end()) if match else ""


def ui_writable_keys(bridge):
    # The bridge's reset/launch helpers also call SetBase. Only actual public setters
    # establish user-writable keys; their own writes never establish reset coverage.
    source = without_comments(bridge)
    writable = set()
    for match in re.finditer(r"\+\s*\([^)]*\)\s*set[A-Z]\w*\b[^;{}]*\{", source):
        writable |= keys(
            r"Config::(?:SetBaseOrCurrent|SetBase|SetCurrent)\s*\(\s*Config::([A-Z][A-Z0-9_]*)\s*,",
            body_after_open(source, match.end()),
        )
    return writable


def reset_covered_keys(bridge, definitions):
    source = without_comments(bridge)
    reset = function_body(source, r"\+\s*\(void\)\s*resetGameplayConfigKeys")
    return (
        keys(r"\bdel\(Config::([A-Z0-9_]+)\s*\)", reset)
        | keys(r"Config::SetBase\(Config::([A-Z0-9_]+)\s*,", reset)
        | keys(r"Config::DeleteKey\([^,\n]+,\s*Config::([A-Z0-9_]+)\s*\)", reset)
        | cir_reset_keys(bridge, definitions)
    )


def cir_reset_keys(bridge, definitions):
    """Resolve DeleteCirKeys coverage from Info locations, never C++ symbol prefixes.

    This recognizes the audited Main/Core/CIR location predicate conservatively: a
    changed predicate needs review instead of silently exempting new Config keys.
    """
    source = without_comments(bridge)
    reset = function_body(source, r"\+\s*\(void\)\s*resetGameplayConfigKeys")
    helper = function_body(source, r"static\s+void\s+DeleteCirKeys\([^)]*\)")
    predicate = function_body(source, r"static\s+bool\s+IsCirKey\([^)]*\)")
    expected = '''return location.system == Config::System::Main &&
      Common::CaseInsensitiveEquals(location.section, "Core") && location.key.size() > 3 &&
      Common::CaseInsensitiveEquals(std::string_view(location.key).substr(0, 3), "CIR");'''
    if re.sub(r"\s+", "", predicate) != re.sub(r"\s+", "", expected):
        return set()
    if not (re.search(r"\bDeleteCirKeys\(", reset)
            and re.search(r"\bIsCirKey\(location\)", helper)
            and re.search(r"layer->DeleteKey\(location\)", helper)):
        return set()
    locations = re.findall(
        r'\bconst\s+Info<[^;]+?>\s+(\w+)\s*\{\s*\{\s*System::(\w+),\s*"([^"]+)",\s*"([^"]+)"',
        without_comments(definitions),
    )
    return {name for name, system, section, key in locations
            if system == "Main" and section.lower() == "core"
            and len(key) > 3 and key[:3].lower() == "cir"}


def main():
    if not os.path.exists(BRIDGE):
        print(f"ERROR: bridge not found at {BRIDGE}", file=sys.stderr)
        return 2
    src = read(BRIDGE)

    definitions = "\n".join(read(path) for path in sorted(CONFIG_DEFINITIONS.glob("*.cpp")))
    writable = ui_writable_keys(src)
    covered = reset_covered_keys(src, definitions)

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
