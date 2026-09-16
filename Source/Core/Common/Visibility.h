// Copyright 2026 iCube
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

// Keep a symbol out of the dylib's export table. Under full LTO, template instantiations
// (linkonce_odr) that stay exported are treated as interposable, so every call to them — even
// from the same image — goes through a dyld stub. The hot cached-interpreter handlers were paying
// ~5 % of the CPU thread in stubs (NSMBW, 2026-09-16 Time Profiler). Only apply this to classes
// nothing outside the core dylib references.
#if defined(__GNUC__) || defined(__clang__)
#define DOLPHIN_HIDDEN __attribute__((visibility("hidden")))
#else
#define DOLPHIN_HIDDEN
#endif
