// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
#import "DOLCloudKitProbe.h"

#import <CloudKit/CloudKit.h>

#import "ICubeLog.h"

@implementation DOLCloudKitProbe

+ (BOOL)canCreateContainerWithIdentifier:(NSString *)identifier {
  // The container is created inside this Objective-C block, so a raise never
  // unwinds through Swift frames.
  return [self succeedsWithoutException:^{
    (void)[CKContainer containerWithIdentifier:identifier];
  }];
}

+ (BOOL)succeedsWithoutException:(NS_NOESCAPE void (^)(void))block {
  @try {
    block();
    return YES;
  } @catch (NSException* exception) {
    DOLDebugLog(@"[CloudSync] container probe raised %@: %@", exception.name, exception.reason);
    return NO;
  }
}

@end
