#import <Foundation/Foundation.h>
typedef NS_ENUM(NSInteger, UIUserInterfaceIdiom) {
    UIUserInterfaceIdiomPhone, UIUserInterfaceIdiomPad
};
@interface UIDevice : NSObject
@property(class, readonly) UIDevice *currentDevice;
@property(readonly) UIUserInterfaceIdiom userInterfaceIdiom;
@end
