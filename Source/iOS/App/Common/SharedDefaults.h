// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Mirror of `LibrarySnapshotAppGroup.identifier` in Source/iOS/PVLibrarySnapshot. Keep identical.
FOUNDATION_EXPORT NSString * const DOLAppGroupIdentifier;

/// The App Group suite when this process is entitled to it, else standardUserDefaults.
/// Library state the extensions need (favorites, last played, added dates) lives here.
FOUNDATION_EXPORT NSUserDefaults *DOLSharedUserDefaults(void);

NS_ASSUME_NONNULL_END
