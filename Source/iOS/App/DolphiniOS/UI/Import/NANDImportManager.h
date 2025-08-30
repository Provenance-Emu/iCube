#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface NANDImportManagerObjC : NSObject
/// Starts importing a BootMii NAND backup from the given URL. Presents a progress alert while importing.
+ (void)importNANDFromURL:(NSURL *)url;
@end

NS_ASSUME_NONNULL_END
