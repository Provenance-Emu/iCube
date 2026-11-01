// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "DOLNFCCapability.h"
#import <TargetConditionals.h>

#if TARGET_OS_IOS && !TARGET_OS_SIMULATOR && !TARGET_OS_MACCATALYST
#import <CoreNFC/CoreNFC.h>
#import <UIKit/UIKit.h>
#endif

BOOL DOLNFCReadingAvailable(void)
{
#if TARGET_OS_IOS && !TARGET_OS_SIMULATOR && !TARGET_OS_MACCATALYST
  @try
  {
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone)
      return NO;
    return NFCNDEFReaderSession.readingAvailable;
  }
  @catch (NSException* exception)
  {
    // ICUBE-KX: CoreNFC's XPC proxy can throw NSInvalidArgumentException.
    // Contain it entirely in Objective-C; Swift cannot catch NSException.
    return NO;
  }
#else
  return NO;
#endif
}
