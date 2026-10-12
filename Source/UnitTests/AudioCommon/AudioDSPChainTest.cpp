// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <algorithm>
#include <cmath>
#include <numbers>
#include <vector>

#include <gtest/gtest.h>

#include "AudioCommon/AudioDSPChain.h"

using AudioCommon::AudioDSPChain;

namespace
{
constexpr u32 kRate = 48000;

std::vector<float> Sine(std::size_t frames, u32 channels, float hz, float amplitude = 0.5f)
{
  std::vector<float> out(frames * channels);
  for (std::size_t f = 0; f < frames; ++f)
  {
    const float v = amplitude * std::sin(2.0f * std::numbers::pi_v<float> * hz * f / kRate);
    for (u32 c = 0; c < channels; ++c)
      out[f * channels + c] = v;
  }
  return out;
}

float Rms(const std::vector<float>& buf, std::size_t from = 0)
{
  double sum = 0;
  for (std::size_t i = from; i < buf.size(); ++i)
    sum += double(buf[i]) * buf[i];
  return static_cast<float>(std::sqrt(sum / std::max<std::size_t>(1, buf.size() - from)));
}
}  // namespace

TEST(AudioDSPChain, DefaultsAreInactiveAndBitIdentical)
{
  AudioDSPChain chain;
  chain.Configure(kRate, 2);
  EXPECT_FALSE(chain.IsActive());

  std::vector<s16> pcm(2 * 1024);
  for (std::size_t i = 0; i < pcm.size(); ++i)
    pcm[i] = static_cast<s16>((i * 977) % 65536 - 32768);
  const std::vector<s16> original = pcm;
  chain.ProcessS16(pcm.data(), 1024);
  EXPECT_EQ(pcm, original);

  std::vector<float> f = Sine(256, 2, 440.0f);
  const std::vector<float> f_original = f;
  chain.Process(f.data(), 256);
  EXPECT_EQ(f, f_original);
}

TEST(AudioDSPChain, GainScalesEveryChannel)
{
  AudioDSPChain chain;
  chain.Configure(kRate, 6);
  AudioDSPChain::Parameters p;
  p.gain = 0.5f;
  chain.SetParameters(p);
  EXPECT_TRUE(chain.IsActive());

  std::vector<float> buf(6 * 64, 0.8f);
  chain.Process(buf.data(), 64);
  for (float v : buf)
    EXPECT_FLOAT_EQ(v, 0.4f);

  std::vector<s16> pcm(6 * 64, 20000);
  chain.ProcessS16(pcm.data(), 64);
  for (s16 v : pcm)
    EXPECT_EQ(v, 10000);
}

TEST(AudioDSPChain, ParametersAreClamped)
{
  AudioDSPChain chain;
  AudioDSPChain::Parameters p;
  p.delay_ms = 99999;
  p.delay_feedback = 3.0f;
  p.crush_bits = 1;
  p.crush_downsample = 0;
  p.eq_low_db = -100.0f;
  p.eq_high_db = 100.0f;
  chain.SetParameters(p);
  const auto got = chain.GetParameters();
  EXPECT_EQ(got.delay_ms, AudioDSPChain::kMaxDelayMs);
  EXPECT_FLOAT_EQ(got.delay_feedback, AudioDSPChain::kMaxFeedback);
  EXPECT_EQ(got.crush_bits, AudioDSPChain::kMinCrushBits);
  EXPECT_EQ(got.crush_downsample, 1);
  EXPECT_FLOAT_EQ(got.eq_low_db, -AudioDSPChain::kEqRangeDb);
  EXPECT_FLOAT_EQ(got.eq_high_db, AudioDSPChain::kEqRangeDb);
}

TEST(AudioDSPChain, BitcrusherQuantisesAndHolds)
{
  AudioDSPChain chain;
  chain.Configure(kRate, 1);
  AudioDSPChain::Parameters p;
  p.crush_enabled = true;
  p.crush_bits = 4;
  p.crush_downsample = 4;
  chain.SetParameters(p);

  std::vector<float> buf(16);
  for (std::size_t i = 0; i < buf.size(); ++i)
    buf[i] = 0.01f * i;
  chain.Process(buf.data(), buf.size());

  // Four-sample hold: each group of four is one value.
  for (std::size_t i = 0; i < buf.size(); i += 4)
  {
    EXPECT_FLOAT_EQ(buf[i + 1], buf[i]);
    EXPECT_FLOAT_EQ(buf[i + 2], buf[i]);
    EXPECT_FLOAT_EQ(buf[i + 3], buf[i]);
  }
  // 4-bit steps: every value is a multiple of 1/15.
  const float step = 1.0f / 15.0f;
  for (float v : buf)
    EXPECT_NEAR(std::round(v / step) * step, v, 1e-6f);
}

TEST(AudioDSPChain, EchoRepeatsAtTheConfiguredDelay)
{
  AudioDSPChain chain;
  chain.Configure(kRate, 1);
  AudioDSPChain::Parameters p;
  p.delay_enabled = true;
  p.delay_ms = 10;  // 480 frames
  p.delay_feedback = 0.0f;
  chain.SetParameters(p);

  std::vector<float> buf(2000, 0.0f);
  buf[0] = 1.0f;
  chain.Process(buf.data(), buf.size());

  EXPECT_FLOAT_EQ(buf[0], 1.0f - AudioDSPChain::kDelayWet);
  EXPECT_FLOAT_EQ(buf[480], AudioDSPChain::kDelayWet);
  for (std::size_t i = 1; i < buf.size(); ++i)
  {
    if (i != 480)
      EXPECT_FLOAT_EQ(buf[i], 0.0f) << i;
  }
}

TEST(AudioDSPChain, EqBoostsBassAndCutsTreble)
{
  AudioDSPChain chain;
  chain.Configure(kRate, 2);
  AudioDSPChain::Parameters p;
  p.eq_enabled = true;
  p.eq_low_db = 12.0f;
  p.eq_high_db = -12.0f;
  chain.SetParameters(p);

  std::vector<float> low = Sine(kRate / 4, 2, 50.0f);
  std::vector<float> high = Sine(kRate / 4, 2, 12000.0f);
  const float low_before = Rms(low, low.size() / 2);
  const float high_before = Rms(high, high.size() / 2);
  chain.Process(low.data(), low.size() / 2);
  chain.Configure(kRate, 2);
  chain.SetParameters(p);
  chain.Process(high.data(), high.size() / 2);
  EXPECT_GT(Rms(low, low.size() / 2), low_before * 2.5f);
  EXPECT_LT(Rms(high, high.size() / 2), high_before * 0.4f);
}

TEST(AudioDSPChain, ParameterChangesLandOnTheRenderThreadWithoutReconfigure)
{
  AudioDSPChain chain;
  chain.Configure(kRate, 2);
  std::vector<float> buf(2 * 32, 0.5f);
  chain.Process(buf.data(), 32);
  EXPECT_FLOAT_EQ(buf[0], 0.5f);

  AudioDSPChain::Parameters p;
  p.gain = 2.0f;
  chain.SetParameters(p);
  std::fill(buf.begin(), buf.end(), 0.25f);
  chain.Process(buf.data(), 32);
  EXPECT_FLOAT_EQ(buf[0], 0.5f);

  p.gain = 1.0f;
  chain.SetParameters(p);
  EXPECT_FALSE(chain.IsActive());
}
