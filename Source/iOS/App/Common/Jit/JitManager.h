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

+ (JitManager*)shared;

- (void)recheckIfJitIsAcquired;

@end

NS_ASSUME_NONNULL_END
