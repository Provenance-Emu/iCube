// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Creates a `CKContainer` where an Objective-C exception can be caught.
///
/// On a device whose signed iCloud entitlements are malformed, `CKContainer`'s
/// initializer raises `CKException` ("Found value \"*\" for entitlement
/// com.apple.developer.icloud-services, expected an array of strings"). Re-signing
/// tools produce exactly that from a wildcard profile, and PVCloudSync's
/// provisioning-profile check does not see it. Swift cannot catch the exception, so
/// it aborted every launch (Sentry ICUBE-HY, GY, J5).
///
/// Only call this once `CloudKitAvailability.buildLevelUnavailableReason` is nil: on
/// the simulator the initializer traps instead of raising, and nothing catches that.
@interface DOLCloudKitProbe : NSObject

/// YES when a container for `identifier` can be created on this install.
+ (BOOL)canCreateContainerWithIdentifier:(NSString *)identifier;

/// YES when `block` returns without raising an Objective-C exception. The catch
/// happens here, in an Objective-C frame.
+ (BOOL)succeedsWithoutException:(NS_NOESCAPE void (^)(void))block;

@end

NS_ASSUME_NONNULL_END
