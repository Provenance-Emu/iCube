// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
#import <XCTest/XCTest.h>
#include "../Common/Emulation/AdaptiveClockFrameGuard.h"

using namespace AdaptiveClockFrameGuard;

namespace
{
const OperatingPoint kNative{1.0f, 1.0f};

// `fps` new game frames per wall second over a `seconds`-long window.
FrameWindow Window(double fps, double seconds = 4.0)
{
  return FrameWindow{(unsigned long long)(fps * seconds + 0.5), seconds};
}

Reference ReferenceAt(OperatingPoint point, double fps)
{
  return Reference{true, point, fps};
}
}  // namespace

@interface AdaptiveClockFrameGuardTests : XCTestCase
@end

@implementation AdaptiveClockFrameGuardTests

// F-Zero GX on the interpreter: clock 1.0 runs at ~55 % speed but every field is a new frame
// (~33 per wall second); clock 0.40 reaches 100 % speed with the game finishing ~20 frames per
// second. Speed alone reads 0.40 as better; the guard must not.
- (void)testFZeroUnderclockThatDeliversFewerFramesIsSuspect
{
  const Reference ref = ReferenceAt(kNative, 33.0);
  XCTAssertEqual(Judge({0.40f, 1.0f}, Window(20.0), ref, kNative), Verdict::Suspect);
  XCTAssertTrue(ConfirmsStarvation(20.0, Window(33.0)));
}

// With Skip Duplicate XFBs on, duplicates are never presented, so the window counts only unique
// frames and the duplicate count stays 0. The rate alone must still expose the loss.
- (void)testSuspectWithoutAnyDuplicateCount
{
  const Reference ref = ReferenceAt(kNative, 36.0);
  const FrameWindow uniqueOnly{30, 1.5};  // 20 fps, dups never counted
  XCTAssertEqual(Judge({0.30f, 1.0f}, uniqueOnly, ref, kNative), Verdict::Suspect);
}

// A 30 fps-by-design title that falls short at 1.0 (24 frames per second at 80 % speed) and
// reaches full speed at 0.80 delivers more frames there: keep the underclock.
- (void)testThirtyFpsTitleThatGainsFramesIsKept
{
  const Reference ref = ReferenceAt(kNative, 24.0);
  XCTAssertEqual(Judge({0.80f, 1.0f}, Window(30.0), ref, kNative), Verdict::Keep);
}

// An idle-loop title delivers the same frames at a lower clock: within noise, keep it.
- (void)testSameFramesWithinNoiseIsKept
{
  const Reference ref = ReferenceAt(kNative, 60.0);
  XCTAssertEqual(Judge({0.60f, 1.0f}, Window(58.5), ref, kNative), Verdict::Keep);
  XCTAssertEqual(Judge({0.60f, 1.0f}, Window(56.0), ref, kNative), Verdict::Suspect);
}

// Shedding VI (lower field rate) must be judged like the CPU lever, not waved through.
- (void)testViUnderclockIsJudged
{
  const Reference ref = ReferenceAt(kNative, 33.0);
  XCTAssertEqual(Judge({0.30f, 0.70f}, Window(21.0), ref, kNative), Verdict::Suspect);
  XCTAssertEqual(Judge({1.0f, 0.90f}, Window(25.0), ref, kNative), Verdict::Suspect);
}

// Loading or a black screen: too few frames to become the reference, and too few to judge.
- (void)testLoadingWindowsNeverBecomeTheReference
{
  XCTAssertEqual(Judge(kNative, Window(2.0), Reference{}, kNative), Verdict::Ignore);
  XCTAssertEqual(Judge(kNative, Window(30.0), Reference{}, kNative), Verdict::Reference);
  const Reference ref = ReferenceAt(kNative, 33.0);
  XCTAssertEqual(Judge({0.40f, 1.0f}, Window(1.0), ref, kNative), Verdict::Ignore);
  XCTAssertFalse(CanConfirm(Window(3.0)));
  XCTAssertTrue(CanConfirm(Window(33.0)));
}

// A window shorter than a second is not a measurement.
- (void)testShortWindowIsIgnored
{
  const Reference ref = ReferenceAt(kNative, 33.0);
  XCTAssertEqual(Judge({0.40f, 1.0f}, FrameWindow{5, 0.5}, ref, kNative), Verdict::Ignore);
}

// A seeded boot starts below native with no reference: no lower point is trusted until the top
// has been measured this run.
- (void)testSeededBootBelowNativeNeedsTheTopMeasuredFirst
{
  XCTAssertEqual(Judge({0.30f, 1.0f}, Window(20.0), Reference{}, kNative), Verdict::NeedsReference);
  XCTAssertEqual(Judge({0.30f, 0.80f}, Window(20.0), Reference{}, kNative), Verdict::NeedsReference);
}

// The thermal ceiling lowers the top: a point at the ceiling is the top, not an underclock.
- (void)testThermalCeilingIsTheTop
{
  const OperatingPoint hot{0.80f, 1.0f};
  XCTAssertEqual(Judge(hot, Window(30.0), Reference{}, hot), Verdict::Reference);
  XCTAssertEqual(Judge({0.70f, 1.0f}, Window(20.0), ReferenceAt(hot, 30.0), hot), Verdict::Suspect);
}

// A higher point than the reference (cooled down, or a higher scene clock) re-bases it.
- (void)testPointAboveTheReferenceBecomesTheReference
{
  const Reference ref = ReferenceAt({0.80f, 1.0f}, 30.0);
  XCTAssertEqual(Judge(kNative, Window(31.0), ref, kNative), Verdict::Reference);
}

// A trip from a stale reference (a 60 fps menu before 33 fps racing) is not confirmed when the
// reference delivers no more in the current scene.
- (void)testSceneChangeDoesNotConfirm
{
  const Reference menu = ReferenceAt(kNative, 60.0);
  XCTAssertEqual(Judge({0.90f, 1.0f}, Window(34.0), menu, kNative), Verdict::Suspect);
  XCTAssertFalse(ConfirmsStarvation(34.0, Window(33.5)));
  XCTAssertFalse(ConfirmsStarvation(34.0, Window(34.5)));
}

@end
