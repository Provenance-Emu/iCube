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
// N64 controller on tvOS 17). Pure strings, so it compiles and tests anywhere.
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
  // Digital buttons that stand in for a right-stick direction: the N64 C cluster.
  CUp,
  CDown,
  CLeft,
  CRight,
};

using Bindings = std::map<std::string, Input>;

// The MFi input name a button-like Input publishes. For the C cluster this is the R Stick
// direction it drives ("R Stick Y+" for C Up); DPad and the sticks publish several names
// ("D-Pad Up", "L Stick X+", ...) and return an empty string here.
std::string InputName(Input input);

bool IsDirection(Input input);
bool IsCButton(Input input);

// True for the Nintendo Switch Online N64 controller (vendor name "N64 Controller").
bool IsN64Pad(const std::string& vendor_name, const std::string& product_category);

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
}  // namespace ciface::iOS::PhysicalProfile
