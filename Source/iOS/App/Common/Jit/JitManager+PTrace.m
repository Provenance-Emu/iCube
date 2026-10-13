// Copyright 2023 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

// Based on PojavLauncher's JIT technique - thank you!

#import "JitManager+PTrace.h"

#import <dlfcn.h>
#import <spawn.h>

#import "FoundationStringUtil.h"
#import "JitManager+Debugger.h"

// SecTask is private API: resolved at runtime, never linked, so it leaves no undefined symbol in the binary.
typedef void* _Nullable (*DOLSecTaskCreateFromSelfFn)(CFAllocatorRef _Nullable allocator);
typedef CFTypeRef _Nullable (*DOLSecTaskCopyValueForEntitlementFn)(void* task, CFStringRef entitlement, CFErrorRef* _Nullable error);

#define PT_TRACE_ME 0
#define PT_DETACH 11
int ptrace(int request, pid_t pid, caddr_t caddr, int data);

extern char** environ;

const char* _Nonnull DOLJitPTraceChildProcessArgument = "ptraceChild";

@implementation JitManager (PTrace)

- (bool)checkCanAcquireJitByPTrace {
  // If we're out of the sandbox, then we can run ptrace.
  // We can check this by the presence of the "platform-application" private entitlement.
  DOLSecTaskCreateFromSelfFn createFromSelf = (DOLSecTaskCreateFromSelfFn)dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
  DOLSecTaskCopyValueForEntitlementFn copyValue = (DOLSecTaskCopyValueForEntitlementFn)dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
  
  if (createFromSelf == NULL || copyValue == NULL) {
    return false;
  }
  
  void* task = createFromSelf(NULL);
  
  if (task == NULL) {
    return false;
  }
  
  CFTypeRef entitlementValue = copyValue(task, CFSTR("platform-application"), NULL);
  bool result = entitlementValue == kCFBooleanTrue;
  
  if (entitlementValue != NULL) {
    CFRelease(entitlementValue);
  }
  
  CFRelease(task);
  
  return result;
}

- (void)runPTraceStartupTasks {
  // If a child process does PT_TRACE_ME, the parent process will also be marked as debugged.
  ptrace(PT_TRACE_ME, 0, NULL, 0);
}

- (void)acquireJitByPTrace {
  if (![self checkCanAcquireJitByPTrace]) {
    return;
  }
  
  const char* executablePath = FoundationToCString([[NSBundle mainBundle] executablePath]);
  const char* arguments[] = { executablePath, DOLJitPTraceChildProcessArgument, NULL };
  
  pid_t childPid;
  if (posix_spawnp(&childPid, executablePath, NULL, NULL, (char* const*)arguments, environ) == 0) {
    waitpid(childPid, NULL, WUNTRACED);
    ptrace(PT_DETACH, childPid, NULL, 0);
    kill(childPid, SIGTERM);
    wait(NULL);
    
    [self recheckIfJitIsAcquired];
  } else {
    self.acquisitionError = [NSString stringWithFormat:@"Failed to spawn child process for PTrace style JIT, errno %d", errno];
  }
}

@end
