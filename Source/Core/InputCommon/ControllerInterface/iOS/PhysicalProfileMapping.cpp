// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "InputCommon/ControllerInterface/iOS/PhysicalProfileMapping.h"

#include <algorithm>
#include <cctype>
#include <compare>
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
    {"left thumbstick button", Input::LStickButton},
    {"right thumbstick button", Input::RStickButton},
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
    {"l3", Input::LStickButton},
    {"left stick button", Input::LStickButton},
    {"left stick click", Input::LStickButton},
    {"thumbl", Input::LStickButton},
    {"r3", Input::RStickButton},
    {"right stick button", Input::RStickButton},
    {"right stick click", Input::RStickButton},
    {"thumbr", Input::RStickButton},
};

// Labels that mean something else on a modern pad than on the N64 one. Looked up before
// s_aliases for a generic pad.
const std::map<std::string, Input> s_generic_aliases = {
    {"l", Input::LShoulder},
    {"r", Input::RShoulder},
    {"zl", Input::LTrigger},
    {"zr", Input::RTrigger},
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

std::optional<Input> ResolveGenericElement(const std::string& name)
{
  const std::string normalized = Normalize(name);
  if (s_standard_names.count(normalized) == 0)
  {
    if (const auto alias = s_generic_aliases.find(StripButtonPrefix(normalized));
        alias != s_generic_aliases.end())
    {
      return alias->second;
    }
  }
  return ResolveElement(name, false);
}

// The framework's standard names first, then the rest alphabetically.
void SortStandardFirst(std::vector<std::string>& names)
{
  std::ranges::sort(names, [](const std::string& lhs, const std::string& rhs) {
    const bool l = IsStandardName(lhs), r = IsStandardName(rhs);
    return l != r ? l : lhs < rhs;
  });
}

// "Button 2" before "Button 10": bare numbered names first, by number. Other names
// alphabetically, except that names differing only in a trailing number ("Trigger 2",
// "Trigger 10") also go by number.
struct NaturalKey
{
  bool named;
  std::string prefix;
  long number;
  std::string name;
  auto operator<=>(const NaturalKey&) const = default;
};

NaturalKey MakeNaturalKey(const std::string& name)
{
  if (const auto index = ButtonIndex(name))
    return {false, "", *index, name};

  const std::string normalized = Normalize(name);
  size_t digits = 0;
  while (digits < normalized.size() &&
         std::isdigit(static_cast<unsigned char>(normalized[normalized.size() - 1 - digits])))
  {
    ++digits;
  }
  // Nine digits at most, so std::stol cannot overflow.
  if (digits == 0 || digits > 9)
    return {true, normalized, -1, name};
  return {true, normalized.substr(0, normalized.size() - digits),
          std::stol(normalized.substr(normalized.size() - digits)), name};
}

bool NaturalOrder(const std::string& lhs, const std::string& rhs)
{
  return MakeNaturalKey(lhs) < MakeNaturalKey(rhs);
}

bool IsFaceButton(Input input)
{
  return input == Input::ButtonA || input == Input::ButtonB || input == Input::ButtonX ||
         input == Input::ButtonY;
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
  case Input::LStickButton:
    return "L Stick";
  case Input::RStickButton:
    return "R Stick";
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

bool IsSnesPad(const std::string& vendor_name, const std::string& product_category)
{
  const std::string normalized = Normalize(vendor_name + " " + product_category);
  return normalized.find("snes") != std::string::npos ||
         normalized.find("super famicom") != std::string::npos;
}

bool IsSwitchOnlinePad(const std::string& vendor_name, const std::string& product_category)
{
  return IsN64Pad(vendor_name, product_category) || IsSnesPad(vendor_name, product_category);
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
  SortStandardFirst(ordered);

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
    if (IsFaceButton(input))
      has_button = true;
  }
  return has_direction && has_button;
}

bool IsRemote(const std::string& product_category)
{
  return Normalize(product_category).find("remote") != std::string::npos;
}

std::optional<int> ButtonIndex(const std::string& name)
{
  const std::string bare = StripButtonPrefix(Normalize(name));
  // Nine digits at most, so std::stoi cannot overflow.
  if (bare.empty() || bare.size() > 9 ||
      !std::all_of(bare.begin(), bare.end(), [](unsigned char c) { return std::isdigit(c); }))
  {
    return std::nullopt;
  }
  return std::stoi(bare);
}

const std::vector<Input>& FallbackButtonOrder()
{
  static const std::vector<Input> s_order = {
      Input::ButtonA,   Input::ButtonB,   Input::ButtonX,      Input::ButtonY,
      Input::LShoulder, Input::RShoulder, Input::LTrigger,     Input::RTrigger,
      Input::Options,   Input::Menu,      Input::LStickButton, Input::RStickButton,
  };
  return s_order;
}

Bindings ResolveGenericBindings(const std::vector<std::string>& button_names,
                                const std::vector<std::string>& direction_names,
                                const std::vector<std::string>& axis_names)
{
  Bindings result;
  std::set<Input> taken;
  const auto bind = [&](const std::string& name, Input input) {
    result[name] = input;
    taken.insert(input);
  };

  // 1. Names. A direction element takes only a direction input and a button only a button
  // input, so a button that happens to be called "Hat" cannot leave the pad without a D-pad.
  const std::set<std::string> directions(direction_names.begin(), direction_names.end());
  std::vector<std::string> named = button_names;
  named.insert(named.end(), direction_names.begin(), direction_names.end());
  SortStandardFirst(named);
  for (const std::string& name : named)
  {
    const auto input = ResolveGenericElement(name);
    if (!input || taken.count(*input) || result.count(name) ||
        IsDirection(*input) != (directions.count(name) != 0))
    {
      continue;
    }
    bind(name, *input);
  }

  // 2. Leftover direction elements, by position.
  std::vector<std::string> ordered_directions = direction_names;
  std::ranges::sort(ordered_directions, NaturalOrder);
  for (const std::string& name : ordered_directions)
  {
    if (result.count(name))
      continue;
    for (const Input input : {Input::DPad, Input::LeftStick, Input::RightStick})
    {
      if (taken.count(input))
        continue;
      bind(name, input);
      break;
    }
  }

  // 3. Leftover buttons, by position.
  bool has_face = false;
  for (const Input input : taken)
    has_face = has_face || IsFaceButton(input);

  std::vector<std::string> direction_prefixes;
  for (const std::string& name : direction_names)
    direction_prefixes.push_back(Normalize(name) + " ");

  std::vector<std::string> leftover;
  for (const std::string& name : button_names)
  {
    if (result.count(name) || directions.count(name))
      continue;
    const std::string normalized = Normalize(name);
    const bool is_direction_half =
        std::ranges::any_of(direction_prefixes, [&](const std::string& prefix) {
          return normalized.rfind(prefix, 0) == 0;
        });
    if (is_direction_half || normalized.find("thumbstick") != std::string::npos)
      continue;
    // Once the names gave a face button, a named extra ("Button Share") is left alone.
    if (has_face && !ButtonIndex(name))
      continue;
    leftover.push_back(name);
  }
  std::ranges::sort(leftover, NaturalOrder);
  leftover.erase(std::unique(leftover.begin(), leftover.end()), leftover.end());

  auto next_button = leftover.begin();
  for (const Input input : FallbackButtonOrder())
  {
    if (next_button == leftover.end())
      break;
    if (taken.count(input))
      continue;
    bind(*next_button++, input);
  }

  // 4. Axes named as triggers.
  std::vector<std::string> ordered_axes = axis_names;
  std::ranges::sort(ordered_axes);
  for (const std::string& name : ordered_axes)
  {
    const auto input = ResolveGenericElement(name);
    if (!input || (*input != Input::LTrigger && *input != Input::RTrigger) ||
        taken.count(*input) || result.count(name))
    {
      continue;
    }
    bind(name, *input);
  }
  return result;
}

std::string PreferredName(const std::vector<std::string>& aliases)
{
  if (aliases.empty())
    return "";
  // Lower is better: standard name, then any name that resolves, then the rest.
  const auto rank = [](const std::string& name) {
    if (IsStandardName(name))
      return 0;
    return ResolveGenericElement(name) ? 1 : 2;
  };
  return *std::ranges::min_element(aliases, [&](const std::string& lhs, const std::string& rhs) {
    const int l = rank(lhs), r = rank(rhs);
    return l != r ? l < r : NaturalOrder(lhs, rhs);
  });
}

Bindings ResolveForPad(const std::string& vendor_name, const std::string& product_category,
                       const std::vector<std::string>& button_names,
                       const std::vector<std::string>& direction_names,
                       const std::vector<std::string>& axis_names)
{
  if (IsSwitchOnlinePad(vendor_name, product_category) || IsRemote(product_category))
  {
    std::vector<std::string> names = button_names;
    names.insert(names.end(), direction_names.begin(), direction_names.end());
    names.insert(names.end(), axis_names.begin(), axis_names.end());
    return ResolveBindings(names, IsN64Pad(vendor_name, product_category));
  }
  return ResolveGenericBindings(button_names, direction_names, axis_names);
}

float TriggerValueFromAxis(float raw, bool& rests_at_minus_one)
{
  if (raw < -0.05f)
    rests_at_minus_one = true;
  return std::clamp(rests_at_minus_one ? (raw + 1.0f) / 2.0f : raw, 0.0f, 1.0f);
}

std::string FallbackName(const std::string& product_category)
{
  if (Normalize(product_category).empty())
    return "Unknown Controller";
  return product_category + " Gamepad";
}
}  // namespace ciface::iOS::PhysicalProfile
