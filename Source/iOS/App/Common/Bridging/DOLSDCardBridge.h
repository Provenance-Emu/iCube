// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// The emulator core's GameCube SD card: a FAT image of one folder, read by an SD adapter in
// memory card slot B. Paths are UTF-8.

// Packs `folder` into a new image at `imagePath`, sized for what the folder holds.
bool DOLSDCardPackFolder(const char* folder, const char* imagePath);

// Unpacks the image into `folder`, replacing whatever is there.
bool DOLSDCardUnpackImage(const char* imagePath, const char* folder);

// Puts the adapter and this image in slot B for the run about to boot, and tells the program
// where on the card it was started from (`programPath`, such as "/apps/name/name.dol"), as a
// loader on a console does. Nothing is saved to the user's settings.
void DOLSDCardInsertForThisRun(const char* imagePath, const char* programPath);

// Takes it out again, so the next boot has the user's own slot B.
void DOLSDCardRemoveForThisRun(void);

#ifdef __cplusplus
}
#endif
