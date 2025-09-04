#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DOLWiimoteBridge : NSObject
+ (BOOL)isClassicActiveForWiimote:(NSInteger)index;
+ (BOOL)isSidewaysForWiimote:(NSInteger)index;
+ (void)setExtensionForWiimote:(NSInteger)index extension:(NSInteger)extRaw;
+ (void)setSidewaysForWiimote:(NSInteger)index enabled:(BOOL)enabled;
@end

NS_ASSUME_NONNULL_END
