// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "JitManager.h"

#import "JitManager+Debugger.h"

typedef NS_ENUM(NSInteger, DOLJitType) {
  DOLJitTypeDebugger,
  DOLJitTypeUnrestricted
};

@interface JitManager ()

@property (readwrite, assign) bool acquiredJit;
@property (readwrite, assign) bool deviceHasTxm;

@end

@implementation JitManager {
  DOLJitType _jitType;
}

+ (JitManager*)shared {
  static JitManager* sharedInstance = nil;
  static dispatch_once_t onceToken;

  dispatch_once(&onceToken, ^{
    sharedInstance = [[self alloc] init];
  });

  return sharedInstance;
}

- (id)init {
  if (self = [super init]) {
#if TARGET_OS_SIMULATOR
    _jitType = DOLJitTypeUnrestricted;
#else
    _jitType = DOLJitTypeDebugger;
#endif
    
    self.acquiredJit = false;
    
    if (@available(iOS 26, *)) {
      self.deviceHasTxm = [self checkIfDeviceUsesTXM];
    } else {
      // This is technically untrue on some devices, but it only matters on iOS 26 or above.
      self.deviceHasTxm = false;
    }
  }
  
  return self;
}

- (void)recheckIfJitIsAcquired {
  if (_jitType == DOLJitTypeDebugger) {
    if (self.deviceHasTxm) {
      NSDictionary* environment = [[NSProcessInfo processInfo] environment];

      // Detect Xcode's debugger automatically:
      //   XCODE         — manually added to the Xcode scheme's environment variables
      //   OS_ACTIVITY_DT_MODE — set automatically by Xcode when debugging on a real device
      //                          (routes os_log to Xcode console; not set by StikDebug)
      // On a TXM device the LuckTXM brk #0x69 handshake is only handled by StikDebug;
      // LLDB will intercept it and raise EXC_BREAKPOINT instead.
      BOOL isXcodeDebugger =
          [environment objectForKey:@"XCODE"] != nil ||
          [environment objectForKey:@"OS_ACTIVITY_DT_MODE"] != nil;

      if (isXcodeDebugger) {
        static dispatch_once_t onceToken;

        dispatch_once(&onceToken, ^{
          self.acquisitionError = @"JIT cannot be enabled while running within Xcode on iOS 26. "
                                   "To debug with JIT, use StikDebug instead. "
                                   "If you intentionally want to suppress this, add XCODE=1 to your scheme's environment variables.";
        });

        return;
      }
    }
    
    self.acquiredJit = [self checkIfProcessIsDebugged];
    
    if (self.deviceHasTxm && self.acquiredJit) {
      self.acquisitionError = @"A debugger is attached. However, if the debugger is not StikDebug, DolphiniOS will crash when emulation starts.";
    }
  } else if (_jitType == DOLJitTypeUnrestricted) {
    self.acquiredJit = true;
  }
}

@end
