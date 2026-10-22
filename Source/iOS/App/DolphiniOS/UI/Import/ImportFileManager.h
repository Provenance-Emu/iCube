// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

#import <UIKit/UIKit.h>

FOUNDATION_EXPORT NSString* _Nonnull const DOLImportFileFinishedNotification;

NS_ASSUME_NONNULL_BEGIN

@interface ImportFileManager : NSObject

+ (ImportFileManager*)shared;

- (void)importFileAtUrl:(NSURL*)url;
/// Window helpers used by the Swift batch-import extension.
- (void)showWindowOnScene:(UIWindowScene*)scene;
- (void)hideWindow;
- (void)presentViewControllerOnWindow:(UIViewController*)controller;

@end

/// Implemented in Swift (`ImportFileManager+BatchImport.swift`).
@interface ImportFileManager (BatchImport)

- (void)importFilesAtUrls:(NSArray<NSURL*>*)urls;

@end

NS_ASSUME_NONNULL_END
