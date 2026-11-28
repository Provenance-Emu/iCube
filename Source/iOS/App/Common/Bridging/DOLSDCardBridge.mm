// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "DOLSDCardBridge.h"

#include "Common/Config/Config.h"
#include "Common/FatFsUtil.h"
#include "Core/Config/MainSettings.h"
#include "Core/HW/EXI/EXI_Device.h"

static bool NeverCancelled()
{
  return false;
}

extern "C" bool DOLSDCardPackFolder(const char* folder, const char* imagePath)
{
  return Common::PackFolderToGCSDImage(folder, imagePath, NeverCancelled);
}

extern "C" bool DOLSDCardUnpackImage(const char* imagePath, const char* folder)
{
  return Common::UnpackGCSDImageToFolder(imagePath, folder, NeverCancelled);
}

extern "C" void DOLSDCardInsertForThisRun(const char* imagePath)
{
  Config::SetCurrent(Config::MAIN_GC_SD_CARD_PATH, std::string(imagePath));
  Config::SetCurrent(Config::MAIN_SLOT_B, ExpansionInterface::EXIDeviceType::SD);
}

extern "C" void DOLSDCardRemoveForThisRun(void)
{
  if (!Config::GetLayer(Config::LayerType::CurrentRun))
    return;
  Config::DeleteKey(Config::LayerType::CurrentRun, Config::MAIN_SLOT_B);
  Config::DeleteKey(Config::LayerType::CurrentRun, Config::MAIN_GC_SD_CARD_PATH);
}
