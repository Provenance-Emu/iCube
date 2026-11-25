// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <map>
#include <optional>
#include <string>
#include <vector>

// Maps the element names of a GCController's physical input profile onto the MFi input names
// every Dolphin profile binds ("Button A", "R Stick Y+", ...), for pads the GameController
// framework exposes with neither an extended nor a micro gamepad (the Nintendo Switch Online
// N64 controller on tvOS 17), and for the Switch Online pads it exposes with only the basic MFi
// profile (the SNES controller), and for plain USB / Bluetooth HID pads it exposes with no gamepad
// profile at all (product category "HID"). Pure strings, so it compiles and tests anywhere.
//
// Semantics are GameCube / Wii, not RetroPad: the N64 pad's A and B are the GameCube A and B,
// its C cluster is the C-Stick (R Stick directions), Z is the GameCube Z trigger (the
// `R Shoulder` input the default GCPad profile binds to Buttons/Z), L and R are the analog
// triggers, ZR is Options (the app's pause route), Start is Menu (GameCube Start / Wii +) and
// Home is Home.
namespace ciface::iOS::PhysicalProfile
{
enum class Input
{
  DPad,
  LeftStick,
  RightStick,
  ButtonA,
  ButtonB,
  ButtonX,
  ButtonY,
  LShoulder,
  RShoulder,
  LTrigger,
  RTrigger,
  Menu,
  Options,
  Home,
  // Stick clicks (L3 / R3).
  LStickButton,
  RStickButton,
  // Digital buttons that stand in for a right-stick direction: the N64 C cluster.
  CUp,
  CDown,
  CLeft,
  CRight,
};

using Bindings = std::map<std::string, Input>;

// The MFi input name a button-like Input publishes. For the C cluster this is the R Stick
// direction it drives ("R Stick Y+" for C Up) and for a stick click it is the name the extended
// gamepad path gives it ("L Stick", "R Stick"); DPad and the sticks publish several names
// ("D-Pad Up", "L Stick X+", ...) and return an empty string here.
std::string InputName(Input input);

bool IsDirection(Input input);
bool IsCButton(Input input);

// True for the Nintendo Switch Online N64 controller (vendor name "N64 Controller").
bool IsN64Pad(const std::string& vendor_name, const std::string& product_category);

// True for the Nintendo Switch Online SNES controller (057E:2017, vendor name "SNES Controller",
// product category "Switch SNES Controller"). The system describes it with the basic MFi profile:
// a legacy gamepad and a micro gamepad, no extended one, so neither carries Start or Select.
bool IsSnesPad(const std::string& vendor_name, const std::string& product_category);

// The Nintendo Switch Online pads bound through their physical profile whenever the system gives
// them no extended gamepad, whatever else it exposes: the N64 and SNES controllers.
bool IsSwitchOnlinePad(const std::string& vendor_name, const std::string& product_category);

// Lowercases, turns '-' and '_' into spaces and collapses whitespace.
std::string Normalize(const std::string& name);

// The input an element should drive, or nullopt when the element is not one a profile reads.
// `is_n64_pad` enables the bare "Button <n>" fallback from RetroArch's N64 autoconfig.
std::optional<Input> ResolveElement(const std::string& name, bool is_n64_pad);

// Resolves every element name. The framework's standard names are bound first, then the
// rest in sorted order; a later name never overrides an earlier binding of the same input.
Bindings ResolveBindings(const std::vector<std::string>& names, bool is_n64_pad);

// A profile is worth adapting when it has a direction input and a face button.
bool IsUsable(const Bindings& bindings);

// True when the product category names a remote (Siri Remote, Control Center remote). A remote
// has a direction pad and buttons too; it is never bound by position.
bool IsRemote(const std::string& product_category);

// The number in a bare "Button <n>" / "<n>" element name.
std::optional<int> ButtonIndex(const std::string& name);

// Inputs handed, in this order, to buttons whose names say nothing ("Button 3"): A, B, X, Y,
// L, R, L2, R2, Options (Select), Menu (Start), L3, R3.
const std::vector<Input>& FallbackButtonOrder();

// Bindings for a generic pad (a plain HID pad): names first, as ResolveBindings but by element
// kind (a button name never takes a direction input, and the reverse), then leftover elements
// by position, so the pad works at all; the player fixes a wrong guess in the remap screen.
//
// Printed labels follow a modern pad here, not the N64 one: L / R are the shoulders and ZL / ZR
// the triggers.
//
// Leftover direction elements fill the unused direction inputs (D-pad, left stick, right
// stick). Leftover buttons fill the unused inputs of FallbackButtonOrder when their name is only
// a number, or when the names alone gave no face button. A button that is one direction of a
// direction element ("Direction Pad Up") or a stick click is never taken by position.
//
// Last, an axis NAMED as a trigger ("Left Trigger", "L2", "ZL") takes that trigger if no button
// did: some pads report analog triggers as axes only. It goes last so a pad with both the
// digital trigger buttons and the axes keeps its positional button order.
Bindings ResolveGenericBindings(const std::vector<std::string>& button_names,
                                const std::vector<std::string>& direction_names,
                                const std::vector<std::string>& axis_names);

// A profile can list one physical element under several names ("Button A" and "Button 1").
// The one name to resolve it by: a framework standard name, else a name that means something,
// else the first in positional order. Callers reduce every element to this name BEFORE
// resolving, so an alias neither takes a positional slot nor displaces the named binding.
std::string PreferredName(const std::vector<std::string>& aliases);

// The one entry point the core and the app share: a Switch Online pad and a remote resolve by
// name alone (ResolveBindings over every element), any other pad through
// ResolveGenericBindings.
Bindings ResolveForPad(const std::string& vendor_name, const std::string& product_category,
                       const std::vector<std::string>& button_names,
                       const std::vector<std::string>& direction_names,
                       const std::vector<std::string>& axis_names);

// A trigger read from an axis, in 0...1. Such an axis rests at 0 (range 0...1) on some pads and
// at -1 (range -1...1) on others; `rests_at_minus_one` is set, and stays set, once the axis has
// reported a negative value.
float TriggerValueFromAxis(float raw, bool& rests_at_minus_one);

// A stick driven from a D-pad, for a pad with a D-pad and no stick. A digital press as a full
// deflection makes a character run the moment it is touched; this starts the push at
// DPAD_STICK_START and reaches a full one DPAD_STICK_RAMP_SECONDS later, so a tap is a nudge and
// a hold is a run.
constexpr float DPAD_STICK_START = 0.4f;
constexpr double DPAD_STICK_RAMP_SECONDS = 0.2;

// How far a direction held for `held_seconds` pushes the stick, DPAD_STICK_START...1.
float DPadStickMagnitude(double held_seconds);

// The stick position for a D-pad whose axes read -1, 0 or 1 (`x_sign`, `y_sign`), each held for
// its own time. A diagonal stays on the unit circle rather than reaching the corner of the square.
struct StickPosition
{
  float x;
  float y;
};
StickPosition DPadStickPosition(int x_sign, double x_held_seconds, int y_sign,
                                double y_held_seconds);

// The name of a pad that reports none: "<product category> Gamepad", so unnamed pads of
// different kinds do not share one device name (and the mappings stored under it). Which pads
// get it is MFiController::NameFor.
std::string FallbackName(const std::string& product_category);
}  // namespace ciface::iOS::PhysicalProfile
