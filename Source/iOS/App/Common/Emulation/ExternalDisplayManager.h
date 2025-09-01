#import <Foundation/Foundation.h>
#if TARGET_OS_IOS
#import <QuartzCore/CAMetalLayer.h>

#ifdef __cplusplus
extern "C" {
#endif

extern CAMetalLayer* _Nullable g_dol_external_metal_layer;
CAMetalLayer* _Nullable DOLGetExternalMetalLayer(void);

#ifdef __cplusplus
}
#endif
#endif
