// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

/// Posted to boot a disc that is not a library tile (a cached patched copy). userInfo: `filePath`
/// (NSString) and `launchID` (NSString, unique per request). Post it through `DiscPatchFlow.launch(path:)`,
/// which also fills `launchID`; the library screen answers it.
FOUNDATION_EXPORT NSNotificationName const DOLLaunchGameAtPathNotification;

/// Posted to open the "Play with Mods" sheet for a library game, for example after the mod browser
/// installed a Riivolution pack for it. userInfo: `gameID` (NSString). The library screen answers it.
FOUNDATION_EXPORT NSNotificationName const DOLShowModsForGameNotification;
