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
@property (readwrite, assign) bool jitSupported;

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

    // JIT is supported iff the process is debuggable (carries get-task-allow): that
    // is the universal precondition for enabling JIT on iOS. Determined at runtime
    // for non-App-Store builds so it adapts to how the binary is actually run —
    // sideload / jailbreak / TrollStore / dev builds are debuggable (flag present
    // → true), normal App Store / TestFlight installs are jitless (flag stripped).
    //
    // App Store builds are jitless by contract: hard-lock JIT off at compile time so
    // the App Store scheme stays jitless even when dev-signed for local testing
    // (dev-signing carries get-task-allow, and Xcode sets CS_DEBUGGED on attach,
    // which would otherwise make the runtime check report JIT as available and lead
    // the boot path to attempt the LuckTXM handshake and crash).
#if APPSTORE
    self.jitSupported = false;
#else
    self.jitSupported = [self checkIfProcessIsJitCapable];
#endif
    
    if (@available(iOS 26, tvOS 26, *)) {
      self.deviceHasTxm = [self checkIfDeviceUsesTXM];
    } else {
      // This is technically untrue on some devices, but it only matters on iOS 26 or above.
      self.deviceHasTxm = false;
    }
  }
  
  return self;
}

- (void)recheckIfJitIsAcquired {
  // Builds that cannot support JIT at all (App Store / jitless) must never acquire
  // it, even with a debugger attached — Xcode sets CS_DEBUGGED on any attached
  // process, and a dev-signed App Store binary carries get-task-allow, either of
  // which would otherwise flip acquiredJit true and drive the boot path into the
  // JIT/LuckTXM handshake. Hard-stop here keeps such builds jitless and crash-free.
  if (!self.jitSupported) {
    self.acquiredJit = false;
    return;
  }

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
      self.acquisitionError = @"A debugger is attached. On iOS 26 TXM devices, StikDebug 2.3.0+ is required for full JIT. Other enablers fall back to Cached Interpreter.";
    }
  } else if (_jitType == DOLJitTypeUnrestricted) {
    self.acquiredJit = true;
  }
}

@end
