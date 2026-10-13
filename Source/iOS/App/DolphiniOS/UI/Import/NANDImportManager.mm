#import "NANDImportManager.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "LocalizationUtil.h"
#import "Common/FileUtil.h"
#import "DiscIO/NANDImporter.h"
#import "FoundationStringUtil.h"
#import "MsgHandler.h"

// ImportNANDBin returns void, so a finished import is recognised by its last step: ExtractCertificates
// writes these files only after the NAND image was read and every file was extracted.
static BOOL NANDImportWroteCertificates(NSDate *since) {
  NSString *wiiRoot = CppToFoundationString(File::GetUserPath(D_WIIROOT_IDX));
  for (NSString *name in @[@"clientca.pem", @"clientcakey.pem", @"rootca.pem"]) {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:[wiiRoot stringByAppendingPathComponent:name] error:nil];
    NSDate *modified = attributes.fileModificationDate;
    if (modified == nil || [modified compare:since] == NSOrderedAscending) { return NO; }
  }
  return YES;
}

@implementation NANDImportManagerObjC

+ (UIViewController *)_topViewController {
  UIWindow *window = UIApplication.sharedApplication.windows.firstObject;
  UIViewController *root = window.rootViewController ?: [UIViewController new];
  UIViewController *top = root;
  while (top.presentedViewController) { top = top.presentedViewController; }
  return top;
}

+ (void)importNANDFromURL:(NSURL *)url {
  [self importNANDFromURL:url completion:nil];
}

+ (void)importNANDFromURL:(NSURL *)url completion:(void (^)(BOOL success))completion {
  [self importNANDFromURL:url keysURL:nil completion:completion];
}

+ (void)importNANDFromURL:(NSURL *)url keysURL:(NSURL *)keysURL completion:(void (^)(BOOL success))completion {
  // Only a picked file is security scoped. A file inside the app container (a Web UI upload on tvOS)
  // answers NO here and is readable all the same.
  BOOL scoped = [url startAccessingSecurityScopedResource];
  if (!scoped && ![NSFileManager.defaultManager isReadableFileAtPath:url.path]) {
    UIAlertController* errorAlert = [UIAlertController alertControllerWithTitle:DOLCoreLocalizedString(@"Error") message:@"Failed to start accessing security scoped resource." preferredStyle:UIAlertControllerStyleAlert];
    [errorAlert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"OK") style:UIAlertActionStyleDefault handler:nil]];
    [[self _topViewController] presentViewController:errorAlert animated:YES completion:nil];
    if (completion) { completion(NO); }
    return;
  }

  // The alert is cosmetic: the import and `completion` never wait for it, so a dropped presentation
  // (another one in flight) can't leave a caller waiting forever.
  UIAlertController* waitAlert = [UIAlertController alertControllerWithTitle:DOLCoreLocalizedString(@"Importing NAND backup") message:nil preferredStyle:UIAlertControllerStyleAlert];
  [[self _topViewController] presentViewController:waitAlert animated:YES completion:nil];

  std::string keysPath = keysURL ? FoundationToCppString(keysURL.path) : std::string();

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSDate *startedAt = [NSDate date];
    // 2606: the progress callback reports (step, current, total) and returns TRUE to cancel
    // (NANDImporter.h). Returning true here aborted the import on its first block.
    // The last argument is asked for the keys.bin of a dump that doesn't carry its keys; a Web UI
    // upload hands in the keys.bin the user uploaded before the dump.
    DiscIO::NANDImporter().ImportNANDBin(FoundationToCppString(url.path), [](DiscIO::NANDImporter::Step, int, int) {
      return false;  // GUI progress unused; never cancel
    }, [keysPath] {
      if (keysPath.empty())
        PanicAlertFmtT("The decryption keys need to be appended to the NAND backup file.");
      return keysPath;
    });

    if (scoped) { [url stopAccessingSecurityScopedResource]; }
    BOOL success = NANDImportWroteCertificates(startedAt);

    dispatch_async(dispatch_get_main_queue(), ^{
      if (waitAlert.presentingViewController != nil) {
        [waitAlert dismissViewControllerAnimated:YES completion:nil];
      }
      if (completion) { completion(success); }
    });
  });
}

@end
