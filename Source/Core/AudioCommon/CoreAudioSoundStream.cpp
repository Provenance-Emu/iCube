// Copyright 2008 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <AudioUnit/AudioUnit.h>

#include "AudioCommon/CoreAudioSoundStream.h"
#include "Common/Logging/Log.h"

static inline float db_to_linear(float db) { return powf(10.0f, db / 20.0f); }

void CoreAudioSound::updateDelayBuffers(unsigned sample_rate)
{
  const size_t max_samples = (size_t)std::max(1, std::min(4000, m_delay_ms)) * (size_t)sample_rate / 1000;
  m_delayL.resize(max_samples, 0.0f);
  m_delayR.resize(max_samples, 0.0f);
  m_delay_index = 0;
}

void CoreAudioSound::computeLowShelf(Biquad& q, float sr, float freq, float gain_db)
{
  const float A = db_to_linear(gain_db);
  const float w0 = 2.0f * (float)M_PI * (freq / sr);
  const float cosw = cosf(w0), sinw = sinf(w0);
  const float S = 1.0f;
  const float alpha = sinw / 2.0f * sqrtf((A + 1/A) * (1/S - 1) + 2);
  const float b0 = A*((A+1) - (A-1)*cosw + 2*sqrtf(A)*alpha);
  const float b1 = 2*A*((A-1) - (A+1)*cosw);
  const float b2 = A*((A+1) - (A-1)*cosw - 2*sqrtf(A)*alpha);
  const float a0 = (A+1) + (A-1)*cosw + 2*sqrtf(A)*alpha;
  const float a1 = -2*((A-1) + (A+1)*cosw);
  const float a2 = (A+1) + (A-1)*cosw - 2*sqrtf(A)*alpha;
  q.b0=b0/a0; q.b1=b1/a0; q.b2=b2/a0; q.a1=a1/a0; q.a2=a2/a0; q.s1L=q.s2L=q.s1R=q.s2R=0;
}

void CoreAudioSound::computeHighShelf(Biquad& q, float sr, float freq, float gain_db)
{
  const float A = db_to_linear(gain_db);
  const float w0 = 2.0f * (float)M_PI * (freq / sr);
  const float cosw = cosf(w0), sinw = sinf(w0);
  const float S = 1.0f;
  const float alpha = sinw / 2.0f * sqrtf((A + 1/A) * (1/S - 1) + 2);
  const float b0 = A*((A+1) + (A-1)*cosw + 2*sqrtf(A)*alpha);
  const float b1 = -2*A*((A-1) + (A+1)*cosw);
  const float b2 = A*((A+1) + (A-1)*cosw - 2*sqrtf(A)*alpha);
  const float a0 = (A+1) - (A-1)*cosw + 2*sqrtf(A)*alpha;
  const float a1 = 2*((A-1) - (A+1)*cosw);
  const float a2 = (A+1) - (A-1)*cosw - 2*sqrtf(A)*alpha;
  q.b0=b0/a0; q.b1=b1/a0; q.b2=b2/a0; q.a1=a1/a0; q.a2=a2/a0; q.s1L=q.s2L=q.s1R=q.s2R=0;
}

void CoreAudioSound::computePeak(Biquad& q, float sr, float freq, float qfac, float gain_db)
{
  const float A = db_to_linear(gain_db);
  const float w0 = 2.0f * (float)M_PI * (freq / sr);
  const float cosw = cosf(w0), sinw = sinf(w0);
  const float alpha = sinw/(2.0f*qfac);
  const float b0 = 1 + alpha*A;
  const float b1 = -2*cosw;
  const float b2 = 1 - alpha*A;
  const float a0 = 1 + alpha/A;
  const float a1 = -2*cosw;
  const float a2 = 1 - alpha/A;
  q.b0=b0/a0; q.b1=b1/a0; q.b2=b2/a0; q.a1=a1/a0; q.a2=a2/a0; q.s1L=q.s2L=q.s1R=q.s2R=0;
}

inline void CoreAudioSound::processEQFrame(float& l, float& r)
{
  auto step = [](Biquad& q, float xL, float xR, float& yL, float& yR){
    // Direct Form II Transposed (more numerically stable)
    const float yl = q.b0*xL + q.s1L; q.s1L = q.b1*xL + q.s2L - q.a1*yl; q.s2L = q.b2*xL - q.a2*yl;
    const float yr = q.b0*xR + q.s1R; q.s1R = q.b1*xR + q.s2R - q.a1*yr; q.s2R = q.b2*xR - q.a2*yr;
    yL = yl; yR = yr;
  };
  float yl, yr;
  step(m_low_shelf, l, r, yl, yr); l = yl; r = yr;
  step(m_mid_peak, l, r, yl, yr); l = yl; r = yr;
  step(m_high_shelf, l, r, yl, yr); l = yl; r = yr;
}

OSStatus CoreAudioSound::callback(void* ref_con, AudioUnitRenderActionFlags* action_flags,
                                  const AudioTimeStamp* timestamp, UInt32 bus_number,
                                  UInt32 number_frames, AudioBufferList* io_data)
{
  auto* const sound = static_cast<CoreAudioSound*>(ref_con);
  for (UInt32 i = 0; i < io_data->mNumberBuffers; i++)
  {
    const AudioBuffer buffer = io_data->mBuffers[i];
    // 16-bit stereo: 4 bytes per frame; use shift to avoid divide in callback.
    sound->m_mixer->Mix(static_cast<short*>(buffer.mData), buffer.mDataByteSize >> 2);

    // Post-processing: convert to float, process, then back to int16_t.
    // RT-safety/perf: skip the entire int16->float->int16 round-trip when no FX
    // are active (the default). Output is then bit-identical to the raw Mix.
    const bool fx_active =
        sound->m_bitcrush_enabled || sound->m_eq_enabled || sound->m_delay_enabled;
    if (!fx_active)
      continue;

    const UInt32 frames = buffer.mDataByteSize >> 2;
    int16_t* pcm = static_cast<int16_t*>(buffer.mData);
    for (UInt32 f = 0; f < frames; ++f)
    {
      float l = pcm[2*f] / 32768.0f;
      float r = pcm[2*f+1] / 32768.0f;

      // Bitcrush (downsample + quantize)
      if (sound->m_bitcrush_enabled)
      {
        if (sound->m_bitcrush_hold == 0) {
          const int maxQ = std::max(1, std::min(16, sound->m_bitcrush_bits));
          const float step = 1.0f / ((1<<maxQ) - 1);
          sound->m_last_crush_L = roundf(l / step) * step;
          sound->m_last_crush_R = roundf(r / step) * step;
          sound->m_bitcrush_hold = std::max(1, sound->m_bitcrush_downsample);
        }
        l = sound->m_last_crush_L; r = sound->m_last_crush_R;
        sound->m_bitcrush_hold -= 1;
      }

      // EQ
      if (sound->m_eq_enabled)
        sound->processEQFrame(l, r);

      // Delay / Echo
      if (sound->m_delay_enabled && !sound->m_delayL.empty())
      {
        const size_t idx = sound->m_delay_index;
        const float dl = sound->m_delayL[idx];
        const float dr = sound->m_delayR[idx];
        // write new sample + feedback
        sound->m_delayL[idx] = l + dl * sound->m_delay_feedback;
        sound->m_delayR[idx] = r + dr * sound->m_delay_feedback;
        sound->m_delay_index = (idx + 1) % sound->m_delayL.size();
        // mix with mild wet amount
        l = l * 0.7f + dl * 0.3f;
        r = r * 0.7f + dr * 0.3f;
      }

      pcm[2*f]   = (int16_t)std::max(-32768.0f, std::min(32767.0f, l * 32768.0f));
      pcm[2*f+1] = (int16_t)std::max(-32768.0f, std::min(32767.0f, r * 32768.0f));
    }
  }

  return noErr;
}

bool CoreAudioSound::Init()
{
  OSStatus err;
  AURenderCallbackStruct callback_struct;
  AudioStreamBasicDescription format;
  AudioComponentDescription desc;
  AudioComponent component;

  desc.componentType = kAudioUnitType_Output;
  desc.componentSubType = kAudioUnitSubType_RemoteIO;
  desc.componentFlags = 0;
  desc.componentFlagsMask = 0;
  desc.componentManufacturer = kAudioUnitManufacturer_Apple;
  component = AudioComponentFindNext(nullptr, &desc);
  if (component == nullptr)
  {
    ERROR_LOG_FMT(AUDIO, "error finding audio component");
    return false;
  }

  err = AudioComponentInstanceNew(component, &audio_unit);
  if (err != noErr)
  {
    ERROR_LOG_FMT(AUDIO, "error opening audio component");
    return false;
  }

  // Reduce CPU overhead on iOS by disabling input path and allowing larger callback slices.
  {
    UInt32 disable_io = 0;
    (void)AudioUnitSetProperty(audio_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
                               1, &disable_io, sizeof(disable_io));
    UInt32 max_frames = 1024; // Favor fewer callbacks per second
    (void)AudioUnitSetProperty(audio_unit, kAudioUnitProperty_MaximumFramesPerSlice,
                               kAudioUnitScope_Global, 0, &max_frames, sizeof(max_frames));
  }

  FillOutASBDForLPCM(format, m_mixer->GetSampleRate(), 2, 16, 16, false, false, false);
  err = AudioUnitSetProperty(audio_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                             &format, sizeof(AudioStreamBasicDescription));
  if (err != noErr)
  {
    ERROR_LOG_FMT(AUDIO, "error setting audio format");
    return false;
  }

  callback_struct.inputProc = callback;
  callback_struct.inputProcRefCon = this;
  err = AudioUnitSetProperty(audio_unit, kAudioUnitProperty_SetRenderCallback,
                             kAudioUnitScope_Input, 0, &callback_struct, sizeof callback_struct);
  if (err != noErr)
  {
    ERROR_LOG_FMT(AUDIO, "error setting audio callback");
    return false;
  }

  err = AudioUnitSetParameter(audio_unit, kHALOutputParam_Volume, kAudioUnitScope_Output, 0,
                              m_volume / 100., 0);
  if (err != noErr)
    ERROR_LOG_FMT(AUDIO, "error setting volume");

  err = AudioUnitInitialize(audio_unit);
  if (err != noErr)
  {
    ERROR_LOG_FMT(AUDIO, "error initializing audiounit");
    return false;
  }

  // Prepare DSP filters at current sample rate
  updateDelayBuffers(m_mixer->GetSampleRate());
  computeLowShelf(m_low_shelf, (float)m_mixer->GetSampleRate(), 150.0f, m_eq_low_db);
  computePeak(m_mid_peak, (float)m_mixer->GetSampleRate(), 1000.0f, 0.707f, m_eq_mid_db);
  computeHighShelf(m_high_shelf, (float)m_mixer->GetSampleRate(), 6000.0f, m_eq_high_db);

  return true;
}

bool CoreAudioSound::SetRunning(bool running)
{
  OSStatus err;
  if (running)
  {
    err = AudioOutputUnitStart(audio_unit);
    if (err != noErr)
    {
      ERROR_LOG_FMT(AUDIO, "error starting audiounit");
      return false;
    }
  }
  else
  {
    err = AudioOutputUnitStop(audio_unit);
    if (err != noErr)
      ERROR_LOG_FMT(AUDIO, "error stopping audiounit");
  }
  return true;
}

void CoreAudioSound::SetVolume(int volume)
{
  OSStatus err;
  m_volume = volume;

  err = AudioUnitSetParameter(audio_unit, kHALOutputParam_Volume, kAudioUnitScope_Output, 0,
                              volume / 100., 0);
  if (err != noErr)
    ERROR_LOG_FMT(AUDIO, "error setting volume");
}

// Public setters
void CoreAudioSound::setDelayEnabled(bool enabled) { m_delay_enabled = enabled; }
void CoreAudioSound::setDelayMs(int ms) { m_delay_ms = std::max(1, std::min(4000, ms)); updateDelayBuffers(m_mixer->GetSampleRate()); }
void CoreAudioSound::setDelayFeedback(float fb) { m_delay_feedback = std::max(0.0f, std::min(0.95f, fb)); }

void CoreAudioSound::setBitcrushEnabled(bool enabled) { m_bitcrush_enabled = enabled; }
void CoreAudioSound::setBitcrushBits(int bits) { m_bitcrush_bits = std::max(4, std::min(16, bits)); }
void CoreAudioSound::setBitcrushDownsample(int factor) { m_bitcrush_downsample = std::max(1, std::min(16, factor)); }

void CoreAudioSound::setEQEnabled(bool enabled) { m_eq_enabled = enabled; }
void CoreAudioSound::setEQLowGainDb(float db) { m_eq_low_db = std::max(-24.0f, std::min(24.0f, db)); computeLowShelf(m_low_shelf, (float)m_mixer->GetSampleRate(), 150.0f, m_eq_low_db); }
void CoreAudioSound::setEQMidGainDb(float db) { m_eq_mid_db = std::max(-24.0f, std::min(24.0f, db)); computePeak(m_mid_peak, (float)m_mixer->GetSampleRate(), 1000.0f, 0.707f, m_eq_mid_db); }
void CoreAudioSound::setEQHighGainDb(float db) { m_eq_high_db = std::max(-24.0f, std::min(24.0f, db)); computeHighShelf(m_high_shelf, (float)m_mixer->GetSampleRate(), 6000.0f, m_eq_high_db); }
