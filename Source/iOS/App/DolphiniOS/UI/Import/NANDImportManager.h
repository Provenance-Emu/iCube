#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface NANDImportManagerObjC : NSObject
/// Starts importing a BootMii NAND backup from the given URL. Presents a progress alert while importing.
+ (void)importNANDFromURL:(NSURL *)url;
/// Same, and calls `completion` on the main queue once the alert is dismissed. `success` is YES only when
/// the import ran to its last step (the importer itself reports nothing), so a caller can delete its copy of
/// the backup after a good import and keep it after a bad one.
+ (void)importNANDFromURL:(NSURL *)url completion:(void (^_Nullable)(BOOL success))completion;
/// Same, for a dump without its keys appended: `keysURL` is the keys.bin that goes with it (nil if there is none).
+ (void)importNANDFromURL:(NSURL *)url keysURL:(NSURL *_Nullable)keysURL completion:(void (^_Nullable)(BOOL success))completion;
@end

NS_ASSUME_NONNULL_END
