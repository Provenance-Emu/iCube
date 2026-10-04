// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

// C++ only: not for the Swift bridging header.

#pragma once

#include "Common/CommonTypes.h"
#include "Common/IniFile.h"
#include "InputCommon/ControllerEmu/ControlGroup/Attachments.h"
#include "InputCommon/ControllerEmu/ControllerEmu.h"

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
