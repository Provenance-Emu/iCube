#!/usr/bin/env python3
"""
iCube touchscreen ButtonType drift linter.

The touchscreen button/axis ids are declared TWICE, by hand, in two languages:

  SOURCE OF TRUTH:
    Source/Core/InputCommon/ControllerInterface/iOS/ButtonType.h
      `enum ciface::iOS::ButtonType` -- consumed by StateManager, Touchscreen.mm,
      and TCManagerInterface.mm on the C++/Obj-C++ side.

  MIRROR:
    Source/iOS/App/DolphiniOS/UI/Emulation/TouchController/TCButtonType.swift
      `enum TCButtonType` -- the Swift-side id used to build touch UI and to call
      into TCManagerInterface (which forwards the raw Int to the C++ enum above).

Nothing enforces that the two stay numerically aligned. A button renumbered on one
side without the other is a SILENT input mismatch: the Swift UI sends an Int that
the C++ side decodes as a different (or no) button. This happened once already
(see docs/audits/2026-09-24-controller-system-audit.md, defect #17, commit
b32af2a26e). This script is the guard against it happening again.

Because the two enums use different naming conventions (upper snake case with
semantic renames on the C++ side, lowerCamelCase with further renames -- e.g.
WIIMOTE_BUTTON_1 -> wiiButtonOne, WIIMOTE_UP -> wiiPadUp, WIIMOTE_IR -> wiiInfrared
-- on the Swift side), there is no reliable *algorithmic* name transform between
them. Instead this script hand-maps every Swift case to the C++ enumerator it is
supposed to mirror (KNOWN_PAIRS below) and fails if their integer values disagree.

Not every C++ value has a Swift mirror (the touch UI exposes composite sticks, not
their synthesized directional sub-values, and has not wired up RUMBLE) -- those are
listed as expected-only-in-cpp and are NOT failures. Any OTHER value present on
only one side is reported as a warning (not a hard failure) so this script doesn't
block on unrelated pre-existing findings (e.g. audit defect #18's dead
`wiiInfraredRecenter` case).

When you add a new touchscreen button/axis: add the enumerator to ButtonType.h
first, then the Swift case, then a line to KNOWN_PAIRS below.

Exit code 0 = clean, 1 = drift found (or a mapped case is missing on either side).
Run from anywhere:
  python3 Source/iOS/App/Project/Scripts/check_button_types.py
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE_ROOT = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))  # .../Source
APP_ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))  # Source/iOS/App

BUTTON_TYPE_H = os.path.join(
    SOURCE_ROOT, "Core", "InputCommon", "ControllerInterface", "iOS", "ButtonType.h"
)
TC_BUTTON_TYPE_SWIFT = os.path.join(
    APP_ROOT, "DolphiniOS", "UI", "Emulation", "TouchController", "TCButtonType.swift"
)

# (C++ enumerator in ciface::iOS::ButtonType, Swift case in TCButtonType) -- both
# sides of every button/axis id the touch UI actually exposes today. Values are
# NOT listed here; they are read live from each file and compared.
KNOWN_PAIRS = [
    # GameCube
    ("BUTTON_A", "gcButtonA"),
    ("BUTTON_B", "gcButtonB"),
    ("BUTTON_START", "gcButtonStart"),
    ("BUTTON_X", "gcButtonX"),
    ("BUTTON_Y", "gcButtonY"),
    ("BUTTON_Z", "gcButtonZ"),
    ("BUTTON_UP", "gcButtonUp"),
    ("BUTTON_DOWN", "gcButtonDown"),
    ("BUTTON_LEFT", "gcButtonLeft"),
    ("BUTTON_RIGHT", "gcButtonRight"),
    ("STICK_MAIN", "gcStickMain"),
    ("STICK_C", "gcStickC"),
    ("TRIGGER_L", "gcTriggerL"),
    ("TRIGGER_R", "gcTriggerR"),
    # Wiimote
    ("WIIMOTE_BUTTON_A", "wiiButtonA"),
    ("WIIMOTE_BUTTON_B", "wiiButtonB"),
    ("WIIMOTE_BUTTON_MINUS", "wiiButtonMinus"),
    ("WIIMOTE_BUTTON_PLUS", "wiiButtonPlus"),
    ("WIIMOTE_BUTTON_HOME", "wiiButtonHome"),
    ("WIIMOTE_BUTTON_1", "wiiButtonOne"),
    ("WIIMOTE_BUTTON_2", "wiiButtonTwo"),
    ("WIIMOTE_UP", "wiiPadUp"),
    ("WIIMOTE_DOWN", "wiiPadDown"),
    ("WIIMOTE_LEFT", "wiiPadLeft"),
    ("WIIMOTE_RIGHT", "wiiPadRight"),
    ("WIIMOTE_IR", "wiiInfrared"),
    ("WIIMOTE_IR_UP", "wiiInfraredUp"),
    ("WIIMOTE_IR_DOWN", "wiiInfraredDown"),
    ("WIIMOTE_IR_LEFT", "wiiInfraredLeft"),
    ("WIIMOTE_IR_RIGHT", "wiiInfraredRight"),
    ("WIIMOTE_IR_FORWARD", "wiiInfraredForward"),
    ("WIIMOTE_IR_BACKWARD", "wiiInfraredBackward"),
    ("WIIMOTE_IR_HIDE", "wiiInfraredHide"),
    ("WIIMOTE_SWING", "wiiSwing"),
    ("WIIMOTE_SWING_UP", "wiiSwingUp"),
    ("WIIMOTE_SWING_DOWN", "wiiSwingDown"),
    ("WIIMOTE_SWING_LEFT", "wiiSwingLeft"),
    ("WIIMOTE_SWING_RIGHT", "wiiSwingRight"),
    ("WIIMOTE_SWING_FORWARD", "wiiSwingForward"),
    ("WIIMOTE_SWING_BACKWARD", "wiiSwingBackward"),
    ("WIIMOTE_TILT", "wiiTilt"),
    ("WIIMOTE_TILT_FORWARD", "wiiTiltForward"),
    ("WIIMOTE_TILT_BACKWARD", "wiiTiltBackward"),
    ("WIIMOTE_TILT_LEFT", "wiiTiltLeft"),
    ("WIIMOTE_TILT_RIGHT", "wiiTiltRight"),
    ("WIIMOTE_TILT_MODIFIER", "wiiTiltModifier"),
    ("WIIMOTE_SHAKE_X", "wiiShakeX"),
    ("WIIMOTE_SHAKE_Y", "wiiShakeY"),
    ("WIIMOTE_SHAKE_Z", "wiiShakeZ"),
    # Nunchuk
    ("NUNCHUK_BUTTON_C", "nunchukButtonC"),
    ("NUNCHUK_BUTTON_Z", "nunchukButtonZ"),
    ("NUNCHUK_STICK", "nunchukStick"),
    ("NUNCHUK_SWING", "nunchukSwing"),
    ("NUNCHUK_SWING_UP", "nunchukSwingUp"),
    ("NUNCHUK_SWING_DOWN", "nunchukSwingDown"),
    ("NUNCHUK_SWING_LEFT", "nunchukSwingLeft"),
    ("NUNCHUK_SWING_RIGHT", "nunchukSwingRight"),
    ("NUNCHUK_SWING_FORWARD", "nunchukSwingForward"),
    ("NUNCHUK_SWING_BACKWARD", "nunchukSwingBackward"),
    ("NUNCHUK_TILT", "nunchukTilt"),
    ("NUNCHUK_TILT_FORWARD", "nunchukTiltForward"),
    ("NUNCHUK_TILT_BACKWARD", "nunchukTiltBackward"),
    ("NUNCHUK_TILT_LEFT", "nunchukTiltLeft"),
    ("NUNCHUK_TILT_RIGHT", "nunchukTiltRight"),
    ("NUNCHUK_TILT_MODIFIER", "nunchukTiltModifier"),
    ("NUNCHUK_SHAKE_X", "nunchukShakeX"),
    ("NUNCHUK_SHAKE_Y", "nunchukShakeY"),
    ("NUNCHUK_SHAKE_Z", "nunchukShakeZ"),
    # Classic Controller
    ("CLASSIC_BUTTON_A", "classicButtonA"),
    ("CLASSIC_BUTTON_B", "classicButtonB"),
    ("CLASSIC_BUTTON_X", "classicButtonX"),
    ("CLASSIC_BUTTON_Y", "classicButtonY"),
    ("CLASSIC_BUTTON_MINUS", "classicButtonMINUS"),
    ("CLASSIC_BUTTON_PLUS", "classicButtonPLUS"),
    ("CLASSIC_BUTTON_HOME", "classicButtonHOME"),
    ("CLASSIC_BUTTON_ZL", "classicButtonZL"),
    ("CLASSIC_BUTTON_ZR", "classicButtonZR"),
    ("CLASSIC_DPAD_UP", "classicPadUp"),
    ("CLASSIC_DPAD_DOWN", "classicPadDown"),
    ("CLASSIC_DPAD_LEFT", "classicPadLeft"),
    ("CLASSIC_DPAD_RIGHT", "classicPadRight"),
    ("CLASSIC_STICK_LEFT", "classicStickLeft"),
    ("CLASSIC_STICK_LEFT_UP", "classicStickLeftUp"),
    ("CLASSIC_STICK_LEFT_DOWN", "classicStickLeftDown"),
    ("CLASSIC_STICK_LEFT_LEFT", "classicStickLeftLeft"),
    ("CLASSIC_STICK_LEFT_RIGHT", "classicStickLeftRight"),
    ("CLASSIC_STICK_RIGHT", "classicStickRight"),
    ("CLASSIC_STICK_RIGHT_UP", "classicStickRightUp"),
    ("CLASSIC_STICK_RIGHT_DOWN", "classicStickRightDown"),
    ("CLASSIC_STICK_RIGHT_LEFT", "classicStickRightLeft"),
    ("CLASSIC_STICK_RIGHT_RIGHT", "classicStickRightRight"),
    ("CLASSIC_TRIGGER_L", "classicTriggerL"),
    ("CLASSIC_TRIGGER_R", "classicTriggerR"),
    # Wiimote IMU
    ("WIIMOTE_ACCEL_LEFT", "wiiAccelLeft"),
    ("WIIMOTE_ACCEL_RIGHT", "wiiAccelRight"),
    ("WIIMOTE_ACCEL_FORWARD", "wiiAccelForward"),
    ("WIIMOTE_ACCEL_BACKWARD", "wiiAccelBackward"),
    ("WIIMOTE_ACCEL_UP", "wiiAccelUp"),
    ("WIIMOTE_ACCEL_DOWN", "wiiAccelDown"),
    ("WIIMOTE_GYRO_PITCH_UP", "wiiGyroPitchUp"),
    ("WIIMOTE_GYRO_PITCH_DOWN", "wiiGyroPitchDown"),
    ("WIIMOTE_GYRO_ROLL_LEFT", "wiiGyroRollLeft"),
    ("WIIMOTE_GYRO_ROLL_RIGHT", "wiiGyroRollRight"),
    ("WIIMOTE_GYRO_YAW_LEFT", "wiiGyroYawLeft"),
    ("WIIMOTE_GYRO_YAW_RIGHT", "wiiGyroYawRight"),
    # Nunchuk IMU
    ("NUNCHUK_ACCEL_LEFT", "nunchukAccelLeft"),
    ("NUNCHUK_ACCEL_RIGHT", "nunchukAccelRight"),
    ("NUNCHUK_ACCEL_FORWARD", "nunchukAccelForward"),
    ("NUNCHUK_ACCEL_BACKWARD", "nunchukAccelBackward"),
    ("NUNCHUK_ACCEL_UP", "nunchukAccelUp"),
    ("NUNCHUK_ACCEL_DOWN", "nunchukAccelDown"),
]

# C++ values with intentionally no Swift mirror: the touch UI drags a composite
# stick widget rather than exposing the four synthesized directional sub-values,
# and RUMBLE has no on-screen control. Not a failure if these are Swift-absent.
EXPECTED_CPP_ONLY = {
    "STICK_MAIN_UP", "STICK_MAIN_DOWN", "STICK_MAIN_LEFT", "STICK_MAIN_RIGHT",
    "STICK_C_UP", "STICK_C_DOWN", "STICK_C_LEFT", "STICK_C_RIGHT",
    "NUNCHUK_STICK_UP", "NUNCHUK_STICK_DOWN", "NUNCHUK_STICK_LEFT", "NUNCHUK_STICK_RIGHT",
    "RUMBLE",
}


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def parse_cpp_enum(text):
    """Returns {NAME: int value} for `NAME = 123,` lines in ButtonType.h."""
    return {name: int(value) for name, value in re.findall(r"\b([A-Z][A-Z0-9_]*)\s*=\s*(\d+)", text)}


def parse_swift_enum(text):
    """Returns {name: int value} for `case name = 123` lines in TCButtonType.swift."""
    return {name: int(value) for name, value in re.findall(r"\bcase\s+([a-zA-Z][a-zA-Z0-9]*)\s*=\s*(\d+)", text)}


def main():
    if not os.path.exists(BUTTON_TYPE_H):
        print(f"ERROR: not found: {BUTTON_TYPE_H}", file=sys.stderr)
        return 2
    if not os.path.exists(TC_BUTTON_TYPE_SWIFT):
        print(f"ERROR: not found: {TC_BUTTON_TYPE_SWIFT}", file=sys.stderr)
        return 2

    cpp = parse_cpp_enum(read(BUTTON_TYPE_H))
    swift = parse_swift_enum(read(TC_BUTTON_TYPE_SWIFT))

    print("== iCube ButtonType drift linter ==")
    print(f"ButtonType.h enumerators:      {len(cpp)}")
    print(f"TCButtonType.swift cases:      {len(swift)}")
    print(f"Known mapped pairs to check:   {len(KNOWN_PAIRS)}")
    print()

    failures = []

    for cpp_name, swift_name in KNOWN_PAIRS:
        cpp_value = cpp.get(cpp_name)
        swift_value = swift.get(swift_name)
        if cpp_value is None:
            failures.append(f"{cpp_name} is in KNOWN_PAIRS but missing from ButtonType.h")
            continue
        if swift_value is None:
            failures.append(f"{swift_name} is in KNOWN_PAIRS but missing from TCButtonType.swift "
                             f"(expected to mirror {cpp_name} = {cpp_value})")
            continue
        if cpp_value != swift_value:
            failures.append(
                f"DRIFT: {cpp_name} = {cpp_value} (ButtonType.h) but "
                f"{swift_name} = {swift_value} (TCButtonType.swift) -- these must match"
            )

    mapped_cpp_names = {c for c, _ in KNOWN_PAIRS}
    mapped_swift_names = {s for _, s in KNOWN_PAIRS}

    unexpected_cpp_only = sorted(
        name for name in cpp
        if name not in mapped_cpp_names and name not in EXPECTED_CPP_ONLY
    )
    unexpected_swift_only = sorted(
        name for name in swift
        if name not in mapped_swift_names
    )

    if unexpected_cpp_only:
        print("WARNING: ButtonType.h enumerators with no Swift mapping and not in "
              "EXPECTED_CPP_ONLY (add to KNOWN_PAIRS if the touch UI should expose them, "
              "or to EXPECTED_CPP_ONLY if that's intentional):")
        for name in unexpected_cpp_only:
            print(f"  - {name} = {cpp[name]}")
        print()

    if unexpected_swift_only:
        print("WARNING: TCButtonType.swift cases with no ButtonType.h mapping in KNOWN_PAIRS "
              "(either add the mapping, or this id has no backing C++ enumerator at all):")
        for name in unexpected_swift_only:
            in_cpp_values = name and swift[name] in cpp.values()
            note = "" if in_cpp_values else "  <-- value does not exist anywhere in ButtonType.h"
            print(f"  - {name} = {swift[name]}{note}")
        print()

    if failures:
        print(f"FAIL: {len(failures)} issue(s):")
        for f in failures:
            print(f"  - {f}")
        return 1

    print("OK: every mapped touchscreen button/axis id agrees between ButtonType.h and "
          "TCButtonType.swift.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
