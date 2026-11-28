// Copyright 2022 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <functional>
#include <string>

#include "Common/Common.h"
#include "Common/CommonTypes.h"

namespace Common
{
static constexpr auto SD_PACK_TEXT = _trans("Pack SD Card Now");
static constexpr auto SD_UNPACK_TEXT = _trans("Unpack SD Card Now");

bool SyncSDFolderToSDImage(const std::function<bool()>& cancelled, bool deterministic);
bool SyncSDImageToSDFolder(const std::function<bool()>& cancelled);

// The card behind the GameCube SD adapter (ExpansionInterface::EXIDeviceType::SD): a FAT image
// of one folder, which is the card's root.
constexpr u64 GC_SD_IMAGE_MIN_SIZE = 64ull * 1024 * 1024;
constexpr u64 GC_SD_IMAGE_MAX_SIZE = 2048ull * 1024 * 1024;
// The image size for files that need `content_size` bytes: a power of two between the two above.
u64 GCSDImageSize(u64 content_size);
bool PackFolderToGCSDImage(const std::string& folder, const std::string& image_path,
                           const std::function<bool()>& cancelled);
// Replaces `folder` with what the image holds. A failure leaves the folder as it was.
bool UnpackGCSDImageToFolder(const std::string& image_path, const std::string& folder,
                             const std::function<bool()>& cancelled);

class FatFsCallbacks
{
public:
  FatFsCallbacks();
  virtual ~FatFsCallbacks();

  virtual u8 DiskInitialize(u8 pdrv);
  virtual u8 DiskStatus(u8 pdrv);
  virtual int DiskRead(u8 pdrv, u8* buff, u32 sector, unsigned int count) = 0;
  virtual int DiskWrite(u8 pdrv, const u8* buff, u32 sector, unsigned int count) = 0;
  virtual int DiskIOCtl(u8 pdrv, u8 cmd, void* buff) = 0;
  virtual u32 GetCurrentTimeFAT();
};

void RunInFatFsContext(FatFsCallbacks& callbacks, const std::function<void()>& function);
}  // namespace Common
