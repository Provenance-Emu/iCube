#import "NANDImportManager.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "LocalizationUtil.h"
#import "DiscIO/NANDImporter.h"
#import "FoundationStringUtil.h"
#import "MsgHandler.h"

@implementation NANDImportManagerObjC

+ (UIViewController *)_topViewController {
  UIWindow *window = UIApplication.sharedApplication.windows.firstObject;
  UIViewController *root = window.rootViewController ?: [UIViewController new];
  UIViewController *top = root;
  while (top.presentedViewController) { top = top.presentedViewController; }
  return top;
}

+ (void)importNANDFromURL:(NSURL *)url {
  if (![url startAccessingSecurityScopedResource]) {
    UIAlertController* errorAlert = [UIAlertController alertControllerWithTitle:DOLCoreLocalizedString(@"Error") message:@"Failed to start accessing security scoped resource." preferredStyle:UIAlertControllerStyleAlert];
    [errorAlert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"OK") style:UIAlertActionStyleDefault handler:nil]];
    [[self _topViewController] presentViewController:errorAlert animated:YES completion:nil];
    return;
  }

  UIAlertController* waitAlert = [UIAlertController alertControllerWithTitle:DOLCoreLocalizedString(@"Importing NAND backup") message:nil preferredStyle:UIAlertControllerStyleAlert];

  [[self _topViewController] presentViewController:waitAlert animated:YES completion:^{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      DiscIO::NANDImporter().ImportNANDBin(FoundationToCppString(url.path), [] {
        // GUI update callback (unused)
      }, [] {
        PanicAlertFmtT("The decryption keys need to be appended to the NAND backup file.");
        return std::string("");
      });

      [url stopAccessingSecurityScopedResource];

      dispatch_async(dispatch_get_main_queue(), ^{
        [waitAlert dismissViewControllerAnimated:YES completion:nil];
      });
    });
  }];
}

@end
