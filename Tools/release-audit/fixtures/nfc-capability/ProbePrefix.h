// Load native Foundation first, then select the production iPhone branch.
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#undef TARGET_OS_IOS
#define TARGET_OS_IOS 1
#if defined(NFC_FIXTURE_SIMULATOR)
#undef TARGET_OS_SIMULATOR
#define TARGET_OS_SIMULATOR 1
#elif defined(NFC_FIXTURE_TV)
#undef TARGET_OS_IOS
#define TARGET_OS_IOS 0
#endif
