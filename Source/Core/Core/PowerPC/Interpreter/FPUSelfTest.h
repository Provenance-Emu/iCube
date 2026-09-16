// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <string>

namespace PowerPC
{
// iCube oracle: runs the interpreter's FP primitives (NI_mul/add/madd, ForceSingle, Force25Bit,
// frsqrte/fres tables, conversions, psq dequantize) on fixed inputs under three host FPCR modes
// (IEEE, FZ, Dolphin's non-IEEE FZ|AH) and returns one "name mode = hexbits" line per result, so
// two builds (phone vs Mac) can be diffed value by value. Pure; restores FPSCR and FPCR after.
std::string RunFPUSelfTest();
}  // namespace PowerPC
