// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "InputCommon/ControllerInterface/iOS/PhysicalProfileMapping.h"

#include <algorithm>
#include <cctype>
#include <set>
#include <sstream>

namespace ciface::iOS::PhysicalProfile
{
namespace
{
// Element names the GameController framework uses for standard inputs (GCInputButtonA is
// "Button A", and so on).
const std::map<std::string, Input> s_standard_names = {
    {"button a", Input::ButtonA},
    {"button b", Input::ButtonB},
    {"button x", Input::ButtonX},
    {"button y", Input::ButtonY},
    {"direction pad", Input::DPad},
    {"left thumbstick", Input::LeftStick},
    {"right thumbstick", Input::RightStick},
    {"left shoulder", Input::LShoulder},
    {"right shoulder", Input::RShoulder},
    {"left trigger", Input::LTrigger},
    {"right trigger", Input::RTrigger},
    {"button menu", Input::Menu},
    {"button options", Input::Options},
    {"button home", Input::Home},
};

// Aliases for pads whose element names are the labels printed on the buttons. Looked up
// after a leading "button " has been dropped.
const std::map<std::string, Input> s_aliases = {
    {"a", Input::ButtonA},
    {"b", Input::ButtonB},
    {"x", Input::ButtonX},
    {"y", Input::ButtonY},
    {"c up", Input::CUp},
    {"cup", Input::CUp},
    {"c down", Input::CDown},
    {"cdown", Input::CDown},
    {"c left", Input::CLeft},
    {"cleft", Input::CLeft},
    {"c right", Input::CRight},
    {"cright", Input::CRight},
    // GameCube Z: the default GCPad profile binds Buttons/Z to `R Shoulder`.
    {"z", Input::RShoulder},
    {"z trigger", Input::RShoulder},
    {"trigger z", Input::RShoulder},
    {"zl", Input::LShoulder},
    {"zr", Input::Options},
    {"select", Input::Options},
    {"minus", Input::Options},
    {"back", Input::Options},
    {"view", Input::Options},
    {"start", Input::Menu},
    {"plus", Input::Menu},
    {"home", Input::Home},
    // N64 L / R are the GameCube analog triggers.
    {"l", Input::LTrigger},
    {"r", Input::RTrigger},
    {"left bumper", Input::LShoulder},
    {"l1", Input::LShoulder},
    {"right bumper", Input::RShoulder},
    {"r1", Input::RShoulder},
    {"l2", Input::LTrigger},
    {"r2", Input::RTrigger},
    {"dpad", Input::DPad},
    {"d pad", Input::DPad},
    {"hat", Input::DPad},
    {"left stick", Input::LeftStick},
    {"joystick", Input::LeftStick},
    {"stick", Input::LeftStick},
    {"right stick", Input::RightStick},
};

// RetroArch `N64_Nintendo_Switch_Online.cfg` (hid driver) button indices.
const std::map<int, Input> s_n64_hid_buttons = {
    {0, Input::ButtonB},   // B (RetroPad Y)
    {1, Input::ButtonA},   // A (RetroPad B)
    {2, Input::CUp},       // C Up
    {3, Input::CLeft},     // C Left
    {4, Input::LTrigger},  // L
    {5, Input::RTrigger},  // R
    {6, Input::RShoulder}, // Z -> GameCube Z
    {7, Input::CDown},     // C Down
    {8, Input::CRight},    // C Right
    {9, Input::Menu},      // Start
    {10, Input::Options},  // ZR
    {12, Input::Home},     // Home
};

constexpr const char* BUTTON_PREFIX = "button ";

std::string StripButtonPrefix(const std::string& normalized)
{
  if (normalized.rfind(BUTTON_PREFIX, 0) == 0)
    return normalized.substr(std::string(BUTTON_PREFIX).size());
  return normalized;
}

bool IsStandardName(const std::string& name)
{
  return s_standard_names.count(Normalize(name)) != 0;
}
}  // namespace

std::string InputName(Input input)
{
  switch (input)
  {
  case Input::ButtonA:
    return "Button A";
  case Input::ButtonB:
    return "Button B";
  case Input::ButtonX:
    return "Button X";
  case Input::ButtonY:
    return "Button Y";
  case Input::LShoulder:
    return "L Shoulder";
  case Input::RShoulder:
    return "R Shoulder";
  case Input::LTrigger:
    return "L Trigger";
  case Input::RTrigger:
    return "R Trigger";
  case Input::Menu:
    return "Menu";
  case Input::Options:
    return "Options";
  case Input::Home:
    return "Home";
  case Input::CUp:
    return "R Stick Y+";
  case Input::CDown:
    return "R Stick Y-";
  case Input::CLeft:
    return "R Stick X-";
  case Input::CRight:
    return "R Stick X+";
  case Input::DPad:
  case Input::LeftStick:
  case Input::RightStick:
    return "";
  }
  return "";
}

bool IsDirection(Input input)
{
  return input == Input::DPad || input == Input::LeftStick || input == Input::RightStick;
}

bool IsCButton(Input input)
{
  return input == Input::CUp || input == Input::CDown || input == Input::CLeft ||
         input == Input::CRight;
}

bool IsN64Pad(const std::string& vendor_name, const std::string& product_category)
{
  return Normalize(vendor_name + " " + product_category).find("n64") != std::string::npos;
}

std::string Normalize(const std::string& name)
{
  std::string spaced;
  spaced.reserve(name.size());
  for (const char c : name)
  {
    if (c == '-' || c == '_')
      spaced += ' ';
    else
      spaced += static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  }
  std::istringstream words(spaced);
  std::string word, collapsed;
  while (words >> word)
  {
    if (!collapsed.empty())
      collapsed += ' ';
    collapsed += word;
  }
  return collapsed;
}

std::optional<Input> ResolveElement(const std::string& name, bool is_n64_pad)
{
  const std::string normalized = Normalize(name);
  if (const auto standard = s_standard_names.find(normalized); standard != s_standard_names.end())
    return standard->second;
  const std::string bare = StripButtonPrefix(normalized);
  if (const auto alias = s_aliases.find(bare); alias != s_aliases.end())
    return alias->second;
  if (is_n64_pad && !bare.empty() &&
      std::all_of(bare.begin(), bare.end(), [](unsigned char c) { return std::isdigit(c); }))
  {
    if (const auto hid = s_n64_hid_buttons.find(std::stoi(bare)); hid != s_n64_hid_buttons.end())
      return hid->second;
  }
  return std::nullopt;
}

Bindings ResolveBindings(const std::vector<std::string>& names, bool is_n64_pad)
{
  std::vector<std::string> ordered = names;
  std::ranges::sort(ordered, [](const std::string& lhs, const std::string& rhs) {
    const bool l = IsStandardName(lhs), r = IsStandardName(rhs);
    return l != r ? l : lhs < rhs;
  });

  Bindings result;
  std::set<Input> taken;
  for (const std::string& name : ordered)
  {
    const auto input = ResolveElement(name, is_n64_pad);
    if (!input || taken.count(*input))
      continue;
    result[name] = *input;
    taken.insert(*input);
  }
  return result;
}

bool IsUsable(const Bindings& bindings)
{
  bool has_direction = false, has_button = false;
  for (const auto& [name, input] : bindings)
  {
    if (input == Input::DPad || input == Input::LeftStick)
      has_direction = true;
    if (input == Input::ButtonA || input == Input::ButtonB || input == Input::ButtonX ||
        input == Input::ButtonY)
      has_button = true;
  }
  return has_direction && has_button;
}
}  // namespace ciface::iOS::PhysicalProfile
