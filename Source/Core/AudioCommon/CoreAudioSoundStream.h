// Copyright 2008 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#ifdef IPHONEOS
#include <AudioUnit/AudioUnit.h>
#endif

#include "AudioCommon/SoundStream.h"

class CoreAudioSound final : public SoundStream
{
#ifdef IPHONEOS
public:
  bool Init() override;
  bool SetRunning(bool running) override;
  void SetVolume(int volume) override;

  static bool IsValid() { return true; }

  /// Built-in DSP controls (no AUv3; CoreAudio backend only)
  void setDelayEnabled(bool enabled);
  void setDelayMs(int ms);
  void setDelayFeedback(float fb); // 0.0 - 0.95

  void setBitcrushEnabled(bool enabled);
  void setBitcrushBits(int bits); // 4 - 16
  void setBitcrushDownsample(int factor); // 1 - 16

  void setEQEnabled(bool enabled);
  void setEQLowGainDb(float db);   // bass shelf gain in dB
  void setEQMidGainDb(float db);   // mid peak gain in dB
  void setEQHighGainDb(float db);  // treble shelf gain in dB

  // Getters for UI sync
  bool getDelayEnabled() const { return m_delay_enabled; }
  int getDelayMs() const { return m_delay_ms; }
  float getDelayFeedback() const { return m_delay_feedback; }
  bool getBitcrushEnabled() const { return m_bitcrush_enabled; }
  int getBitcrushBits() const { return m_bitcrush_bits; }
  int getBitcrushDownsample() const { return m_bitcrush_downsample; }
  bool getEQEnabled() const { return m_eq_enabled; }
  float getEQLowGainDb() const { return m_eq_low_db; }
  float getEQMidGainDb() const { return m_eq_mid_db; }
  float getEQHighGainDb() const { return m_eq_high_db; }

private:
  AudioUnit audio_unit;
  int m_volume;

  static OSStatus callback(void* ref_con, AudioUnitRenderActionFlags* action_flags,
                           const AudioTimeStamp* timestamp, UInt32 bus_number, UInt32 number_frames,
                           AudioBufferList* io_data);

  // DSP state
  bool m_delay_enabled = false;
  int m_delay_ms = 200;
  float m_delay_feedback = 0.35f;
  std::vector<float> m_delayL;
  std::vector<float> m_delayR;
  size_t m_delay_index = 0;

  bool m_bitcrush_enabled = false;
  int m_bitcrush_bits = 16;
  int m_bitcrush_downsample = 1;
  int m_bitcrush_hold = 0;
  float m_last_crush_L = 0.0f;
  float m_last_crush_R = 0.0f;

  bool m_eq_enabled = false;
  float m_eq_low_db = 0.0f;
  float m_eq_mid_db = 0.0f;
  float m_eq_high_db = 0.0f;

  struct Biquad { float b0=1, b1=0, b2=0, a1=0, a2=0, s1L=0, s2L=0, s1R=0, s2R=0; };
  Biquad m_low_shelf;
  Biquad m_mid_peak;
  Biquad m_high_shelf;

  void updateDelayBuffers(unsigned sample_rate);
  void updateEQ(unsigned sample_rate);
  static void computeLowShelf(Biquad& q, float sr, float freq, float gain_db);
  static void computeHighShelf(Biquad& q, float sr, float freq, float gain_db);
  static void computePeak(Biquad& q, float sr, float freq, float qfac, float gain_db);
  inline void processEQFrame(float& l, float& r);
#endif
};
