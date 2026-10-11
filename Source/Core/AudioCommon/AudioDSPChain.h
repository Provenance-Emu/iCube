// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <functional>
#include <mutex>
#include <vector>

#include "Common/CommonTypes.h"

namespace AudioCommon
{
/// The filter chain both iOS backends run on their output: echo, 3-band EQ, bitcrusher, then a
/// master gain. Interleaved float frames, 1..kMaxChannels channels, processed in place.
///
/// Real-time rules: Configure() is the only method that allocates. SetParameters() may be called
/// from any thread; the render thread picks the new values up with a try_lock and keeps the old
/// ones if it loses the race, so Process() never blocks.
class AudioDSPChain final
{
public:
  static constexpr u32 kMaxChannels = 8;
  static constexpr int kMaxDelayMs = 2000;
  static constexpr int kMinDelayMs = 1;
  static constexpr int kMinCrushBits = 4;
  static constexpr int kMaxCrushBits = 16;
  static constexpr int kMaxCrushDownsample = 16;
  static constexpr float kMaxFeedback = 0.95f;
  static constexpr float kEqRangeDb = 24.0f;
  /// Dry/wet of the echo. Fixed, as the shipped CoreAudio chain had it.
  static constexpr float kDelayWet = 0.3f;

  struct Parameters
  {
    bool delay_enabled = false;
    int delay_ms = 200;
    float delay_feedback = 0.35f;
    bool crush_enabled = false;
    int crush_bits = 16;
    int crush_downsample = 1;
    bool eq_enabled = false;
    float eq_low_db = 0.0f;
    float eq_mid_db = 0.0f;
    float eq_high_db = 0.0f;
    /// Linear master gain, 1.0 = unity.
    float gain = 1.0f;

    bool operator==(const Parameters&) const = default;
  };

  AudioDSPChain();

  /// Sizes the delay lines and scratch buffers. Not real-time safe. Resets all filter state.
  void Configure(u32 sample_rate, u32 channels);
  u32 GetSampleRate() const { return m_sample_rate; }
  u32 GetChannels() const { return m_channels; }

  /// Any thread. Values are clamped to the ranges above.
  void SetParameters(const Parameters& params);
  /// Read-modify-write under the parameter lock, so two writers (volume and a Config reload) can
  /// never overwrite each other's field with a stale copy.
  void Update(const std::function<void(Parameters&)>& edit);
  Parameters GetParameters() const;

  /// True when Process() would change the samples (an effect is on or gain is not unity).
  bool IsActive() const { return m_active.load(std::memory_order_relaxed); }

  /// Render thread. `frames` interleaved frames of GetChannels() channels.
  void Process(float* interleaved, std::size_t frames);
  /// Render thread. Converts to float, processes, converts back; untouched when !IsActive().
  void ProcessS16(s16* interleaved, std::size_t frames);

#ifdef IPHONEOS
  /// Reads the MAIN_AUDIO_FX_* keys. `gain` is left at its current value.
  void LoadFromConfig();
#endif

private:
  struct BiquadCoefficients
  {
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
  };
  struct BiquadState
  {
    float s1 = 0, s2 = 0;
  };
  /// Everything the render thread needs, copied under the lock. Plain data, no allocation.
  struct Snapshot
  {
    Parameters params;
    std::array<BiquadCoefficients, 3> eq;
    std::size_t delay_frames = 0;
    bool active = false;
  };

  static Parameters Clamp(Parameters p);
  static void ComputeLowShelf(BiquadCoefficients& q, float sr, float freq, float gain_db);
  static void ComputeHighShelf(BiquadCoefficients& q, float sr, float freq, float gain_db);
  static void ComputePeak(BiquadCoefficients& q, float sr, float freq, float qfac, float gain_db);
  Snapshot BuildSnapshot(const Parameters& params) const;
  void PublishLocked(const Parameters& params);
  void PickUpSnapshot();
  void ResetDelay(std::size_t delay_frames);

  u32 m_sample_rate = 48000;
  u32 m_channels = 2;

  mutable std::mutex m_shared_mutex;
  Snapshot m_shared;
  std::atomic<u32> m_generation{0};
  std::atomic<bool> m_active{false};

  // Render-thread-owned state.
  Snapshot m_live;
  u32 m_seen_generation = 0;
  std::vector<float> m_delay;  // kMaxDelayMs worth of frames × channels
  std::size_t m_delay_index = 0;
  std::array<std::array<BiquadState, kMaxChannels>, 3> m_eq_state{};
  std::array<float, kMaxChannels> m_crush_hold{};
  int m_crush_counter = 0;
  std::vector<float> m_scratch;
};
}  // namespace AudioCommon
