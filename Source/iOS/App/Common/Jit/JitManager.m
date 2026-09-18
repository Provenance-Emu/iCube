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
@property (readwrite, assign) bool debuggerAttached;
@property (readwrite, assign) bool txmAuthorized;

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

  // Live P_TRACED read: StikDebug may attach AFTER launch (URL hand-off), and it
  // detaches again once the TXM handshake is answered.
  self.debuggerAttached = [self checkIfDebuggerAttachedNow];

  if (_jitType == DOLJitTypeDebugger) {
    if (self.deviceHasTxm) {
      if ([self checkIfRunningUnderXcode]) {
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
    
    if (self.deviceHasTxm && self.acquiredJit && !self.txmAuthorized) {
      self.acquisitionError = self.debuggerAttached
          ? @"A debugger is attached. On iOS 26 TXM devices the JIT region is authorized by StikDebug's script when a game boots; other debuggers fall back to Cached Interpreter."
          : @"JIT was acquired but no debugger is attached now. On iOS 26 TXM devices, launch iCube through StikDebug (Enable JIT via StikDebug) so its script can authorize the JIT region; otherwise games use the Cached Interpreter.";
    }
  } else if (_jitType == DOLJitTypeUnrestricted) {
    self.acquiredJit = true;
  }
}

- (bool)shouldAttemptTXMHandshake {
  if (!self.deviceHasTxm || !self.acquiredJit) {
    return false;
  }

  // Test/debug override. "1" forces the handshake even without a live debugger
  // (the SIGTRAP net in AllocateExecutableMemoryRegion_LuckTXM then turns an
  // unanswered brk into a clean interpreter fallback); "0" disables it outright.
  NSString* override = [[NSProcessInfo processInfo] environment][@"DOL_JIT_TXM"];
  if ([override isEqualToString:@"1"]) {
    return true;
  }
  if ([override isEqualToString:@"0"]) {
    return false;
  }

  // Auto-detect: a broker can only answer the brk if a debugger is attached right
  // now, and LLDB (Xcode) would trap it instead of answering. CS_DEBUGGED alone is
  // not enough — old-style JIT enablers set it and detach immediately.
  return [self checkIfDebuggerAttachedNow] && ![self checkIfRunningUnderXcode];
}

- (void)noteTXMHandshakeResult:(bool)authorized {
  self.txmAuthorized = authorized;
  if (authorized) {
    self.acquisitionError = nil;
  }
}

@end
