#!/usr/bin/env python3
"""
iCube localized-key coverage checker.

UI strings go through `L("...")` (Common/Swift/Localized.swift -> NSLocalizedString)
and are looked up at runtime in en.lproj/Core.strings (and ja.lproj/Core.strings).
Core.strings itself is maintained by a separate pipeline that this script does NOT
replace:

  - Project/Scripts/UpdateCoreStrings.py runs as an "Update Core Strings" build
    pre-script. It converts Languages/po/<lang>.po (the upstream Dolphin core
    translation catalog) into <lang>.lproj/Core.strings, but MERGES rather than
    overwrites: a .po key wins, and any existing Core.strings key the .po does NOT
    provide is preserved verbatim. That preservation path is how DolphiniOS-only
    UI strings (library grid, controller settings, etc.) survive rebuilds.
  - .bartycrouch.toml only runs BartyCrouch's "interfaces" task over DolphiniOS,
    which extracts strings from Storyboards/XIBs into their own per-file .strings
    tables -- it does not touch Core.strings and knows nothing about `L("...")`
    call sites in Swift.

Nothing today extracts new `L("...")` call sites out of Swift source and folds them
into Core.strings; that has been a manual/ad-hoc "genstrings audit" step. This
script is the automated half of that audit: it finds every `L("literal")` key used
under Source/iOS/App and reports which ones are missing from en.lproj/Core.strings.

Existing Core.strings entries are read via `plutil -convert json`, not a hand-rolled
.strings parser: the file legitimately contains multi-line entries (the .po ->
.strings conversion writes literal newlines from multi-line msgids/msgstrs instead
of escaping them as \\n), which a naive line-by-line "key" = "value"; regex silently
undercounts. plutil is the authoritative parser Xcode itself uses for this format.

This script does NOT modify Core.strings and is NOT wired into the Xcode build --
run it by hand (or from a separate lint job) after adding new `L(...)` call sites:

  python3 Source/iOS/App/Project/Scripts/check_localized_keys.py
  python3 Source/iOS/App/Project/Scripts/check_localized_keys.py --check   # CI-style: exit 1 if any are missing

Exit code (plain mode): always 0 -- it's a report.
Exit code (--check):    0 if every L() key exists in Core.strings, 1 if any are missing.
"""
import argparse
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
APP_ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))  # Source/iOS/App

SEARCH_DIRS = ["Common", "DolphiniOS"]
CORE_STRINGS_EN = os.path.join(APP_ROOT, "Common", "UI", "Localization", "en.lproj", "Core.strings")

# Directories to never descend into: Xcode/Tuist build output, dependency checkouts,
# and anything not actually part of the app's own Swift source.
SKIP_DIR_PREFIXES = ("build-", "build",)
SKIP_DIR_NAMES = {
    ".git", ".build", "DerivedData", "Derived",
    "iCube.xcodeproj", "iCube.xcworkspace",
    "DolphiniOS.xcodeproj", "DolphiniOS.xcworkspace",
    "Pods", "__pycache__", "venv", ".venv",
}

# Matches `L("...")` with a plain string-literal argument, tolerating escaped
# characters (\" \\ \n \u{...} etc.) inside the literal, and incidental whitespace
# around the argument.
L_CALL_RE = re.compile(r'\bL\(\s*"((?:[^"\\]|\\.)*)"\s*\)')

# A raw (still-Swift-escaped) capture that contains string interpolation -- `\(` --
# is not a static key at all; NSLocalizedString would be called with a runtime
# value that can never be cataloged ahead of time. Flag these separately instead of
# treating the literal interpolation source text as a "key".
INTERPOLATION_RE = re.compile(r'\\\(')

_UNICODE_ESCAPE_RE = re.compile(r'\\u\{([0-9a-fA-F]+)\}')
_SIMPLE_ESCAPES = {
    'n': '\n', 't': '\t', 'r': '\r', '"': '"', "'": "'", '\\': '\\', '0': '\0',
}


def decode_swift_string_literal(raw):
    """Decodes the escapes Swift allows inside a plain (non-raw) string literal:
    \\\\ \\" \\n \\t \\r \\0 and \\u{XXXX}. Leaves anything else (there shouldn't be
    anything else once interpolation call sites are filtered out) untouched."""
    raw = _UNICODE_ESCAPE_RE.sub(lambda m: chr(int(m.group(1), 16)), raw)

    out = []
    i = 0
    while i < len(raw):
        c = raw[i]
        if c == '\\' and i + 1 < len(raw):
            nxt = raw[i + 1]
            out.append(_SIMPLE_ESCAPES.get(nxt, nxt))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def encode_strings_value(s):
    """Encodes a plain string into the escaped form a .strings file entry needs."""
    return (
        s.replace("\\", "\\\\")
         .replace('"', '\\"')
         .replace("\n", "\\n")
         .replace("\t", "\\t")
    )


def iter_swift_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [
            d for d in dirnames
            if d not in SKIP_DIR_NAMES and not d.startswith(SKIP_DIR_PREFIXES)
        ]
        for name in filenames:
            if name.endswith(".swift"):
                yield os.path.join(dirpath, name)


def find_l_keys():
    """Returns (keys, interpolated) where:
    keys = {decoded_key: [(relative_path, line_no), ...]} for static `L("...")` call sites
    interpolated = [(relative_path, line_no, raw_source)] for call sites using \\( interpolation,
                    which cannot be statically cataloged.
    """
    keys = {}
    interpolated = []
    for search_dir in SEARCH_DIRS:
        root = os.path.join(APP_ROOT, search_dir)
        if not os.path.isdir(root):
            continue
        for path in iter_swift_files(root):
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                for line_no, line in enumerate(f, start=1):
                    for match in L_CALL_RE.finditer(line):
                        raw = match.group(1)
                        rel_path = os.path.relpath(path, APP_ROOT)
                        if INTERPOLATION_RE.search(raw):
                            interpolated.append((rel_path, line_no, raw))
                            continue
                        key = decode_swift_string_literal(raw)
                        keys.setdefault(key, []).append((rel_path, line_no))
    return keys, interpolated


def load_existing_keys(strings_path):
    """Authoritative key set via plutil (handles the multi-line entries the .po
    conversion writes; a hand-rolled line-based regex undercounts them)."""
    if not os.path.exists(strings_path):
        return set()
    result = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", strings_path],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"ERROR: plutil failed to parse {strings_path}: {result.stderr}", file=sys.stderr)
        sys.exit(2)
    return set(json.loads(result.stdout).keys())


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--check", action="store_true",
        help="Exit non-zero if any L(...) key is missing from en.lproj/Core.strings."
    )
    args = parser.parse_args()

    if not os.path.exists(CORE_STRINGS_EN):
        print(f"ERROR: not found: {CORE_STRINGS_EN}", file=sys.stderr)
        return 2

    used, interpolated = find_l_keys()
    existing = load_existing_keys(CORE_STRINGS_EN)

    missing = sorted(key for key in used if key not in existing)

    print("== iCube localized-key coverage checker ==")
    print(f"L(...) call sites scanned:              {sum(len(v) for v in used.values()) + len(interpolated)}")
    print(f"  static (cataloguable):                {sum(len(v) for v in used.values())}")
    print(f"  interpolated (skipped, not static):   {len(interpolated)}")
    print(f"Distinct static L(...) keys found:      {len(used)}")
    print(f"Keys already in en.lproj/Core.strings:  {len(existing)}")
    print(f"Missing keys:                           {len(missing)}")
    print()

    if interpolated:
        print("Skipped (string-interpolated `L(\"...\\(...)...\")` call sites -- not a static "
              "key, cannot be cataloged; these need a rewrite to `L(\"format %@\") ` + "
              "String(format:) if they should ever be localizable):")
        for rel_path, line_no, raw in interpolated[:20]:
            print(f"  - {rel_path}:{line_no}  L(\"{raw}\")")
        if len(interpolated) > 20:
            print(f"  ... and {len(interpolated) - 20} more")
        print()

    if missing:
        print("Missing from en.lproj/Core.strings:")
        for key in missing:
            locations = ", ".join(f"{path}:{line}" for path, line in used[key][:3])
            more = "" if len(used[key]) <= 3 else f" (+{len(used[key]) - 3} more)"
            print(f"  - \"{key}\"  [{locations}{more}]")
        print()

    if args.check:
        if missing:
            print(f"FAIL: {len(missing)} key(s) missing from en.lproj/Core.strings.")
            return 1
        print("OK: every L(...) key exists in en.lproj/Core.strings.")
        return 0

    print("Report mode: no keys were added or removed. Re-run with --check to get a "
          "non-zero exit code for missing keys.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
