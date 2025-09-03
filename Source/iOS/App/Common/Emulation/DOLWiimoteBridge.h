#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DOLWiimoteBridge : NSObject
+ (BOOL)isClassicActiveForWiimote:(NSInteger)index;
+ (BOOL)isSidewaysForWiimote:(NSInteger)index;
@end

NS_ASSUME_NONNULL_END
