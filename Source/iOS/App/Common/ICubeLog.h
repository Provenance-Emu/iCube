// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#import <Foundation/Foundation.h>
/// NSLog in DEBUG builds only. Release builds keep the console quiet (and free of paths and game names).
#ifdef DEBUG
#define DOLDebugLog(...) NSLog(__VA_ARGS__)
#else
#define DOLDebugLog(...) do {} while (0)
#endif
