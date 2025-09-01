#import "ExternalDisplayManager.h"

#if TARGET_OS_IOS
CAMetalLayer* _Nullable g_dol_external_metal_layer = nil;
CAMetalLayer* _Nullable DOLGetExternalMetalLayer(void) { return g_dol_external_metal_layer; }
#endif
