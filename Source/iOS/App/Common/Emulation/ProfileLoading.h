// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

// C++ only: not for the Swift bridging header.

#pragma once

#include <array>
#include <functional>
#include <map>
#include <string>

#include "Common/CommonTypes.h"
#include "Common/IniFile.h"
#include "InputCommon/ControllerEmu/ControlGroup/Attachments.h"
#include "InputCommon/ControllerEmu/ControllerEmu.h"
#include "InputCommon/ControllerInterface/ControllerInterface.h"

// Loads a profile's `[Profile]` section into `controller`, keeping a Wii Remote's extension unless
// the profile names one. `Attachments::LoadConfig` selects None whenever the `Extension =` line is
// missing, and the bundled Wii Remote profiles (Physical Controller, Touchscreen, DSU) carry none,
// so a default load would otherwise reset the extension the player chose. A controller without an
// extension group (a GameCube pad) loads as usual.
inline void LoadProfileKeepingExtension(ControllerEmu::EmulatedController* controller,
                                        Common::IniFile::Section* section)
{
  ControllerEmu::Attachments* attachments = nullptr;
  for (const auto& group : controller->groups)
  {
    if (group->type == ControllerEmu::GroupType::Attachments)
      attachments = static_cast<ControllerEmu::Attachments*>(group.get());
  }
  const bool keep = attachments && !section->Exists(attachments->name);
  const u32 extension = keep ? attachments->GetSelectedAttachment() : 0;
  controller->LoadConfig(section);
  if (keep)
    attachments->SetSelectedAttachment(extension);
}

// A GameCube profile written for a pad with a left stick ("Physical Controller") binds the Main
// Stick to `L Stick ...`. A pad whose only direction input is a D-pad (the Switch Online SNES pad,
// a plain HID pad such as the 8BitDo FlipPad) has no such input, and booted with nothing on the
// Main Stick: most games could not be steered until the player remapped.
//
// The keys to rewrite so the D-pad drives the Main Stick instead, or none. All of these must hold:
// the device has all four `D-Pad` inputs and none of the four `L Stick` ones, and every Main Stick
// direction is bound to exactly its `L Stick` input (so a mapping the player wrote is never
// touched). A `D-Pad/<direction>` key bound to exactly the same D-pad input is cleared, so one
// press is not both a stick push and a D-pad press. Wii profiles have no `Main Stick/` keys.
inline std::map<std::string, std::string>
MainStickFromDPadFallback(const std::function<std::string(const std::string&)>& value_for_key,
                          const std::function<bool(const std::string&)>& has_input)
{
  struct Direction
  {
    const char* name;
    const char* stick_input;
    const char* dpad_input;
  };
  static constexpr std::array<Direction, 4> directions{{
      {"Up", "L Stick Y+", "D-Pad Up"},
      {"Down", "L Stick Y-", "D-Pad Down"},
      {"Left", "L Stick X-", "D-Pad Left"},
      {"Right", "L Stick X+", "D-Pad Right"},
  }};
  const auto quoted = [](const char* input) { return "`" + std::string(input) + "`"; };
  const auto trimmed = [](const std::string& value) {
    const auto first = value.find_first_not_of(" \t");
    if (first == std::string::npos)
      return std::string();
    return value.substr(first, value.find_last_not_of(" \t") - first + 1);
  };

  for (const Direction& direction : directions)
  {
    if (has_input(direction.stick_input) || !has_input(direction.dpad_input) ||
        trimmed(value_for_key(std::string("Main Stick/") + direction.name)) !=
            quoted(direction.stick_input))
    {
      return {};
    }
  }

  std::map<std::string, std::string> changes;
  for (const Direction& direction : directions)
  {
    changes[std::string("Main Stick/") + direction.name] = quoted(direction.dpad_input);
    const std::string dpad_key = std::string("D-Pad/") + direction.name;
    if (trimmed(value_for_key(dpad_key)) == quoted(direction.dpad_input))
      changes[dpad_key] = "";
  }
  return changes;
}

// Applies MainStickFromDPadFallback to a profile section about to be loaded for `device`.
// Does nothing without a device.
inline void ApplyMainStickFromDPadFallback(Common::IniFile::Section* section,
                                           const ciface::Core::Device* device)
{
  if (!section || !device)
    return;
  const auto changes = MainStickFromDPadFallback(
      [&](const std::string& key) {
        std::string value;
        section->Get(key, &value, "");
        return value;
      },
      [&](const std::string& input) {
        for (const auto* candidate : device->Inputs())
        {
          if (candidate->GetName() == input)
            return true;
        }
        return false;
      });
  for (const auto& [key, value] : changes)
    section->Set(key, value);
}
