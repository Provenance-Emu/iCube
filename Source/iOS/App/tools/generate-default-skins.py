#!/usr/bin/env python3
"""Author iCube's four default pads, then bake their classic fallback bundles.

Geometry is a transcription of TouchOverlayDefaults, not a new controller layout.
The runtime prepares the legacy reference unit for each environment. Exact legacy
canvas margins and GameCube shoulder floors also need host preparation (the
current format has no unscaled length or cross-axis canvas expression). All editable
control groups keep TouchOverlayGroup.rawValue IDs; every descendant is relative
to its parent so moving/resizing a migrated group moves/resizes all its controls.

Run with --sources-only to author JSON without invoking skinkit-bake.
SKINKIT_PATH / SKINKIT_BAKE may select another checkout / prebuilt baker.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
from zipfile import ZipFile

APP = Path(__file__).resolve().parents[1]
ROOT = APP / "DolphiniOS/Resources/DefaultSkins"
SKINKIT = Path(os.environ.get("SKINKIT_PATH", str(APP / "build-Xcode-ios/SourcePackages/checkouts/SkinKit"))).expanduser()
KINDS = ("gameCube", "wiiRemote", "wiiRemoteSideways", "wiiClassic")
# TouchOverlayGroupViews' knob frame and TouchOverlayInput's analog reach.
# Keep these explicit: std.stick defaults (0.5 / 0.35) change legacy behavior.
STICK_KNOB_FRACTION = 0.4
STICK_TRAVEL_FRACTION = 1 / 3


def sum_(*terms):
    terms = [term for term in terms if term != 0]
    return terms[0] if len(terms) == 1 else {"sum": terms} if terms else 0


def max_(*terms):
    return {"max": list(terms)}


def safe(edge):
    return {"safe": edge}


def fixed(points):
    # Legacy edge padding, bottom guard and IR margin are CANVAS points, not u.
    return points  # Pending unscaled-length capability; see fixed() call sites.


def frac(value):
    return {"frac": value}


def frame(x, y, w, h):
    return {"frame": [x, y, w, h]}


def relative_frame(rect, size):
    x, y, w, h = rect
    return frame(frac(x / size[0]), frac(y / size[1]), frac(w / size[0]), frac(h / size[1]))


def linear(top, bottom, gloss=False):
    return {"type": "linear", "start": [0.5, 0], "end": [0.5, 0.5 if gloss else 1],
            "stops": [[top, 0], [bottom, 1]]}


def solid(color, opacity=1):
    return {"type": "solid", "color": color, "opacity": opacity}


def shadow(color, opacity, radius, y=0):
    return {"type": "shadow", "color": color, "opacity": opacity,
            "radius": fixed(radius), "offset": [0, fixed(y)]}


def shape(kind, fills=(), strokes=(), **kwargs):
    return {"type": "shape", "shape": {"kind": kind}, "fills": list(fills),
            "strokes": list(strokes), **kwargs}


# These paths intentionally do NOT use std.kidneyButton / std.triggerBar:
# std's bean differs from KidneyShape, and its trapezoid tapers the opposite edge.
KIDNEY = {"kind": "path", "box": [0, 0, 1, 1],
          "d": "M.12 .55 C.05 .05 .60 -.08 .88 .45 C1.05 .62 .50 1.08 .12 .55 Z"}
BAR = {"kind": "path", "box": [0, 0, 1, 1], "d": "M0 0 L1 0 L.86 1 L.14 1 Z"}


def palette(kind):
    if kind == "gameCube":
        return {"top": "#755CA8", "bottom": "#3D2B66", "glow": "#9E7AF2", "label": "#FFFFFFE6"}
    return {"top": "#FFFFFF", "bottom": "#DBDBDB", "glow": "#529EFF", "label": "#000000"}


def button_art(id, kind, trigger=False):
    suffix = id.split(".")[-1]
    top, bottom = "$top", "$bottom"
    if kind == "gameCube":
        top, bottom = {"a": ("#52DB66", "#1A8C38"), "b": ("#F24D47", "#A6141A"),
                       "start": ("#FAFAFA", "#CCCCCC")}.get(suffix, (top, bottom))
    if suffix in ("x", "y") and kind == "gameCube":
        outline = KIDNEY
    elif suffix in ("z", "l", "r", "zl", "zr"):
        outline = BAR
    else:
        outline = {"kind": "capsule" if suffix in ("start", "minus", "plus", "home", "mic") else "ellipse"}
    label = {"one": "1", "two": "2", "minus": "−", "plus": "+", "home": "⌂"}.get(suffix, suffix.upper())
    layers = []
    for pressed in (False, True):
        body = shape("ellipse", [linear(bottom, top) if pressed else linear(top, bottom),
                                  linear("#FFFFFF1A" if pressed else "#FFFFFF57", "#FFFFFF00", gloss=True)],
                     [{"color": "$glow" if kind != "gameCube" else "#FFFFFF",
                       "opacity": (0.95 if pressed else 0.6) if kind != "gameCube" else 0.5,
                       "width": fixed(2 if pressed else 1)}])
        body["shape"] = outline
        layers.append({"type": "group", "id": id + (".pressed" if pressed else ".rest"),
                       "role": "highlight" if pressed else "base",
                       "effects": [shadow("#000000", 0.35, 1 if pressed else 3, 0 if pressed else 2),
                                   shadow("$glow", 0.85 if pressed else 0.35, 8 if pressed else 4)],
                       "children": [body, {"type": "text", "text": label,
                                           "font": {"size": fixed(11), "weight": "bold"},
                                           "color": "$label", "opacity": 1 if kind == "gameCube" else 0.55,
                                           "align": "center"}]})
    return {"type": "control", "id": id, "kind": "trigger" if trigger else "button",
            "input": "mic" if suffix == "mic" else suffix,
            "children": layers,
            "states": {"pressed": {"scale": 0.92, "patch": [
                {"target": "#" + id + ".rest", "visible": False}]}}}


def dpad_art(id, side):
    children = [shape("ellipse", [{"type": "radial", "center": [0.4, 0.34], "radius": 90 / 128,
                                  "stops": [["$top", 0.9, 2 / (side * 90 / 128)], ["$bottom", 0.95, 1]]}],
                      [{"color": "$glow", "opacity": 0.55, "width": fixed(2), "align": "inner"}])]
    # The outer silhouette of the two rounded rectangles in CrossShape is a
    # rounded plus with sharp concave corners; retain its full-frame gradient.
    cross = shape("cross", [linear("$bottom", "$top")], layout={"inset": frac(18 / 128)})
    cross["shape"].update(armRatio=0.34, cornerRadius=fixed(6))
    children.append(cross)
    paths = {"up": "M.5 0 L1 1 L0 1 Z", "down": "M.5 1 L0 0 L1 0 Z",
             "left": "M0 .5 L1 0 L1 1 Z", "right": "M1 .5 L0 1 L0 0 Z"}
    states = {}
    directions = {
        "up": (0, -34 / 128, 0, 1),
        "down": (0, 34 / 128, 0, -1),
        "left": (-34 / 128, 0, 1, 0),
        "right": (34 / 128, 0, -1, 0),
    }
    for direction, (dx, dy, shadow_x, shadow_y) in directions.items():
        rest_id = id + "." + direction + ".rest"
        lit_id = id + "." + direction + ".lit"
        for lit in (False, True):
            scale = 1.1 if lit else 1
            arrow = shape("path", [solid("$glow") if lit else solid("#FFFFFF", 0.85)],
                          id=lit_id if lit else rest_id, opacity=0 if lit else 1,
                          effects=[shadow("#000000", 0.3, scale)])
            arrow["effects"][0]["offset"] = [fixed(shadow_x * scale), fixed(shadow_y * scale)]
            arrow["shape"].update(d=paths[direction], box=[0, 0, 1, 1])
            arrow["layout"] = {"size": {"width": frac(20 / 128 * scale), "height": frac(20 / 128 * scale)},
                               "anchor": {"to": "parent", "x": "center", "y": "center"},
                               "offset": {"x": frac(dx), "y": frac(dy)}}
            children.append(arrow)
        states["pressed." + direction] = {"patch": [
            {"target": "#" + rest_id, "opacity": 0},
            {"target": "#" + lit_id, "opacity": 1},
        ]}
    return {"type": "control", "id": id, "kind": "dpad",
            "input": {d: d for d in ("up", "down", "left", "right")},
            "effects": [shadow("#000000", 0.4, 3, 2)], "states": states, "children": children}


def stick_art(id, input, side):
    base = shape("ellipse", [{"type": "radial", "center": [0.5, 0.5], "radius": 70 / side,
                              "stops": [["#000000", 0.35, 2 / 70], ["$glow", 0.28, 1]]}], role="base")
    gate = shape("polygon", strokes=[{"color": "$glow", "opacity": 0.6, "width": fixed(2)}],
                 layout={"inset": fixed(6)}, role="base")
    gate["shape"].update(sides=8, rotation=-22.5)
    ring = shape("ellipse", strokes=[{"color": "$glow", "opacity": 0.9, "width": fixed(3)}],
                 id=id + ".ring", opacity=0, role="base", effects=[shadow("$glow", 0.9, 8)])
    knob = shape("ellipse", [{"type": "radial", "center": [0.38, 0.3], "radius": 40 / (side * STICK_KNOB_FRACTION),
                              "stops": [["$top", 1 / 40], ["$bottom", 1]]}],
                 [{"color": "#000000", "opacity": 0.25, "width": fixed(1.5)}], role="knob",
                 layout={"size": {"width": frac(STICK_KNOB_FRACTION), "height": frac(STICK_KNOB_FRACTION)},
                         "anchor": {"x": "center", "y": "center", "to": "parent"}},
                 effects=[shadow("#000000", 0.5, 4, 2)])
    return {"type": "control", "id": id, "kind": "thumbstick", "input": input, "travel": frac(STICK_TRAVEL_FRACTION),
            "children": [base, gate, ring, knob],
            "states": {"pressed": {"patch": [{"target": "#" + id + ".ring", "opacity": 1}]}}}


def control(id, rect, group_size, kind, type="button", input=None):
    if type == "dpad":
        node = dpad_art(id, rect[2])
    elif type == "thumbstick":
        node = stick_art(id, input, rect[2])
    else:
        node = button_art(id, kind, type == "trigger")
    node["layout"] = relative_frame(rect, group_size)
    return node


def group(id, size, x, y, controls, kind, landscape=None, visible=None):
    node = {"type": "group", "id": id,
            "layout": {"size": {"width": size[0], "height": size[1]},
                       "anchor": {"to": "canvas", "x": "leading", "y": "bottom"},
                       "offset": {"x": x, "y": y}},
            "children": [control(cid, rect, size, kind, *args) for cid, rect, *args in controls]}
    if landscape:
        node["when"] = [{"orientation": "landscape", "layout": {"offset": {"x": landscape[0], "y": landscape[1]}}}]
    if visible:
        node["visible"] = visible
    return node


def single(gid, cid, side, x, y, kind, type="button", input=None, landscape=None, visible=None):
    size = (side, side) if isinstance(side, (int, float)) else side
    args = [type, input] if input else [type]
    return group(gid, size, x, y, [(cid, (0, 0, *size), *args)], kind, landscape, visible)


def computed_edges():
    # x is a leading edge measured from the canvas. y is negative lift from bottom.
    left = sum_(max_(safe("left"), fixed(8)), fixed(8))
    right_inset = sum_(max_(safe("right"), fixed(8)), fixed(8))
    bottom_inset = sum_(max_(safe("bottom"), fixed(8)), fixed(6))
    return left, right_inset, bottom_inset


def build(kind):
    left, right, bottom = computed_edges()
    # Guide insets let us subtract safe area / fixed canvas margins without
    # requiring a negative-safe operator in ordinary edge-anchored groups.
    guides = [{"type": "group", "id": "edges", "layout": {"inset": {
        "left": left, "right": right, "bottom": bottom, "top": 0}}}]
    groups = []

    def add(gid, size, x, lift, controls, edge="leading", diagonal=0, landscape_lift=None, visible=None):
        node = group(gid, size, x, -lift, controls, kind, visible=visible)
        node["layout"]["anchor"]["to"] = "#edges"
        node["layout"]["anchor"]["x"] = edge
        if diagonal or landscape_lift is not None:
            node["when"] = [{"orientation": "landscape", "layout": {"offset": {
                "x": sum_(x, diagonal), "y": -(landscape_lift if landscape_lift is not None else lift)}}}]
        groups.append(node)
        return node

    def one(gid, cid, side, x=0, lift=0, edge="leading", type="button", input=None, **kwargs):
        size = (side, side) if isinstance(side, (int, float)) else side
        return add(gid, size, x, lift, [(cid, (0, 0, *size), type, input)], edge, **kwargs)

    if kind == "gameCube":
        one("gcMainStick", "gc.mainStick", 132, lift=112, type="thumbstick", input="leftThumbstick")
        one("gcDpad", "gc.dpad", 104, x=14, type="dpad", diagonal=70)
        one("gcCStick", "gc.cStick", 100, x=-35, edge="trailing", type="thumbstick", input="rightThumbstick", diagonal=-70)
        # A centre (84,86); B (0,86), X (126,48), Y (49,0).
        add("gcFaceButtons", (170, 134), 0, 108, [("gc.a", (48, 50, 72, 72)),
            ("gc.b", (0, 86, 48, 48)), ("gc.x", (126, 48, 44, 64)), ("gc.y", (49, 0, 64, 44))], "trailing")
        # Bottom-up shoulder bands. The host must apply the legacy picture-floor
        # max and canvas clamp; Skin2 lengths cannot read width on the y axis.
        one("gcLeftShoulder", "gc.l", (96, 44), lift=252, type="trigger")
        add("gcRightShoulder", (96, 96), 0, 250,
            [("gc.r", (0, 0, 96, 44), "trigger"), ("gc.z", (8, 52, 80, 44))], "trailing")
        one("gcStart", "gc.start", (70, 44), edge="center")
        one("gcMicrophone", "gc.mic", (70, 44), lift=52, edge="center", visible={"flag": "microphone"})
    elif kind == "wiiRemote":
        # The pointer must be first so physical controls take precedence above it.
        groups.append({"type": "group", "id": "wiiIRPad", "layout": {"inset": fixed(24)}, "children": [
            {"type": "control", "id": "wii.ir", "kind": "touchSurface", "input": "pointer",
             "layout": frame(0, 0, frac(1), frac(1))}]})
        one("nunchukStick", "nunchuk.stick", 132, type="thumbstick", input="leftThumbstick", diagonal=70)
        one("wiiDpad", "wii.dpad", 104, lift=140, type="dpad")
        one("nunchukZ", "nunchuk.z", (80, 44), lift=252)
        one("nunchukC", "nunchuk.c", 48, x=88, lift=250)
        add("wiiAB", (72, 136), 0, 0, [("wii.b", (8, 0, 56, 56)), ("wii.a", (0, 64, 72, 72))], "trailing")
        add("wiiOneTwo", (48, 104), -80, 0, [("wii.one", (0, 0, 48, 48)), ("wii.two", (0, 56, 48, 48))], "trailing")
        add("wiiMinusPlusHome", (148, 44), 0, 144,
            [("wii.minus", (0, 0, 44, 44)), ("wii.home", (52, 0, 44, 44)), ("wii.plus", (104, 0, 44, 44))], "trailing")
    elif kind == "wiiClassic":
        one("classicLeftStick", "classic.leftStick", 124, type="thumbstick", input="leftThumbstick", diagonal=70)
        one("classicRightStick", "classic.rightStick", 124, edge="trailing", type="thumbstick", input="rightThumbstick", diagonal=-70)
        one("classicDpad", "classic.dpad", 104, lift=132, type="dpad")
        add("classicFaceButtons", (152, 152), 0, 132, [("classic.x", (52, 0, 48, 48)),
            ("classic.y", (0, 52, 48, 48)), ("classic.a", (104, 52, 48, 48)), ("classic.b", (52, 104, 48, 48))], "trailing")
        add("classicLeftShoulder", (134, 44), 0, 244,
            [("classic.l", (0, 0, 64, 44), "trigger"), ("classic.zl", (70, 0, 64, 44))])
        add("classicRightShoulder", (134, 44), 0, 292,
            [("classic.zr", (0, 0, 64, 44)), ("classic.r", (70, 0, 64, 44), "trigger")], "trailing")
        one_system = [("classic.minus", (0, 0, 44, 44)), ("classic.home", (52, 0, 44, 44)), ("classic.plus", (104, 0, 44, 44))]
        add("classicMinusPlusHome", (148, 44), 0, 344, one_system, "center", landscape_lift=0)
    elif kind == "wiiRemoteSideways":
        guides = []
        groups = [single("wiiDpad", "wii.dpad", 128, safe("left"), 0, kind, "dpad"),
                  single("sidewaysB", "wii.b", 77, sum_(safe("left"), 25.5), -168, kind),
                  group("sidewaysFaceCluster", (126, 157), 0, -40, [
                      ("wii.minus", (91.5, 0, 26, 26)), ("wii.a", (83, 51, 43, 43)),
                      ("wii.plus", (8.5, 59.5, 26, 26)), ("wii.one", (0, 114, 43, 43)),
                      ("wii.two", (83, 114, 43, 43))], kind),
                  single("sidewaysHome", "wii.home", 32, 0, 0, kind)]
        # Pin to the SAFE area's edges: legacy shifted() adds only side and bottom
        # insets (and half their difference for the centred Home).
        for node in groups:
            node["layout"]["anchor"]["to"] = "safeArea"
        groups[0]["layout"]["offset"]["x"] = 0
        groups[1]["layout"]["offset"]["x"] = 25.5
        groups[2]["layout"]["anchor"]["x"] = "trailing"
        groups[2]["layout"]["offset"]["x"] = -20
        groups[3]["layout"]["anchor"]["x"] = "center"
    else:
        raise ValueError(kind)

    # Centre columns use the SAFE horizontal midpoint, not the midpoint of edges
    # (max(inset,8)+8 would shift the Duo column by four points).
    for node in groups:
        if node["layout"].get("anchor", {}).get("x") == "center" and kind != "wiiRemoteSideways":
            node["layout"]["anchor"]["to"] = "#centerColumn"
    if kind != "wiiRemoteSideways":
        guides.append({"type": "group", "id": "centerColumn", "layout": {"inset": {
            "left": safe("left"), "right": safe("right"), "top": 0, "bottom": bottom}}})

    return {"formatVersion": "2.0", "identifier": "com.icube.default." + kind,
            "name": "iCube " + kind, "author": "iCube", "gameTypes": ["ngc" if kind == "gameCube" else "wii"],
            "requires": ["layout.anchors", "shapes.parametric", "shapes.path", "paint.gradients", "effects.shadow", "text", "tokens", "states", "controls.dpad", "controls.thumbstick", "controls.touchSurface"],
            "reference": {"shortSide": 390, "minScale": 1, "maxScale": 1 if kind == "wiiRemoteSideways" else 1.35},
            "bake": {"traits": ["iphone.standard", "iphone.edgeToEdge", "ipad.standard"]},
            "tokens": palette(kind), "root": {"type": "group", "id": "canvas", "children": guides + groups}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sources-only", action="store_true")
    args = parser.parse_args()
    baker = None
    if not args.sources_only:
        if "SKINKIT_BAKE" in os.environ:
            baker = Path(os.environ["SKINKIT_BAKE"]).expanduser()
            if not baker.is_file():
                raise FileNotFoundError(f"SKINKIT_BAKE does not name a file: {baker}")
        else:
            candidates = [
                SKINKIT / ".build/out/Products/Debug/skinkit-bake",
                SKINKIT / ".build/debug/skinkit-bake",
            ]
            baker = next((candidate for candidate in candidates if candidate.is_file()), None)
            if baker is None:
                subprocess.run(["xcrun", "swift", "build", "--jobs", "4", "--package-path", str(SKINKIT),
                                "--product", "skinkit-bake"], check=True)
                binary_directory = subprocess.check_output(
                    ["xcrun", "swift", "build", "--package-path", str(SKINKIT), "--show-bin-path"],
                    text=True).strip()
                baker = Path(binary_directory) / "skinkit-bake"
    # Write every source first, so a bake error cannot leave the later pads stale.
    for kind in KINDS:
        folder = ROOT / kind
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "skin.json").write_text(json.dumps(build(kind), indent=2, ensure_ascii=False) + "\n")
    if not args.sources_only:
        for kind in KINDS:
            folder = ROOT / kind
            # The baker deliberately refuses to overwrite an archive. Bake in a
            # scratch directory and install the expanded classic files only after
            # success, so reruns are deterministic and never pick an old archive.
            with tempfile.TemporaryDirectory(prefix="icube-default-skin-") as temporary:
                output = Path(temporary)
                subprocess.run([str(baker), str(folder / "skin.json"), str(output)], check=True)
                with ZipFile(output / "skin-1.deltaskin") as archive:
                    assert archive.read("skin.json") == (folder / "skin.json").read_bytes()
                    archive.extractall(output / "expanded")
                for generated in (output / "expanded").iterdir():
                    destination = folder / generated.name
                    if destination.is_dir():
                        shutil.rmtree(destination)
                    elif destination.exists():
                        destination.unlink()
                    shutil.move(str(generated), str(destination))
                # Keep the expanded bundle as the resource directory: the app bundles
                # skin.json alongside info.json, preview.png and bake/*.pdf.
                (folder / "skin-1.deltaskin").unlink(missing_ok=True)


if __name__ == "__main__":
    main()
