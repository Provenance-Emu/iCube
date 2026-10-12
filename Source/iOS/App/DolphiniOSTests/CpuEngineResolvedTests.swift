// DolphiniOSTests/CpuEngineResolvedTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class CpuEngineResolvedTests: XCTestCase {
  func test_jitEngines_fallBackWithoutJit() {
    XCTAssertEqual(CpuEngine.resolved(stored: .jit64, acquiredJit: false), .cachedInterpreter)
    XCTAssertEqual(CpuEngine.resolved(stored: .jitARM64, acquiredJit: false), .cachedInterpreter)
  }

  func test_passesThroughOtherwise() {
    for engine in CpuEngine.allCases {
      XCTAssertEqual(CpuEngine.resolved(stored: engine, acquiredJit: true), engine)
    }
    XCTAssertEqual(CpuEngine.resolved(stored: .interpreter, acquiredJit: false), .interpreter)
    XCTAssertEqual(CpuEngine.resolved(stored: .cachedInterpreter, acquiredJit: false), .cachedInterpreter)
    XCTAssertEqual(CpuEngine.resolved(stored: .cachedInterpreterIR, acquiredJit: false), .cachedInterpreterIR)
  }

  func test_shortNames() {
    XCTAssertEqual(CpuEngine.interpreter.shortName, "INT")
    XCTAssertEqual(CpuEngine.cachedInterpreter.shortName, "CIR")
    XCTAssertEqual(CpuEngine.cachedInterpreterIR.shortName, "CIR-IR")
    XCTAssertEqual(CpuEngine.jit64.shortName, "JIT")
    XCTAssertEqual(CpuEngine.jitARM64.shortName, "JIT")
  }
}
