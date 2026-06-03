#!/usr/bin/env python3
"""icube_config_lint.py — static audit of iCube's config <-> bridge <-> UI wiring.

Flags the class of bug iCube keeps hitting: a setting the frontend WRITES that the
backend never READS (e.g. GFX_HACK_VI_SKIP bool set by launch/UI while the runtime
reads GFX_HACK_VI_SKIP_MODE), plus NSUserDefaults key drift between Swift and ObjC.

Pure stdlib, Python 3. Regex/text scan — robust to missing files (warn, continue).
Exits nonzero if any DANGLING or MISMATCH issue is found, so it can be a CI gate.

Limitations (honest about false-positive risk):
  - This is a textual scanner, not a compiler. It cannot see *semantic* supersession
    (e.g. a tri-state MODE key overriding a legacy bool at runtime); it only knows
    "is symbol X referenced by Config::Get anywhere". Such cases are noted, not flagged.
  - Symbols read only via templated/iterated Config::Get over a container, or via
    string-built keys, are invisible to it.
  - NSUserDefaults keys built by string concatenation (prefix + gameID) are matched
    by prefix where detectable, else may appear as near-misses.
"""

import os
import re
import sys

# ---------------------------------------------------------------------------
# Repo roots / file globs
# ---------------------------------------------------------------------------
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

CONFIG_DIR = os.path.join(REPO, "Source", "Core", "Core", "Config")
CORE_ROOT = os.path.join(REPO, "Source", "Core")
BRIDGE_H = os.path.join(REPO, "Source", "iOS", "App", "Common", "Bridging", "DOLConfigBridge.h")
BRIDGE_MM = os.path.join(REPO, "Source", "iOS", "App", "Common", "Bridging", "DOLConfigBridge.mm")
LAUNCH_MM = os.path.join(REPO, "Source", "iOS", "App", "Common", "Services", "DolphinCoreService.mm")
UI_DIR = os.path.join(REPO, "Source", "iOS", "App", "Common", "UI")
IOS_ROOT = os.path.join(REPO, "Source", "iOS")

# Core subdirectories that are NOT compiled into the iOS app (desktop / other-host
# frontends). A Config symbol read ONLY here "does nothing" on iCube.
NON_IOS_CORE_DIRS = {
    "DolphinQt", "DolphinNoGUI", "DolphinTool", "MacUpdater",
    "WinUpdater", "UpdaterCommon",
}

WARNINGS = []


def warn(msg):
    WARNINGS.append(msg)


_LINE_COMMENT = re.compile(r"//[^\n]*")
_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.DOTALL)


def strip_comments(text):
    """Blank out // and /* */ comments, preserving newlines so line numbers hold.

    String-literal-aware enough for this codebase: we do NOT blank inside "..."
    because keys live in string literals. We only need to kill comment text so a
    `// DOLConfigBridge.mm` reference or a commented-out @AppStorage doesn't count.
    """
    def _blank(m):
        return re.sub(r"[^\n]", " ", m.group(0))
    # Block comments first (may span lines), then line comments.
    text = _BLOCK_COMMENT.sub(_blank, text)
    # Avoid nuking "http://" inside string literals: only strip // when not
    # immediately preceded by a quote-run on the same line. Cheap heuristic:
    # blank // ... unless the // is inside a quoted string. We approximate by
    # not stripping if an odd number of unescaped quotes precede on the line.
    out = []
    for line in text.split("\n"):
        idx = line.find("//")
        while idx != -1:
            before = line[:idx]
            if before.count('"') % 2 == 0:  # not inside a string literal
                line = before + " " * (len(line) - idx)
                break
            idx = line.find("//", idx + 2)
        out.append(line)
    return "\n".join(out)


def read(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except FileNotFoundError:
        warn("missing file (skipped): %s" % os.path.relpath(path, REPO))
        return None
    except OSError as exc:
        warn("could not read %s: %s" % (os.path.relpath(path, REPO), exc))
        return None


def rel(path):
    return os.path.relpath(path, REPO)


def line_of(text, idx):
    return text.count("\n", 0, idx) + 1


def walk(root, exts):
    out = []
    if not os.path.isdir(root):
        warn("missing dir (skipped): %s" % rel(root))
        return out
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            if any(name.endswith(e) for e in exts):
                out.append(os.path.join(dirpath, name))
    return out


# ---------------------------------------------------------------------------
# 1. Config definitions
# ---------------------------------------------------------------------------
# const Info<T> SYMBOL{{System::X, "Section", "Key"}, DEFAULT};
# Defaults may span lines and include #if defined(__APPLE__) branches.
DEF_HEAD = re.compile(
    r"\bconst\s+Info<\s*(?P<type>[^>]+?)\s*>\s+(?P<sym>[A-Z][A-Z0-9_]+)\s*\{",
    re.MULTILINE,
)
LOC_RE = re.compile(
    r"\{\s*System::(?P<system>\w+)\s*,\s*\"(?P<section>[^\"]*)\"\s*,\s*\"(?P<key>[^\"]*)\"\s*\}"
)


def _match_brace(text, open_idx):
    """Given index of an opening '{', return index just past the matching '}'."""
    depth = 0
    i = open_idx
    n = len(text)
    while i < n:
        c = text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def parse_config_defs():
    """Return dict sym -> {type, system, section, key, default, apple_default, file, line}."""
    defs = {}
    for path in sorted(walk(CONFIG_DIR, (".cpp",))):
        text = read(path)
        if text is None:
            continue
        for m in DEF_HEAD.finditer(text):
            sym = m.group("sym")
            typ = m.group("type").strip()
            open_brace = m.end() - 1  # the '{' captured at end of head
            end = _match_brace(text, open_brace)
            body = text[open_brace:end]
            loc = LOC_RE.search(body)
            if not loc:
                continue  # not a {System,section,key} Info — skip
            # Default = everything after the location tuple's closing brace, up to
            # the final closing brace of the whole Info initializer.
            loc_end = loc.end()
            default_raw = body[loc_end:].strip()
            default_raw = default_raw.lstrip(",").strip()
            default_raw = default_raw.rstrip("}").strip()
            apple_default = None
            plain_default = default_raw
            if "__APPLE__" in default_raw:
                # Split #if[def] ...__APPLE__... [&& (...)]\n APPLE [#else OTHER] #endif
                # The #if line may carry extra arch guards (&& (defined(__aarch64__)...));
                # consume the whole directive line, then capture the branch bodies.
                apple_m = re.search(
                    r"#if[^\n]*__APPLE__[^\n]*\n(?P<apple>.*?)\s*#else\s*(?P<other>.*?)\s*#endif",
                    default_raw, re.DOTALL,
                )
                if apple_m:
                    apple_default = " ".join(apple_m.group("apple").split())
                    plain_default = " ".join(apple_m.group("other").split())
                else:
                    apple_m2 = re.search(
                        r"#if[^\n]*__APPLE__[^\n]*\n(?P<apple>.*?)\s*#endif",
                        default_raw, re.DOTALL,
                    )
                    if apple_m2:
                        apple_default = " ".join(apple_m2.group("apple").split())
                        plain_default = ""
            else:
                plain_default = " ".join(default_raw.split())
            defs[sym] = {
                "type": typ,
                "system": loc.group("system"),
                "section": loc.group("section"),
                "key": loc.group("key"),
                "default": plain_default,
                "apple_default": apple_default,
                "file": rel(path),
                "line": line_of(text, m.start()),
            }
    return defs


# ---------------------------------------------------------------------------
# 2. Runtime consumers — Config::Get / Config::GetBase across Source/Core + Source/iOS
# ---------------------------------------------------------------------------
READ_RE = re.compile(r"\bConfig::Get(?:Base)?\s*\(\s*Config::([A-Z][A-Z0-9_]+)\b")
BRIDGE_MM_REL = rel(BRIDGE_MM)


def parse_reads():
    """Return dict sym -> list of (relpath, line, category).

    category in:
      'core-ios'   : Source/Core, compiled into the iOS app (real runtime read)
      'core-desktop': Source/Core under DolphinQt/etc — NOT in iOS build
      'ios-app'    : Source/iOS, NOT the bridge shim (real frontend read)
      'bridge'     : inside DOLConfigBridge.mm (a getter round-trip — NOT a consumer)
    A symbol is "functionally read" if it has any read whose category != 'bridge'
    and != 'core-desktop' (per the linter's intent: it must do something on iOS).
    """
    reads = {}
    for root in (CORE_ROOT, IOS_ROOT):
        for path in walk(root, (".cpp", ".h", ".mm", ".m")):
            text = read(path)
            if text is None:
                continue
            relpath = rel(path)
            if relpath == BRIDGE_MM_REL:
                category = "bridge"
            elif relpath.startswith(os.path.join("Source", "Core")):
                parts = relpath.split(os.sep)
                subdir = parts[2] if len(parts) > 2 else ""
                category = "core-desktop" if subdir in NON_IOS_CORE_DIRS else "core-ios"
            else:
                category = "ios-app"
            for m in READ_RE.finditer(text):
                reads.setdefault(m.group(1), []).append(
                    (relpath, line_of(text, m.start()), category)
                )
    return reads


# ---------------------------------------------------------------------------
# 3. Bridge accessors — DOLConfigBridge.{h,mm}
# ---------------------------------------------------------------------------
# Reads:  Config::Get(Config::SYM)  /  Config::GetBase(Config::SYM)
# Writes: Config::SetBase/SetBaseOrCurrent/SetCurrent(Config::SYM, ...)
BRIDGE_WRITE_RE = re.compile(
    r"\bConfig::Set(?:Base|BaseOrCurrent|Current)\s*\(\s*Config::([A-Z][A-Z0-9_]+)\b"
)
# ObjC class-method declaration: first selector segment.
#   + (RetType)methodName;            -> base "methodName"
#   + (RetType)name:(int)x sel2:(y);  -> base "name", full "name:sel2:"
OBJC_METHOD_DEF_RE = re.compile(
    r"^\s*\+\s*\([^)]*\)\s*([A-Za-z_][A-Za-z0-9_]*)", re.MULTILINE
)
# Full ObjC selector on a declaration line: capture every "label:" segment.
OBJC_SELECTOR_LINE_RE = re.compile(
    r"^\s*\+\s*\([^)]*\)\s*([A-Za-z_][A-Za-z0-9_]*)(.*)$", re.MULTILINE
)
NS_SWIFT_NAME_RE = re.compile(r"NS_SWIFT_NAME\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)")
SELECTOR_SEG_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\s*:")


def _selector_swift_bases(first_seg, rest):
    """From an ObjC selector, produce the set of Swift call base-names that could
    refer to it. Swift folds the first label into the method base when it reads as
    a preposition/noun, e.g.  gcPortDeviceForPort:  ->  Swift `gcPortDevice(forPort:)`.
    We can't know Swift's exact fold, so emit candidates:
      - the literal first segment (gcPortDeviceForPort -> too long, but also)
      - first segment (the ObjC base name) itself
      - first segment split at the last CamelCase 'For'/'With'/'At'/'To'/'By' boundary
    """
    cands = {first_seg}
    # split at common preposition boundaries that Swift turns into arg labels
    for prep in ("For", "With", "At", "To", "By", "In", "Of", "From"):
        i = first_seg.rfind(prep)
        if i > 0 and (i + len(prep)) < len(first_seg) and first_seg[i + len(prep)].isupper():
            cands.add(first_seg[:i])
    return cands


def parse_bridge():
    text_mm = read(BRIDGE_MM)
    text_h = read(BRIDGE_H)
    bridge = {
        "reads": {},   # sym -> [(line, ...)]
        "writes": {},  # sym -> [(line, ...)]
        "methods_decl": set(),  # base selectors declared in .h
        "methods_impl": set(),  # base selectors implemented in .mm
        "swift_names": set(),   # Swift base-names callable from Swift (folds + NS_SWIFT_NAME)
    }
    if text_mm is not None:
        text_mm_nc = strip_comments(text_mm)
        for m in READ_RE.finditer(text_mm_nc):
            bridge["reads"].setdefault(m.group(1), []).append(line_of(text_mm, m.start()))
        for m in BRIDGE_WRITE_RE.finditer(text_mm_nc):
            bridge["writes"].setdefault(m.group(1), []).append(line_of(text_mm, m.start()))
        for m in OBJC_METHOD_DEF_RE.finditer(text_mm_nc):
            bridge["methods_impl"].add(m.group(1))
    for src in (text_h, text_mm):
        if src is None:
            continue
        nc = strip_comments(src)
        for m in OBJC_SELECTOR_LINE_RE.finditer(nc):
            first = m.group(1)
            rest = m.group(2)
            if src is text_h:
                bridge["methods_decl"].add(first)
            bridge["swift_names"].update(_selector_swift_bases(first, rest))
        for m in NS_SWIFT_NAME_RE.finditer(nc):
            bridge["swift_names"].add(m.group(1))
    return bridge


# ---------------------------------------------------------------------------
# 4. UI usage — Swift + .mm under UI/
# ---------------------------------------------------------------------------
SWIFT_BRIDGE_CALL_RE = re.compile(r"\bDOLConfigBridge\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)")
OBJC_BRIDGE_CALL_RE = re.compile(r"\[\s*DOLConfigBridge\s+([A-Za-z_][A-Za-z0-9_]*)")
APPSTORAGE_RE = re.compile(r"@AppStorage\(\s*\"([^\"]+)\"")
SWIFT_UD_RE = re.compile(
    r"UserDefaults[^\n]*?\.(?:set|bool|integer|float|double|object|string|array|dictionary)"
    r"(?:\(\s*forKey:|ForKey:)\s*\"([^\"]+)\""
)


def parse_ui():
    """Return bridge-selectors called, AppStorage keys, swift UD keys (each w/ file:line)."""
    bridge_calls = {}   # selector -> [(relpath, line)]
    appstorage = {}     # key -> [(relpath, line)]
    swift_ud = {}       # key -> [(relpath, line)]
    for path in walk(UI_DIR, (".swift", ".mm")):
        raw = read(path)
        if raw is None:
            continue
        text = strip_comments(raw)
        relpath = rel(path)
        for m in SWIFT_BRIDGE_CALL_RE.finditer(text):
            bridge_calls.setdefault(m.group(1), []).append((relpath, line_of(text, m.start())))
        for m in OBJC_BRIDGE_CALL_RE.finditer(text):
            bridge_calls.setdefault(m.group(1), []).append((relpath, line_of(text, m.start())))
        for m in APPSTORAGE_RE.finditer(text):
            appstorage.setdefault(m.group(1), []).append((relpath, line_of(text, m.start())))
        if path.endswith(".swift"):
            for m in SWIFT_UD_RE.finditer(text):
                swift_ud.setdefault(m.group(1), []).append((relpath, line_of(text, m.start())))
    return bridge_calls, appstorage, swift_ud


# ---------------------------------------------------------------------------
# 5. ObjC NSUserDefaults keys across Source/iOS/**/*.mm
# ---------------------------------------------------------------------------
OBJC_UD_KEY_RE = re.compile(
    r"\b(?:bool|object|float|integer|double|string|array|dictionary|setBool|setObject|"
    r"setFloat|setInteger|setDouble|set)(?:Value)?(?:ForKey|forKey)\s*:\s*@\"([^\"]+)\""
)
REGISTER_DEFAULTS_RE = re.compile(r"registerDefaults\s*:\s*@\{(.*?)\}", re.DOTALL)
DICT_KEY_RE = re.compile(r"@\"([^\"]+)\"\s*:")


def parse_objc_ud():
    """Return dict key -> [(relpath, line, kind)] where kind in {read,write,register}."""
    keys = {}
    for path in walk(IOS_ROOT, (".mm",)):
        raw = read(path)
        if raw is None:
            continue
        text = strip_comments(raw)
        relpath = rel(path)
        for m in OBJC_UD_KEY_RE.finditer(text):
            key = m.group(1)
            frag = m.group(0)
            kind = "write" if frag.lower().startswith("set") else "read"
            keys.setdefault(key, []).append((relpath, line_of(text, m.start()), kind))
        for reg in REGISTER_DEFAULTS_RE.finditer(text):
            block = reg.group(1)
            base = reg.start(1)
            for km in DICT_KEY_RE.finditer(block):
                keys.setdefault(km.group(1), []).append(
                    (relpath, line_of(text, base + km.start()), "register")
                )
    return keys


# ---------------------------------------------------------------------------
# Launch overrides + reset coverage (DolphinCoreService + resetGameplayConfigKeys)
# ---------------------------------------------------------------------------
SETBASE_IFUNSPEC_RE = re.compile(
    r"\bSetBaseIfUnspecified\s*\(\s*Config::([A-Z][A-Z0-9_]+)\s*,\s*(.*?)\)\s*;",
    re.DOTALL,
)
PLAIN_SETBASE_RE = re.compile(
    r"\bConfig::SetBase(?:OrCurrent|Current)?\s*\(\s*Config::([A-Z][A-Z0-9_]+)\s*,\s*(.*?)\)\s*;",
    re.DOTALL,
)
DEL_RE = re.compile(r"\bdel\s*\(\s*Config::([A-Z][A-Z0-9_]+)\s*\)")


def parse_launch_overrides():
    """sym -> (value, relpath, line) from SetBaseIfUnspecified + plain SetBase in launch."""
    overrides = {}
    text = read(LAUNCH_MM)
    if text is None:
        return overrides
    for m in SETBASE_IFUNSPEC_RE.finditer(text):
        sym = m.group(1)
        val = " ".join(m.group(2).split())
        overrides[sym] = (val, rel(LAUNCH_MM), line_of(text, m.start()))
    for m in PLAIN_SETBASE_RE.finditer(text):
        sym = m.group(1)
        if sym in overrides:
            continue
        val = " ".join(m.group(2).split())
        overrides[sym] = (val, rel(LAUNCH_MM), line_of(text, m.start()))
    return overrides


# Two write forms:
#   Config::SetBase/SetBaseOrCurrent/SetCurrent(Config::SYM, ...)
#   Config::Set(Config::LayerType::X, Config::SYM, ...)   <- per-layer (auto controllers)
ANY_WRITE_RE = re.compile(
    r"\bConfig::Set(?:Base|BaseOrCurrent|Current)\s*\(\s*Config::([A-Z][A-Z0-9_]+)\b"
)
LAYER_WRITE_RE = re.compile(
    r"\bConfig::Set\s*\(\s*Config::LayerType::\w+\s*,\s*Config::([A-Z][A-Z0-9_]+)\b"
)


def parse_all_config_writes():
    """Repo-wide: sym -> {relpath: line} for every Config::Set*(Config::SYM).

    Catches both the SetBase* family and the per-layer Config::Set(LayerType, SYM, ..)
    form used by automatic controllers (e.g. AutoIRController writes GFX_EFB_SCALE this
    way). Used to detect competing writers across independent subsystems.
    """
    writes = {}
    for root in (CORE_ROOT, IOS_ROOT):
        for path in walk(root, (".cpp", ".mm", ".m")):
            text = read(path)
            if text is None:
                continue
            relpath = rel(path)
            text_nc = strip_comments(text)
            for rx in (ANY_WRITE_RE, LAYER_WRITE_RE):
                for m in rx.finditer(text_nc):
                    sym = m.group(1)
                    writes.setdefault(sym, {})
                    writes[sym].setdefault(relpath, line_of(text, m.start()))
    return writes


def parse_reset_coverage():
    """Set of symbols del()'d inside resetGameplayConfigKeys."""
    covered = set()
    text = read(BRIDGE_MM)
    if text is None:
        return covered
    start = text.find("resetGameplayConfigKeys")
    if start < 0:
        warn("resetGameplayConfigKeys not found in DOLConfigBridge.mm")
        return covered
    # scope to that method body: from its opening brace to matching close.
    brace = text.find("{", start)
    if brace < 0:
        return covered
    end = _match_brace(text, brace)
    body = text[brace:end]
    for m in DEL_RE.finditer(body):
        covered.add(m.group(1))
    return covered


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
def near_misses(key, pool):
    """Return keys in pool that are close to `key` (edit-distance-ish / substring)."""
    out = []
    for other in pool:
        if other == key:
            continue
        if key in other or other in key:
            out.append(other)
            continue
        # normalized compare: drop underscores, lowercase
        a = key.replace("_", "").lower()
        b = other.replace("_", "").lower()
        if a == b or (len(a) > 4 and (a in b or b in a)):
            out.append(other)
            continue
        if _lev(key, other) <= 2 and abs(len(key) - len(other)) <= 2:
            out.append(other)
    return sorted(set(out))


def _lev(a, b):
    if a == b:
        return 0
    la, lb = len(a), len(b)
    if abs(la - lb) > 3:
        return 99
    prev = list(range(lb + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[lb]


def selector_to_symcandidate(sel):
    """Heuristic: bridge selector camelCase -> guess if it touches config (unused now)."""
    return sel


PERF_KEYS = [
    "MAIN_CPU_CORE", "MAIN_CPU_THREAD", "MAIN_FASTMEM", "MAIN_FASTMEM_ARENA",
    "MAIN_FAST_DISC_SPEED", "MAIN_DSP_THREAD", "MAIN_SYNC_GPU", "MAIN_ACCURATE_NANS",
    "GFX_HACK_SKIP_EFB_COPY_TO_RAM", "GFX_HACK_SKIP_XFB_COPY_TO_RAM",
    "GFX_HACK_IMMEDIATE_XFB", "GFX_HACK_VI_SKIP", "GFX_HACK_VI_SKIP_MODE",
    "GFX_WAIT_FOR_SHADERS_BEFORE_STARTING", "GFX_ASYNC_PRESENT",
    "GFX_SHADER_COMPILER_THREADS", "GFX_SHADER_PRECOMPILER_THREADS",
    "MAIN_USE_GAME_COVERS",
]


def hr(title, char="="):
    return "\n%s\n%s %s\n%s" % (char * 78, "#", title, char * 78)


def main():
    print("icube_config_lint — repo:", REPO)

    defs = parse_config_defs()
    reads_by_sym = parse_reads()
    bridge = parse_bridge()
    bridge_calls, appstorage, swift_ud = parse_ui()
    objc_ud = parse_objc_ud()
    launch = parse_launch_overrides()
    reset_cov = parse_reset_coverage()
    cross_writes = parse_all_config_writes()

    print("\nParsed: %d Config defs | %d symbols read (Core+iOS) | "
          "%d bridge writers / %d bridge readers | %d launch overrides | "
          "%d reset-covered | %d @AppStorage keys | %d ObjC UD keys"
          % (len(defs), len(reads_by_sym), len(bridge["writes"]), len(bridge["reads"]),
             len(launch), len(reset_cov), len(appstorage), len(objc_ud)))

    dangling = []      # hard dangling: no functional read anywhere
    ios_dangling = []  # read ONLY by desktop (DolphinQt) — does nothing on iOS
    ud_mismatch = []
    competing = []

    # set of symbols WRITTEN by the iCube frontend (bridge setters OR launch overrides)
    written_syms = set(bridge["writes"].keys()) | set(launch.keys())

    def _written_where(sym):
        where = []
        if sym in bridge["writes"]:
            where.append("bridge setter @ %s:%s" % (BRIDGE_MM_REL, bridge["writes"][sym][0]))
        if sym in launch:
            where.append("launch override @ %s:%s" % (launch[sym][1], launch[sym][2]))
        return where

    # ----- DANGLING CONFIG ----------------------------------------------------
    # Functional read = Config::Get OUTSIDE the bridge shim (the bridge getter just
    # round-trips a value back to the UI; it is not a consumer). A symbol read only
    # in the bridge, or not read at all, does nothing at runtime.
    for sym in sorted(written_syms):
        reads = reads_by_sym.get(sym, [])
        functional = [r for r in reads if r[2] in ("core-ios", "ios-app")]
        desktop_only = [r for r in reads if r[2] == "core-desktop"]
        if functional:
            continue  # genuinely consumed — fine
        if desktop_only:
            # read only by DolphinQt/etc — compiles but inert in the iOS build
            ios_dangling.append((sym, _written_where(sym),
                                 ["%s:%s" % (r[0], r[1]) for r in desktop_only]))
        else:
            # no functional read anywhere (bridge-getter round-trip, if any, doesn't count)
            bridge_only = [r for r in reads if r[2] == "bridge"]
            note = (" (only read = bridge getter round-trip)" if bridge_only else "")
            dangling.append((sym, _written_where(sym), sym in defs, note))

    # ----- NSUserDefault MISMATCH --------------------------------------------
    # Swift-side keys: @AppStorage + Swift UserDefaults string keys.
    # ObjC-side keys:  NSUserDefaults reads/writes/register in *.mm.
    swift_keys = set(appstorage.keys()) | set(swift_ud.keys())
    objc_keys = set(objc_ud.keys())
    objc_prefixes = sorted(objc_keys)

    def covered_by_objc(k):
        if k in objc_keys:
            return True
        # ObjC may build keys with a known prefix (e.g. adaptive_clock_cpu_<id>).
        for ok in objc_keys:
            if ok.endswith("_") and k.startswith(ok):
                return True
        return False

    # Swift key never seen on ObjC side (with same string)
    for k in sorted(swift_keys):
        if not covered_by_objc(k):
            nm = near_misses(k, objc_keys)
            locs = appstorage.get(k, []) + swift_ud.get(k, [])
            ud_mismatch.append(("swift-only", k, locs, nm))

    # ObjC key never seen on Swift side
    for k in sorted(objc_keys):
        if k in swift_keys:
            continue
        # prefix family (built strings) — skip the synthesized members
        if any(k.startswith(p) and p.endswith("_") and p != k for p in objc_prefixes):
            continue
        nm = near_misses(k, swift_keys)
        # Only a "mismatch" worth flagging if a near-miss exists on the Swift side,
        # OR the key looks like a user-facing setting (heuristic: present in both
        # read & some Swift-ish context). Pure ObjC-internal keys (schema versions,
        # caches) are expected to be ObjC-only — list those as info, not mismatch.
        locs = objc_ud.get(k, [])
        kinds = {x[2] for x in locs}
        ud_mismatch.append(("objc-only", k, locs, nm, kinds))

    # ----- MISSING HOOK -------------------------------------------------------
    # (a) bridge accessor (Config read/written) referenced by NO UI selector.
    bridge_syms = set(bridge["reads"]) | set(bridge["writes"])
    ui_selectors = set(bridge_calls.keys())
    # Build sym -> selectors heuristic: we can't map sym->selector textually, so
    # instead flag bridge SELECTORS declared but never called by UI.
    declared = bridge["methods_decl"] or bridge["methods_impl"]
    uncalled_selectors = sorted(
        s for s in declared
        if s not in ui_selectors
        and not s.startswith("init")
        and s not in {"load", "save", "synchronize"}
    )
    # (b) UI calls a bridge selector that doesn't exist in bridge.
    # Match against base impl/decl names AND the Swift-fold/NS_SWIFT_NAME resolved
    # set, so Swift's argument-label folding (gcPortDevice(forPort:) ->
    # gcPortDeviceForPort:) and explicit NS_SWIFT_NAME renames don't false-positive.
    impl = bridge["methods_impl"] | bridge["methods_decl"] | bridge["swift_names"]
    impl_lc = {x.lower() for x in impl}

    def call_resolves(s):
        if s in impl:
            return True
        sl = s.lower()
        # Swift may keep a preposition in the base and drop the first arg label,
        # e.g. setWiimoteSourceFor(_:source:) -> ObjC setWiimoteSourceForIndex:...
        # Accept if the call name is a prefix of a known base selector (or vice-versa).
        for cand in impl_lc:
            if (cand.startswith(sl) or sl.startswith(cand)) and abs(len(cand) - len(sl)) <= 8:
                return True
        return False

    ui_calls_missing = sorted(s for s in ui_selectors if not call_resolves(s))
    # (c) bridge references a Config symbol that doesn't exist (typo).
    bridge_unknown_syms = sorted(s for s in bridge_syms if s not in defs)
    # launch references unknown symbol
    launch_unknown = sorted(s for s in launch if s not in defs)

    # ----- COMPETING WRITERS --------------------------------------------------
    # The real competition risk is a Config symbol written by >1 INDEPENDENT
    # subsystem that BOTH ship in the iOS build (e.g. the manual IR picker AND
    # AutoIRController both writing GFX_EFB_SCALE). Collapse all the iCube frontend
    # writers (everything under Source/iOS — bridge, launch, every settings VC) into
    # ONE logical "iCube-frontend" source: a user picker + its bridge setter is
    # normal layering, not competition. Desktop-only DolphinQt/etc writers don't
    # compile into iOS, so they can't compete there — drop them.
    def _logical_source(relpath):
        if relpath.startswith(os.path.join("Source", "iOS")):
            return "iCube-frontend"
        parts = relpath.split(os.sep)
        subdir = parts[2] if len(parts) > 2 else ""
        if subdir in NON_IOS_CORE_DIRS:
            return None  # desktop — not in iOS build
        return relpath  # a distinct Core/VideoCommon/etc subsystem

    for sym, files in sorted(cross_writes.items()):
        logical = {}
        for f, ln in files.items():
            src = _logical_source(f)
            if src is None:
                continue
            logical.setdefault(src, []).append("%s:%s" % (f, ln))
        if len(logical) > 1:
            detail = []
            for src in sorted(logical):
                detail.append("%s  [%s]" % (logical[src][0], src))
            competing.append((sym, len(logical), detail))

    # ===== PRINT ==============================================================
    print(hr("1. DANGLING CONFIG  (written by iCube frontend, NEVER Config::Get-read)"))
    print("   Severity: CRITICAL — the setting does nothing at runtime.")
    if not dangling:
        print("   none found.")
    for sym, where, known, note in dangling:
        d = defs.get(sym)
        keyinfo = ("[%s/%s \"%s\"]" % (d["system"], d["section"], d["key"])) if d else "[UNKNOWN SYMBOL]"
        print("   - %-40s %s" % (sym, keyinfo))
        for w in where:
            print("       written: %s" % w)
        print("       read:    (no functional Config::Get outside the bridge)%s" % note)

    print(hr("1b. iOS-DANGLING  (written by iCube, read ONLY by desktop DolphinQt/etc.)", "-"))
    print("   Severity: HIGH — compiles, but does nothing in the iOS build.")
    if not ios_dangling:
        print("   none found.")
    for sym, where, desktop in ios_dangling:
        d = defs.get(sym)
        keyinfo = ("[%s/%s \"%s\"]" % (d["system"], d["section"], d["key"])) if d else "[UNKNOWN]"
        print("   - %-40s %s" % (sym, keyinfo))
        for w in where:
            print("       written: %s" % w)
        print("       desktop-only read: %s" % ", ".join(desktop[:4]))

    print(hr("2. NSUserDefault KEY MISMATCH  (Swift <-> ObjC string drift)"))
    print("   Severity: HIGH if a near-miss exists (typo/drift). INFO if simply one-sided.")
    real_mismatch = 0
    swift_only = [x for x in ud_mismatch if x[0] == "swift-only"]
    objc_only = [x for x in ud_mismatch if x[0] == "objc-only"]
    print("\n   -- Swift-side keys NOT read with same string on ObjC/runtime side --")
    if not swift_only:
        print("      none.")
    for _t, k, locs, nm in swift_only:
        loc0 = ("%s:%s" % (locs[0][0], locs[0][1])) if locs else "?"
        tag = ("  near-miss on ObjC: %s" % ", ".join(nm)) if nm else "  (no ObjC counterpart)"
        sev = "HIGH" if nm else "INFO"
        if nm:
            real_mismatch += 1
        print("      [%-4s] %-34s @ %s%s" % (sev, k, loc0, tag))
    print("\n   -- ObjC-side keys NOT present on Swift side --")
    if not objc_only:
        print("      none.")
    for _t, k, locs, nm, kinds in objc_only:
        loc0 = ("%s:%s" % (locs[0][0], locs[0][1])) if locs else "?"
        sev = "HIGH" if nm else "info"
        if nm:
            real_mismatch += 1
        tag = ("  near-miss on Swift: %s" % ", ".join(nm)) if nm else "  (ObjC-internal; expected one-sided)"
        print("      [%-4s] %-34s @ %s  {%s}%s"
              % (sev, k, loc0, ",".join(sorted(kinds)), tag))

    print(hr("3. MISSING / TYPO HOOK"))
    print("   (a) Bridge selectors declared/implemented but called by NO UI file:")
    if not uncalled_selectors:
        print("       none.")
    else:
        for s in uncalled_selectors:
            print("       - %s" % s)
    print("   (b) UI calls a DOLConfigBridge selector that doesn't exist in the bridge:")
    if not ui_calls_missing:
        print("       none.")
    else:
        for s in ui_calls_missing:
            locs = bridge_calls.get(s, [])
            loc0 = ("%s:%s" % (locs[0][0], locs[0][1])) if locs else "?"
            print("       - %-30s called @ %s" % (s, loc0))
    print("   (c) Bridge references a Config symbol that doesn't exist (typo):")
    if not bridge_unknown_syms and not launch_unknown:
        print("       none.")
    for s in bridge_unknown_syms:
        print("       - %s (in DOLConfigBridge.mm)" % s)
    for s in launch_unknown:
        print("       - %s (in DolphinCoreService.mm launch)" % s)

    print(hr("4. DUPLICATE / COMPETING WRITERS"))
    print("   Severity: MEDIUM — a Config symbol written by >1 INDEPENDENT subsystem")
    print("   that both ship in iOS. All Source/iOS writers collapse to 'iCube-frontend'")
    print("   (user picker + its bridge setter = normal layering). DolphinQt-only dropped.")
    print("   NOTE: many Core-side writers are *intentional* runtime overrides (boot-time")
    print("   per-game INI, fast-forward, netplay, achievements). The high-signal case is")
    print("   an AUTO controller competing with a USER setpoint (e.g. GFX_EFB_SCALE).")
    if not competing:
        print("   none found.")
    for sym, n, detail in competing:
        print("   - %-38s written by %d independent sources:" % (sym, n))
        for d in detail:
            print("       %s" % d)

    print(hr("5. DEFAULTS TABLE  (perf-relevant keys)"))
    print("   compiled-default | apple-default | launch-override | in-reset-list?  — flag DISAGREE")
    print("   %-38s %-14s %-12s %-16s %-9s %s"
          % ("SYMBOL", "compiled", "apple", "launch", "in-reset", "flag"))
    disagreements = 0
    for sym in PERF_KEYS:
        d = defs.get(sym)
        if not d:
            print("   %-38s  (NO DEF FOUND)" % sym)
            continue
        comp = d["default"] or "-"
        apple = d["apple_default"] or "-"
        lov = launch.get(sym)
        launch_val = lov[0] if lov else "-"
        in_reset = "yes" if sym in reset_cov else "NO"
        # A disagreement only exists when the launch override VALUE actually differs
        # from the effective compiled default. A redundant SetBaseIfUnspecified(X, false)
        # where the default is already false is NOT a disagreement, in or out of reset.
        # NOTE: runtime-valued launch overrides (fastmemAvailable, threads) can't be
        # evaluated statically — they're flagged as "unverifiable" rather than asserted.
        eff_default = apple if apple != "-" else comp
        runtime_valued = bool(re.search(r"[a-z]", launch_val)) and launch_val not in (
            "true", "false") and not launch_val.startswith(("TriState::", "PowerPC::"))
        differs = bool(lov) and _norm(launch_val) != _norm(eff_default)
        flag = ""
        if lov and runtime_valued:
            flag = "launch value computed at runtime — disagreement UNVERIFIABLE (review)"
        elif differs and sym in reset_cov:
            flag = "reset DE-TUNES: deletes key -> compiled default, discarding launch override"
            disagreements += 1
        elif differs and in_reset == "NO":
            flag = "reset GAP: launch-tuned but reset won't clear a bad user override"
            disagreements += 1
        print("   %-38s %-14s %-12s %-16s %-9s %s"
              % (sym, comp[:14], apple[:12], launch_val[:16], in_reset, flag))

    # ===== EXIT ===============================================================
    print(hr("SUMMARY", "-"))
    if WARNINGS:
        print("warnings:")
        for w in WARNINGS:
            print("   ! %s" % w)
    n_dangling = len(dangling) + len(ios_dangling)
    print("DANGLING (hard): %d | iOS-dangling: %d | UD real-mismatch: %d | "
          "missing-hook: %d | competing: %d | defaults-disagree: %d"
          % (len(dangling), len(ios_dangling), real_mismatch,
             len(ui_calls_missing) + len(bridge_unknown_syms) + len(launch_unknown),
             len(competing), disagreements))

    fail = bool(dangling) or bool(ios_dangling) or real_mismatch > 0 \
        or bool(ui_calls_missing) or bool(bridge_unknown_syms) or bool(launch_unknown)
    if fail:
        print("RESULT: FAIL (dangling/mismatch/missing-hook found) — exit 1")
        return 1
    print("RESULT: PASS — exit 0")
    return 0


def _norm(v):
    return v.strip().lower().rstrip(";").strip()


if __name__ == "__main__":
    sys.exit(main())
