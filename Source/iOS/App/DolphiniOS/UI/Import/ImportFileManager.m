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

  // Archive imports: extract on a background queue so the UI stays responsive.
  // Security-scoped access must remain active for the duration of extraction.
  if ([DOLZipImportHelper isArchivePath:sourcePath]) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      DOLZipImportResult* result = [DOLZipImportHelper importArchiveAtPath:sourcePath toFolder:softwareFolder];

      dispatch_async(dispatch_get_main_queue(), ^{
        if (result.importedCount > 0 || result.skippedExistingCount > 0) {
          NSString* snackbar = [DOLZipImportHelper snackbarTextForImportedCount:result.importedCount
                                                                     skippedCount:result.skippedExistingCount
                                                                archivesProcessed:1];
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

  [alert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"Copy") style:UIAlertActionStyleDefault
    handler:^(UIAlertAction* action) {
    NSError* error = nil;
    if (![fileManager copyItemAtPath:sourcePath toPath:destinationPath error:&error]) {
      UIAlertController* errorAlert = [UIAlertController alertControllerWithTitle:DOLCoreLocalizedString(@"Error") message:[NSString stringWithFormat:@"The copy operation failed.\n\n%@", error.localizedDescription] preferredStyle:UIAlertControllerStyleAlert];
      
      [errorAlert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"OK") style:UIAlertActionStyleDefault
        handler:^(UIAlertAction* action) {
        finish();
      }]];
      
      [self presentViewControllerOnWindow:errorAlert];
    } else {
      [LibraryAddedDateStoreBridge recordPath:destinationPath];
      finish();
    }
  }]];
  
  [alert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"Move") style:UIAlertActionStyleDefault
    handler:^(UIAlertAction* action) {
    NSError* error = nil;
    if (![fileManager moveItemAtPath:sourcePath toPath:destinationPath error:&error]) {
      UIAlertController* errorAlert = [UIAlertController alertControllerWithTitle:DOLCoreLocalizedString(@"Error") message:[NSString stringWithFormat:@"The move operation failed.\n\n%@", error.localizedDescription] preferredStyle:UIAlertControllerStyleAlert];
      
      [errorAlert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"OK") style:UIAlertActionStyleDefault
        handler:^(UIAlertAction* action) {
        finish();
      }]];
      
      [self presentViewControllerOnWindow:errorAlert];
    } else {
      [LibraryAddedDateStoreBridge recordPath:destinationPath];
      finish();
    }
  }]];
  
  [alert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"Cancel") style:UIAlertActionStyleCancel
    handler:^(UIAlertAction* action) {
    finish();
  }]];
  
  [self presentViewControllerOnWindow:alert];
}

@end
