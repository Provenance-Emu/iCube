// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface JitManager : NSObject

@property (readonly, assign) bool acquiredJit;
@property (nonatomic, nullable) NSString* acquisitionError;

@property (readonly, assign) bool deviceHasTxm;

/// True when this build/distribution can ever acquire JIT. False on App Store /
/// TestFlight (jitless) builds, where no external debugger path is available and
/// the core always runs the Cached Interpreter. Callers use this to avoid showing
/// the "Waiting for JIT" prompt when JIT can never be enabled.
@property (readonly, assign) bool jitSupported;

/// True when a debugger is attached to this process RIGHT NOW (P_TRACED), as opposed to
/// acquiredJit, which reads CS_DEBUGGED and stays set after the debugger detaches. On an
/// iOS 26 TXM device this is the signal that a StikDebug broker may be listening for the
/// brk #0x69 handshake. Refreshed by recheckIfJitIsAcquired.
@property (readonly, assign) bool debuggerAttached;

/// True once the TXM handshake succeeded in this process: the dual-mapped JIT region is
/// authorized and every later boot can use it without a broker attached.
@property (readonly, assign) bool txmAuthorized;

+ (JitManager*)shared;

- (void)recheckIfJitIsAcquired;

/// iOS 26 TXM auto-detection. True when the boot path should issue the brk #0x69
/// handshake: TXM device, JIT acquired, and a debugger attached right now (StikDebug's
/// script, or Xcode / any lldb running the dolphin_jit_lldb.py bless hook).
/// `DOL_JIT_TXM=1` in the environment forces true, `DOL_JIT_TXM=0` forces false.
- (bool)shouldAttemptTXMHandshake;

/// Call immediately before issuing the TXM handshake. Persists a crash cookie so that if
/// the brk kills us (a debugger is attached that is not a broker, and EXC_BREAKPOINT cannot
/// be caught), the next launch declines to try again instead of crashing forever.
- (void)beginTXMHandshake;

/// Records the outcome of the TXM handshake (see txmAuthorized) and clears the cookie.
- (void)noteTXMHandshakeResult:(bool)authorized;

/// Clears the crash cookie after an explicit user request to enable JIT, so a one-off bad
/// attempt does not disable the feature permanently.
- (void)clearTXMHandshakeCookie;

/// True when the cookie is set, i.e. a previous handshake never returned and JIT is being
/// declined for safety. Surfaced in Settings so a stuck device has a way back that does not
/// depend on StikDebug being installed.
@property (readonly, assign) bool txmHandshakeBlocked;

@end

NS_ASSUME_NONNULL_END
