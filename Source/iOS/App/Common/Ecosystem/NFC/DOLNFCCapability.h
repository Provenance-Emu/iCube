// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

/// Synchronous system probe. Call from the background capability cache, never a UI body.
/// Unsupported hardware and Objective-C failures both return NO.
FOUNDATION_EXPORT BOOL DOLNFCReadingAvailable(void);
