// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>
@class GCController;
NS_ASSUME_NONNULL_BEGIN
/// Exact-controller gameplay suppression; does not replace physical input handlers or bindings.
@interface DOLControllerInputLease : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithController:(GCController*)controller NS_DESIGNATED_INITIALIZER;
/// Begin release. Suppression remains until buttons and axes are physically neutral.
- (void)requestRelease;
/// Call during a closing-release fence; backend polling also completes pending releases.
/// Returns YES after disconnect or when no nested lease/pending-neutral fence suppresses it.
- (BOOL)pollRelease;
/// Only for actual controller disconnect. Old native wrappers remain permanently neutral.
- (void)forceReleaseForDisconnect;
@end
NS_ASSUME_NONNULL_END
