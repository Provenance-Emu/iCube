#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import "DOLShaderPostProcessor.h"

@implementation DOLShaderPostProcessor
+ (instancetype)shared {
  static DOLShaderPostProcessor* s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ s = [DOLShaderPostProcessor new]; });
  return s;
}
- (void)configureWithDevice:(id<MTLDevice>)device { self.device = device; }
- (void)renderSource:(id<MTLTexture>)source commandBuffer:(id<MTLCommandBuffer>)cb drawable:(id<CAMetalDrawable>)drawable {
  if (!source || !cb || !drawable) return;
  id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
  if (!blit) return;
  MTLSize size = MTLSizeMake(drawable.texture.width, drawable.texture.height, 1);
  [blit copyFromTexture:source
            sourceSlice:0
            sourceLevel:0
           sourceOrigin:MTLOriginMake(0, 0, 0)
             sourceSize:size
              toTexture:drawable.texture
       destinationSlice:0
       destinationLevel:0
      destinationOrigin:MTLOriginMake(0, 0, 0)];
  [blit endEncoding];
}
@end
