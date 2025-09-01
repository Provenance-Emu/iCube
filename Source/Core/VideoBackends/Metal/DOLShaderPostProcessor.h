#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

@interface DOLShaderPostProcessor : NSObject
@property (nonatomic, strong) id<MTLDevice> device;
+ (instancetype)shared;
- (void)configureWithDevice:(id<MTLDevice>)device;
- (void)renderSource:(id<MTLTexture>)source commandBuffer:(id<MTLCommandBuffer>)cb drawable:(id<CAMetalDrawable>)drawable;
@end
