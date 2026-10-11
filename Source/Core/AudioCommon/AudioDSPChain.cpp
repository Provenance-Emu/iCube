// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "AudioCommon/AudioDSPChain.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <numbers>

#ifdef IPHONEOS
#include "Common/Config/Config.h"
#include "Core/Config/iOSSettings.h"
#endif

namespace AudioCommon
{
namespace
{
constexpr float kLowShelfHz = 150.0f;
constexpr float kMidPeakHz = 1000.0f;
constexpr float kMidPeakQ = 0.707f;
constexpr float kHighShelfHz = 6000.0f;
constexpr std::size_t kScratchFrames = 8192;

float DbToLinear(float db)
{
  return std::pow(10.0f, db / 20.0f);
}

inline float Biquad(float x, const float b0, const float b1, const float b2, const float a1,
                    const float a2, float& s1, float& s2)
{
  // Direct Form II transposed.
  const float y = b0 * x + s1;
  s1 = b1 * x + s2 - a1 * y;
  s2 = b2 * x - a2 * y;
  return y;
}
}  // namespace

AudioDSPChain::AudioDSPChain()
{
  Configure(m_sample_rate, m_channels);
}

void AudioDSPChain::Configure(u32 sample_rate, u32 channels)
{
  m_sample_rate = std::max<u32>(1, sample_rate);
  m_channels = std::clamp<u32>(channels, 1, kMaxChannels);
  const std::size_t max_delay_frames =
      static_cast<std::size_t>(kMaxDelayMs) * m_sample_rate / 1000 + 1;
  m_delay.assign(max_delay_frames * m_channels, 0.0f);
  m_scratch.assign(kScratchFrames * m_channels, 0.0f);
  m_delay_index = 0;
  m_eq_state = {};
  m_crush_hold = {};
  m_crush_counter = 0;

  // Coefficients depend on the sample rate: rebuild from the current parameters. Configure is not
  // called from the render thread, so the render copy adopts the snapshot directly.
  std::lock_guard lock(m_shared_mutex);
  PublishLocked(m_shared.params);
  m_live = m_shared;
  m_seen_generation = m_generation.load();
}

AudioDSPChain::Parameters AudioDSPChain::Clamp(Parameters p)
{
  p.delay_ms = std::clamp(p.delay_ms, kMinDelayMs, kMaxDelayMs);
  p.delay_feedback = std::clamp(p.delay_feedback, 0.0f, kMaxFeedback);
  p.crush_bits = std::clamp(p.crush_bits, kMinCrushBits, kMaxCrushBits);
  p.crush_downsample = std::clamp(p.crush_downsample, 1, kMaxCrushDownsample);
  p.eq_low_db = std::clamp(p.eq_low_db, -kEqRangeDb, kEqRangeDb);
  p.eq_mid_db = std::clamp(p.eq_mid_db, -kEqRangeDb, kEqRangeDb);
  p.eq_high_db = std::clamp(p.eq_high_db, -kEqRangeDb, kEqRangeDb);
  p.gain = std::clamp(p.gain, 0.0f, 4.0f);
  return p;
}

void AudioDSPChain::ComputeLowShelf(BiquadCoefficients& q, float sr, float freq, float gain_db)
{
  const float A = DbToLinear(gain_db);
  const float w0 = 2.0f * std::numbers::pi_v<float> * (freq / sr);
  const float cosw = std::cos(w0), sinw = std::sin(w0);
  const float S = 1.0f;
  const float alpha = sinw / 2.0f * std::sqrt((A + 1 / A) * (1 / S - 1) + 2);
  const float sqA = std::sqrt(A);
  const float b0 = A * ((A + 1) - (A - 1) * cosw + 2 * sqA * alpha);
  const float b1 = 2 * A * ((A - 1) - (A + 1) * cosw);
  const float b2 = A * ((A + 1) - (A - 1) * cosw - 2 * sqA * alpha);
  const float a0 = (A + 1) + (A - 1) * cosw + 2 * sqA * alpha;
  const float a1 = -2 * ((A - 1) + (A + 1) * cosw);
  const float a2 = (A + 1) + (A - 1) * cosw - 2 * sqA * alpha;
  q = {b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0};
}

void AudioDSPChain::ComputeHighShelf(BiquadCoefficients& q, float sr, float freq, float gain_db)
{
  const float A = DbToLinear(gain_db);
  const float w0 = 2.0f * std::numbers::pi_v<float> * (freq / sr);
  const float cosw = std::cos(w0), sinw = std::sin(w0);
  const float S = 1.0f;
  const float alpha = sinw / 2.0f * std::sqrt((A + 1 / A) * (1 / S - 1) + 2);
  const float sqA = std::sqrt(A);
  const float b0 = A * ((A + 1) + (A - 1) * cosw + 2 * sqA * alpha);
  const float b1 = -2 * A * ((A - 1) + (A + 1) * cosw);
  const float b2 = A * ((A + 1) + (A - 1) * cosw - 2 * sqA * alpha);
  const float a0 = (A + 1) - (A - 1) * cosw + 2 * sqA * alpha;
  const float a1 = 2 * ((A - 1) - (A + 1) * cosw);
  const float a2 = (A + 1) - (A - 1) * cosw - 2 * sqA * alpha;
  q = {b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0};
}

void AudioDSPChain::ComputePeak(BiquadCoefficients& q, float sr, float freq, float qfac,
                                float gain_db)
{
  const float A = DbToLinear(gain_db);
  const float w0 = 2.0f * std::numbers::pi_v<float> * (freq / sr);
  const float cosw = std::cos(w0), sinw = std::sin(w0);
  const float alpha = sinw / (2.0f * qfac);
  const float b0 = 1 + alpha * A;
  const float b1 = -2 * cosw;
  const float b2 = 1 - alpha * A;
  const float a0 = 1 + alpha / A;
  const float a1 = -2 * cosw;
  const float a2 = 1 - alpha / A;
  q = {b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0};
}

AudioDSPChain::Snapshot AudioDSPChain::BuildSnapshot(const Parameters& params) const
{
  Snapshot s;
  s.params = params;
  const float sr = static_cast<float>(m_sample_rate);
  ComputeLowShelf(s.eq[0], sr, kLowShelfHz, params.eq_low_db);
  ComputePeak(s.eq[1], sr, kMidPeakHz, kMidPeakQ, params.eq_mid_db);
  ComputeHighShelf(s.eq[2], sr, kHighShelfHz, params.eq_high_db);
  s.delay_frames = std::max<std::size_t>(
      1, static_cast<std::size_t>(params.delay_ms) * m_sample_rate / 1000);
  s.active = params.delay_enabled || params.crush_enabled || params.eq_enabled ||
             params.gain != 1.0f;
  return s;
}

void AudioDSPChain::PublishLocked(const Parameters& params)
{
  m_shared = BuildSnapshot(params);
  m_active.store(m_shared.active, std::memory_order_relaxed);
  m_generation.fetch_add(1, std::memory_order_release);
}

void AudioDSPChain::SetParameters(const Parameters& params)
{
  const Parameters clamped = Clamp(params);
  std::lock_guard lock(m_shared_mutex);
  if (clamped == m_shared.params)
    return;
  PublishLocked(clamped);
}

AudioDSPChain::Parameters AudioDSPChain::GetParameters() const
{
  std::lock_guard lock(m_shared_mutex);
  return m_shared.params;
}

#ifdef IPHONEOS
void AudioDSPChain::LoadFromConfig()
{
  Parameters p = GetParameters();
  p.delay_enabled = Config::Get(Config::MAIN_AUDIO_FX_DELAY_ENABLED);
  p.delay_ms = Config::Get(Config::MAIN_AUDIO_FX_DELAY_MS);
  p.delay_feedback = Config::Get(Config::MAIN_AUDIO_FX_DELAY_FEEDBACK);
  p.crush_enabled = Config::Get(Config::MAIN_AUDIO_FX_CRUSH_ENABLED);
  p.crush_bits = Config::Get(Config::MAIN_AUDIO_FX_CRUSH_BITS);
  p.crush_downsample = Config::Get(Config::MAIN_AUDIO_FX_CRUSH_DOWNSAMPLE);
  p.eq_enabled = Config::Get(Config::MAIN_AUDIO_FX_EQ_ENABLED);
  p.eq_low_db = Config::Get(Config::MAIN_AUDIO_FX_EQ_LOW_DB);
  p.eq_mid_db = Config::Get(Config::MAIN_AUDIO_FX_EQ_MID_DB);
  p.eq_high_db = Config::Get(Config::MAIN_AUDIO_FX_EQ_HIGH_DB);
  SetParameters(p);
}
#endif

void AudioDSPChain::ResetDelay(std::size_t delay_frames)
{
  // Only the region the new length addresses needs clearing.
  std::memset(m_delay.data(), 0, delay_frames * m_channels * sizeof(float));
  m_delay_index = 0;
}

void AudioDSPChain::PickUpSnapshot()
{
  const u32 generation = m_generation.load(std::memory_order_acquire);
  if (generation == m_seen_generation)
    return;
  // Never block the render thread: if the writer holds the lock, try again next buffer.
  if (!m_shared_mutex.try_lock())
    return;
  const Snapshot next = m_shared;
  m_shared_mutex.unlock();
  m_seen_generation = generation;

  const bool delay_changed = next.delay_frames != m_live.delay_frames ||
                             next.params.delay_enabled != m_live.params.delay_enabled;
  const bool eq_changed = next.params.eq_enabled != m_live.params.eq_enabled ||
                          next.params.eq_low_db != m_live.params.eq_low_db ||
                          next.params.eq_mid_db != m_live.params.eq_mid_db ||
                          next.params.eq_high_db != m_live.params.eq_high_db;
  m_live = next;
  if (delay_changed)
    ResetDelay(m_live.delay_frames);
  if (eq_changed)
    m_eq_state = {};
}

void AudioDSPChain::Process(float* interleaved, std::size_t frames)
{
  PickUpSnapshot();
  const Snapshot& s = m_live;
  if (!s.active)
    return;

  const u32 channels = m_channels;
  const Parameters& p = s.params;
  const float crush_step = 1.0f / static_cast<float>((1 << p.crush_bits) - 1);
  const std::size_t delay_frames = std::min(s.delay_frames, m_delay.size() / channels);

  for (std::size_t f = 0; f < frames; ++f)
  {
    float* frame = interleaved + f * channels;

    if (p.crush_enabled)
    {
      if (m_crush_counter == 0)
      {
        for (u32 c = 0; c < channels; ++c)
          m_crush_hold[c] = std::round(frame[c] / crush_step) * crush_step;
        m_crush_counter = p.crush_downsample;
      }
      for (u32 c = 0; c < channels; ++c)
        frame[c] = m_crush_hold[c];
      --m_crush_counter;
    }

    if (p.eq_enabled)
    {
      for (u32 c = 0; c < channels; ++c)
      {
        float x = frame[c];
        for (std::size_t band = 0; band < 3; ++band)
        {
          const BiquadCoefficients& q = s.eq[band];
          BiquadState& st = m_eq_state[band][c];
          x = Biquad(x, q.b0, q.b1, q.b2, q.a1, q.a2, st.s1, st.s2);
        }
        frame[c] = x;
      }
    }

    if (p.delay_enabled && delay_frames > 0)
    {
      float* line = m_delay.data() + m_delay_index * channels;
      for (u32 c = 0; c < channels; ++c)
      {
        const float delayed = line[c];
        line[c] = frame[c] + delayed * p.delay_feedback;
        frame[c] = frame[c] * (1.0f - kDelayWet) + delayed * kDelayWet;
      }
      m_delay_index = (m_delay_index + 1) % delay_frames;
    }

    if (p.gain != 1.0f)
    {
      for (u32 c = 0; c < channels; ++c)
        frame[c] *= p.gain;
    }
  }
}

void AudioDSPChain::ProcessS16(s16* interleaved, std::size_t frames)
{
  PickUpSnapshot();
  if (!m_live.active)
    return;

  const u32 channels = m_channels;
  constexpr float kScale = 32768.0f;
  while (frames > 0)
  {
    const std::size_t chunk = std::min(frames, kScratchFrames);
    const std::size_t samples = chunk * channels;
    for (std::size_t i = 0; i < samples; ++i)
      m_scratch[i] = interleaved[i] / kScale;
    Process(m_scratch.data(), chunk);
    for (std::size_t i = 0; i < samples; ++i)
    {
      const float v = std::clamp(m_scratch[i] * kScale, -32768.0f, 32767.0f);
      interleaved[i] = static_cast<s16>(v);
    }
    interleaved += samples;
    frames -= chunk;
  }
}
}  // namespace AudioCommon
