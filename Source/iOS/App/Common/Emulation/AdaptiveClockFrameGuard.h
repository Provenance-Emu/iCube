// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

// The adaptive clock's frame-rate guard, kept free of Dolphin and UIKit so the decision is unit
// tested (iCubeTests/AdaptiveClockFrameGuardTests.mm).
//
// The clock controller descends while the emulated speed reads below 100 %. That speed sensor
// cannot tell a game whose frame rate is what the clock buys: on a CPU-bound 60 fps title (F-Zero
// GX, Melee with 4 players) every underclock step raises the speed toward 100 % while the game
// finishes FEWER frames per real second, so the descent ends near the floor in slow motion. The
// guard compares what each operating point actually delivers, new game frames per wall second,
// against the highest point measured this run (CPU and VI both at their ceiling). A point that
// delivers clearly less is suspect; the controller re-measures at the reference and, if the
// reference really delivers more, goes back to it.
//
// The rate counts unique presents (total minus duplicates). With Skip Duplicate XFBs on (the
// default) duplicates are never presented and so never counted; the total is then the unique
// count. The guard this replaces compared duplicate ratios and was blind in that configuration.

namespace AdaptiveClockFrameGuard
{
// Applied clocks of one window. A lever under manual control is passed equal to the reference.
struct OperatingPoint
{
  float cpu = 1.0f;
  float vi = 1.0f;
};

struct FrameWindow
{
  unsigned long long uniqueFrames = 0;
  double seconds = 0.0;
};

struct Reference
{
  bool valid = false;
  OperatingPoint point;
  double rate = 0.0;  // unique frames per wall second at `point`
};

enum class Verdict
{
  Ignore,          // too short to judge
  Reference,       // at/above the reference point with enough frames: becomes the new reference
  Keep,            // below the reference and delivers about as many frames: fine
  Suspect,         // below the reference and delivers clearly fewer frames
  NeedsReference,  // below the top with no reference yet (seeded boot): measure the top first
};

constexpr float kClockEpsilon = 0.001f;
// A window shorter than this is not a measurement (clock changed a moment ago).
constexpr double kMinWindowSeconds = 1.0;
// A reference needs this many new frames; fewer is loading or a black screen.
constexpr unsigned long long kMinReferenceFrames = 30;
// A lower point is judged from this many new frames. Below it the window is loading, not play
// (a starving 60 fps game still finishes ~15 frames per second).
constexpr unsigned long long kMinJudgedFrames = 10;
// A lower point losing more than this share of the reference rate is suspect.
constexpr double kSuspectLoss = 0.05;
// Back at the reference, the rate must beat the suspect window by this share to confirm that the
// underclock (not a scene change) cost the frames.
constexpr double kConfirmGain = 0.03;

inline double Rate(const FrameWindow& w)
{
  return w.seconds > 0.0 ? (double)w.uniqueFrames / w.seconds : 0.0;
}

inline bool IsBelow(const OperatingPoint& p, const OperatingPoint& ref)
{
  return p.cpu < ref.cpu - kClockEpsilon || p.vi < ref.vi - kClockEpsilon;
}

// `top` is the highest point the controller may apply now (CPU at the thermal ceiling, VI 1.0).
inline Verdict Judge(const OperatingPoint& point, const FrameWindow& w, const Reference& ref,
                     const OperatingPoint& top)
{
  if (w.seconds < kMinWindowSeconds)
    return Verdict::Ignore;
  const OperatingPoint& bar = ref.valid ? ref.point : top;
  if (!IsBelow(point, bar))
    return w.uniqueFrames >= kMinReferenceFrames ? Verdict::Reference : Verdict::Ignore;
  if (w.uniqueFrames < kMinJudgedFrames)
    return Verdict::Ignore;
  if (!ref.valid)
    return Verdict::NeedsReference;
  return Rate(w) < ref.rate * (1.0 - kSuspectLoss) ? Verdict::Suspect : Verdict::Keep;
}

// The re-measurement at the reference after a Suspect (or NeedsReference) window. True: the
// reference delivers more, so the lower point was starving the game.
inline bool ConfirmsStarvation(double suspectRate, const FrameWindow& atReference)
{
  return Rate(atReference) >= suspectRate * (1.0 + kConfirmGain);
}

// A confirmation window needs as many frames as a reference; fewer means measure again.
inline bool CanConfirm(const FrameWindow& atReference)
{
  return atReference.seconds >= kMinWindowSeconds &&
         atReference.uniqueFrames >= kMinReferenceFrames;
}
}  // namespace AdaptiveClockFrameGuard
