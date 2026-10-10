#!/usr/bin/env python3
"""
iCube design-token ratchet (design spec §4.3, docs/superpowers/specs/2026-10-10-icube-design-language.md).

Counts hard-coded styling in Source/iOS/App/Common/**/*.swift -- system font sizes and text styles,
custom fonts, numeric corner radii and line widths, RGB colours, named system colours, bordered-
prominent buttons, and .navigationTitle in tvOS code -- outside the design module
(MenuKit/ICubeDesign*.swift). Debug screens are exempt, as is any line ending in
`// design-lint: allow <reason>`.

It is a ratchet, not a hard fail: design_tokens_baseline.json holds each file's count when the
module landed. --check fails if any file's count rises above its baseline (a file not in the
baseline has a baseline of 0). When counts fall, --check passes and asks you to run --update so
the lower count becomes the new ceiling.

Run from anywhere:
  python3 Source/iOS/App/Project/Scripts/check_design_tokens.py --check
  python3 Source/iOS/App/Project/Scripts/check_design_tokens.py --update
"""
import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
APP_ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))  # Source/iOS/App
SCAN_ROOT = "Common"
BASELINE = os.path.join(HERE, "design_tokens_baseline.json")
ALLOW_MARKER = "design-lint: allow"

TEXT_STYLES = "largeTitle|title|title2|title3|headline|subheadline|body|callout|footnote|caption|caption2"
# (?<!\w) keeps a design-module call such as `icube.font(.body)` from matching `.font(.body`.
PATTERNS = [
    re.compile(r"(?<!\w)\.font\(\.system\(size:"),
    re.compile(r"(?<!\w)\.font\(\.(?:%s)\b" % TEXT_STYLES),
    re.compile(r"\bFont\.custom\("),
    re.compile(r"\bcornerRadius:\s*[0-9]"),
    re.compile(r"\blineWidth:\s*[0-9]"),
    re.compile(r"\bColor\(red:"),
    re.compile(r"\bColor\.(?:blue|cyan|purple|orange|yellow|green|pink)\b"),
    re.compile(r"\.borderedProminent\b"),
]
NAV_TITLE = re.compile(r"\.navigationTitle\(")


def is_exempt(rel_path):
    parts = rel_path.split("/")
    name = parts[-1]
    if name.startswith("ICubeDesign") and "MenuKit" in parts:
        return True
    if "Debug" in parts[:-1] or "Debug" in name:
        return True
    return False


def _strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    out = []
    for line in text.split("\n"):
        if ALLOW_MARKER in line:
            out.append("")
            continue
        out.append(re.sub(r"//.*$", "", line))
    return out


def count_violations(text, rel_path):
    tv_file = os.path.basename(rel_path).startswith("TV")
    stack = []  # one of "tv", "notv", "other" per open #if
    total = 0
    for line in _strip_comments(text):
        s = line.strip()
        if s.startswith("#if"):
            if re.match(r"#if\s+os\(tvOS\)\s*$", s):
                stack.append("tv")
            elif re.match(r"#if\s+!os\(tvOS\)|#if\s+os\(iOS\)", s):
                stack.append("notv")
            else:
                stack.append("other")
            continue
        if s.startswith("#elseif"):
            if stack:
                stack[-1] = "other"
            continue
        if s.startswith("#else"):
            if stack:
                stack[-1] = {"tv": "notv", "notv": "tv"}.get(stack[-1], "other")
            continue
        if s.startswith("#endif"):
            if stack:
                stack.pop()
            continue
        for pattern in PATTERNS:
            total += len(pattern.findall(line))
        in_tv = "tv" in stack or (tv_file and "notv" not in stack)
        if in_tv:
            total += len(NAV_TITLE.findall(line))
    return total


def scan():
    counts = {}
    root = os.path.join(APP_ROOT, SCAN_ROOT)
    for dirpath, _, files in os.walk(root):
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            rel = os.path.relpath(os.path.join(dirpath, name), APP_ROOT).replace(os.sep, "/")
            if is_exempt(rel):
                continue
            with open(os.path.join(dirpath, name), encoding="utf-8") as f:
                n = count_violations(f.read(), rel)
            if n:
                counts[rel] = n
    return counts


def compare(current, baseline):
    worse = {p: (baseline.get(p, 0), n) for p, n in current.items() if n > baseline.get(p, 0)}
    better = {p: (b, current.get(p, 0)) for p, b in baseline.items() if current.get(p, 0) < b}
    return worse, better


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--update", action="store_true")
    args = parser.parse_args()

    current = scan()
    if args.update:
        with open(BASELINE, "w", encoding="utf-8") as f:
            json.dump(dict(sorted(current.items())), f, indent=2)
            f.write("\n")
        print("design-token baseline: %d files, %d findings" % (len(current), sum(current.values())))
        return 0

    with open(BASELINE, encoding="utf-8") as f:
        baseline = json.load(f)
    worse, better = compare(current, baseline)
    for path, (was, now) in sorted(worse.items()):
        print("%s: %d hard-coded style(s), baseline %d. Use ICubeDesign tokens "
              "(Common/Swift/MenuKit/ICubeDesign*.swift) or mark the line "
              "'// %s <reason>'." % (path, now, was, ALLOW_MARKER))
    if better:
        print("design-token ratchet: %d file(s) improved; run --update to lower the baseline." % len(better))
    if worse:
        return 1
    print("design-token ratchet: OK (%d findings across %d files)" % (sum(current.values()), len(current)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
