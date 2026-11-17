// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "ImportFileManager.h"

NSString* const DOLImportFileFinishedNotification = @"DOLImportFileFinishedNotification";

#import "Swift.h"

#import "GameFileCacheManager.h"
#import "LocalizationUtil.h"
#import "MainSceneCoordinator.h"

@implementation ImportFileManager {
  UIWindow* _window;
}

+ (ImportFileManager*)shared {
  static ImportFileManager* sharedInstance = nil;
  static dispatch_once_t onceToken;

  dispatch_once(&onceToken, ^{
    sharedInstance = [[self alloc] init];
  });

  return sharedInstance;
}

- (void)showWindowOnScene:(UIWindowScene*)scene {
  self->_window = [[UIWindow alloc] initWithWindowScene:scene];
  self->_window.frame = [UIScreen mainScreen].bounds;
  self->_window.rootViewController = [[UIViewController alloc] init];
  self->_window.windowLevel = UIWindowLevelAlert;
  
  UIWindow* topWindow = scene.windows.lastObject;
  self->_window.windowLevel = topWindow.windowLevel + 1;
  
  [self->_window makeKeyAndVisible];
}

- (void)hideWindow {
  [self->_window setHidden:true];
  
  self->_window = nil;
}

- (void)presentViewControllerOnWindow:(UIViewController*)controller {
  [self->_window.rootViewController presentViewController:controller animated:true completion:nil];
}

- (void)importFileAtUrl:(NSURL*)url {
  UIWindowScene* mainScene = [MainSceneCoordinator shared].mainScene;
  
  if (mainScene == nil) {
    return;
  }
  
  [self showWindowOnScene:mainScene];
  
  if (![url startAccessingSecurityScopedResource]) {
    UIAlertController* errorAlert = [UIAlertController alertControllerWithTitle:DOLCoreLocalizedString(@"Error") message:@"Failed to start accessing security scoped resource." preferredStyle:UIAlertControllerStyleAlert];
    
    [errorAlert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"OK") style:UIAlertActionStyleDefault
      handler:^(UIAlertAction* action) {
      [self hideWindow];
    }]];
    
    [self presentViewControllerOnWindow:errorAlert];
    
    return;
  }
  
  void (^finish)(void) = ^void() {
    [url stopAccessingSecurityScopedResource];
    
    [self hideWindow];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:DOLImportFileFinishedNotification object:self userInfo:nil];
  };
  
  NSString* sourcePath = [url path];
  NSString* softwareFolder = [UserFolderUtil getSoftwareFolder];
  NSString* destinationPath = [softwareFolder stringByAppendingPathComponent:[sourcePath lastPathComponent]];

  NSFileManager* fileManager = [NSFileManager defaultManager];
  [DOLImportStaging removeStaleStagedImportsInFolder:softwareFolder];

  // Archive imports: extract on a background queue so the UI stays responsive.
  // Security-scoped access must remain active for the duration of extraction. The picked
  // archive is copied into a private temp dir first and is never modified.
  if ([DOLZipImportHelper isArchivePath:sourcePath]) {
    // No UIKit background task here, as before; on iOS 26 a large archive also gets a
    // continued-processing task (its progress moves in one step when the extraction ends).
    DOLImportKeepAlive* archiveKeepAlive = [DOLImportKeepAlive beginWithPaths:@[sourcePath] holdsLegacyTask:NO];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      DOLZipImportResult* result = [DOLZipImportHelper importPickedArchiveAtURL:url toFolder:softwareFolder];

      dispatch_async(dispatch_get_main_queue(), ^{
        [archiveKeepAlive endWithSuccess:result.succeeded];
        if (result.succeeded) {
          NSMutableArray<NSString*>* snackbarLines = [NSMutableArray array];
          if (result.installedPackMessage != nil) {
            [snackbarLines addObject:result.installedPackMessage];
          }
          if (result.importedCount > 0 || result.skippedExistingCount > 0) {
            [snackbarLines addObject:[DOLZipImportHelper snackbarTextForImportedCount:result.importedCount
                                                                          skippedCount:result.skippedExistingCount
                                                                     archivesProcessed:1]];
          }
          NSString* snackbar = [snackbarLines componentsJoinedByString:@"\n"];
          [[NSNotificationCenter defaultCenter] postNotificationName:@"DOLShowSnackbar"
                                                              object:nil
                                                            userInfo:@{@"text": snackbar}];

          if (result.errorMessage != nil) {
            UIAlertController* warningAlert = [UIAlertController alertControllerWithTitle:DOLCoreLocalizedString(@"Import") message:result.errorMessage preferredStyle:UIAlertControllerStyleAlert];
            [warningAlert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"OK") style:UIAlertActionStyleDefault
              handler:^(UIAlertAction* action) {
              finish();
            }]];
            [self presentViewControllerOnWindow:warningAlert];
          } else {
            finish();
          }
        } else if (result.errorMessage != nil) {
          UIAlertController* errorAlert = [UIAlertController alertControllerWithTitle:DOLCoreLocalizedString(@"Error") message:result.errorMessage preferredStyle:UIAlertControllerStyleAlert];

          [errorAlert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"OK") style:UIAlertActionStyleDefault
            handler:^(UIAlertAction* action) {
            finish();
          }]];

          [self presentViewControllerOnWindow:errorAlert];
        } else {
          finish();
        }
      });
    });

    return;
  }

  if ([fileManager fileExistsAtPath:destinationPath]) {
    UIAlertController* errorAlert = [UIAlertController alertControllerWithTitle:DOLCoreLocalizedString(@"Error") message:@"This software has already been imported." preferredStyle:UIAlertControllerStyleAlert];
    
    [errorAlert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"OK") style:UIAlertActionStyleDefault
      handler:^(UIAlertAction* action) {
      finish();
    }]];
    
    [self presentViewControllerOnWindow:errorAlert];
    
    return;
  }
  
  UIAlertController* alert = [UIAlertController alertControllerWithTitle:DOLCoreLocalizedString(@"Import") message:nil preferredStyle:UIAlertControllerStyleAlert];

  // Both actions run the file operation OFF the main thread (a 1.4 GB copy on main is a
  // watchdog-length hang), through DOLImportStaging (staged + size-verified, so an interrupted
  // copy never leaves a truncated file under the real name), and inside a background task so
  // leaving the app mid-copy does not suspend it half-written.
  // On iOS 26 a large import is also a continued-processing task: it keeps running after the
  // user leaves the app, shows system progress, and stops when the system UI cancels it.
  void (^runFileOperation)(NSString*, BOOL (^)(DOLImportKeepAlive*, NSError**)) = ^(NSString* verb, BOOL (^operation)(DOLImportKeepAlive*, NSError**)) {
    DOLImportKeepAlive* keepAlive = [DOLImportKeepAlive beginWithPaths:@[sourcePath] holdsLegacyTask:YES];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSError* error = nil;
      const BOOL ok = operation(keepAlive, &error);
      dispatch_async(dispatch_get_main_queue(), ^{
        const BOOL stopped = !ok && keepAlive.isCancelled;
        [keepAlive endWithSuccess:ok];
        if (stopped) {
          [[NSNotificationCenter defaultCenter] postNotificationName:@"DOLShowSnackbar"
                                                              object:nil
                                                            userInfo:@{@"text": DOLCoreLocalizedString(@"Import stopped.")}];
          finish();
        } else if (!ok) {
          UIAlertController* errorAlert = [UIAlertController alertControllerWithTitle:DOLCoreLocalizedString(@"Error") message:[NSString stringWithFormat:@"The %@ operation failed.\n\n%@", verb, error.localizedDescription] preferredStyle:UIAlertControllerStyleAlert];
          [errorAlert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"OK") style:UIAlertActionStyleDefault
            handler:^(UIAlertAction* action) {
            finish();
          }]];
          [self presentViewControllerOnWindow:errorAlert];
        } else {
          [LibraryAddedDateStoreBridge recordPath:destinationPath];
          finish();
        }
      });
    });
  };

  [alert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"Copy") style:UIAlertActionStyleDefault
    handler:^(UIAlertAction* action) {
    runFileOperation(@"copy", ^BOOL(DOLImportKeepAlive* keepAlive, NSError** error) {
      return [DOLImportStaging stagedCopyFromPath:sourcePath toPath:destinationPath keepAlive:keepAlive itemIndex:0 error:error];
    });
  }]];
  
  [alert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"Move") style:UIAlertActionStyleDefault
    handler:^(UIAlertAction* action) {
    runFileOperation(@"move", ^BOOL(DOLImportKeepAlive* keepAlive, NSError** error) {
      return [DOLImportStaging stagedMoveFromPath:sourcePath toPath:destinationPath keepAlive:keepAlive itemIndex:0 error:error];
    });
  }]];
  
  [alert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"Cancel") style:UIAlertActionStyleCancel
    handler:^(UIAlertAction* action) {
    finish();
  }]];
  
  [self presentViewControllerOnWindow:alert];
}

@end
