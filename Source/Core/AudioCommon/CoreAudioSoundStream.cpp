// Copyright 2008 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <AudioUnit/AudioUnit.h>
#include <cstring>

 #include "AudioCommon/CoreAudioSoundStream.h"
#include "AudioCommon/SurroundDecoder.h"
#include "Common/Logging/Log.h"

OSStatus CoreAudioSound::callback(void* ref_con, AudioUnitRenderActionFlags* action_flags,
                                  const AudioTimeStamp* timestamp, UInt32 bus_number,
                                  UInt32 number_frames, AudioBufferList* io_data)
{
  auto* const sound = static_cast<CoreAudioSound*>(ref_con);
  if (sound->m_output_channels == 6 && sound->m_surround)
  {
    // Ensure decoder has enough input to produce requested surround frames
    const size_t needed = sound->m_surround->QueryFramesNeededForSurroundOutput(number_frames);
    if (needed > 0)
    {
      sound->m_stereo_temp.resize(needed * 2);
      sound->m_mixer->Mix(sound->m_stereo_temp.data(), static_cast<u32>(needed));
      sound->m_surround->PutFrames(sound->m_stereo_temp.data(), needed);
    }

    // Produce 6-channel float frames (interleaved)
    sound->m_surround_temp.resize(static_cast<size_t>(number_frames) * 6);
    sound->m_surround->ReceiveFrames(sound->m_surround_temp.data(), number_frames);

    if (sound->m_output_is_float)
    {
      if (sound->m_output_interleaved)
      {
        // Interleaved float output expected in buffer 0
        if (io_data->mNumberBuffers >= 1)
        {
          AudioBuffer& buffer = io_data->mBuffers[0];
          const size_t bytes = sound->m_surround_temp.size() * sizeof(float);
          std::memcpy(buffer.mData, sound->m_surround_temp.data(), std::min<size_t>(buffer.mDataByteSize, bytes));
        }
      }
      else
      {
        // Non-interleaved: one buffer per channel
        const size_t frames = number_frames;
        for (UInt32 ch = 0; ch < io_data->mNumberBuffers && ch < 6; ++ch)
        {
          float* dst = static_cast<float*>(io_data->mBuffers[ch].mData);
          const float* src = sound->m_surround_temp.data() + ch;
          for (size_t f = 0; f < frames; ++f)
            dst[f] = src[f * 6];
        }
      }
    }
    else
    {
      // Unexpected int output: convert float [-1,1] to int16
      if (sound->m_output_interleaved)
      {
        if (io_data->mNumberBuffers >= 1)
        {
          int16_t* dst = static_cast<int16_t*>(io_data->mBuffers[0].mData);
          const size_t frames = number_frames;
          for (size_t f = 0; f < frames; ++f)
          {
            for (int ch = 0; ch < 6; ++ch)
            {
              const float s = sound->m_surround_temp[f * 6 + ch];
              const float clamped = std::max(-1.0f, std::min(1.0f, s));
              dst[f * 6 + ch] = static_cast<int16_t>(clamped * 32767.0f);
            }
          }
        }
      }
      else
      {
        for (UInt32 ch = 0; ch < io_data->mNumberBuffers && ch < 6; ++ch)
        {
          int16_t* dst = static_cast<int16_t*>(io_data->mBuffers[ch].mData);
          const size_t frames = number_frames;
          const float* src = sound->m_surround_temp.data() + ch;
          for (size_t f = 0; f < frames; ++f)
          {
            const float s = src[f * 6];
            const float clamped = std::max(-1.0f, std::min(1.0f, s));
            dst[f] = static_cast<int16_t>(clamped * 32767.0f);
          }
        }
      }
    }
  }
  else
  {
    // Stereo path
    if (sound->m_output_is_float)
    {
      // Mix to int16 then convert to float for output
      const size_t frames = number_frames;
      sound->m_stereo_temp.resize(frames * 2);
      sound->m_mixer->Mix(sound->m_stereo_temp.data(), static_cast<u32>(frames));
      sound->m_stereo_temp_float.resize(frames * 2);
      const float inv = 1.0f / 32768.0f;
      for (size_t i = 0; i < frames * 2; ++i)
        sound->m_stereo_temp_float[i] = static_cast<float>(sound->m_stereo_temp[i]) * inv;

      if (sound->m_output_interleaved)
      {
        if (io_data->mNumberBuffers >= 1)
        {
          AudioBuffer& buffer = io_data->mBuffers[0];
          const size_t bytes = frames * 2 * sizeof(float);
          std::memcpy(buffer.mData, sound->m_stereo_temp_float.data(), std::min<size_t>(buffer.mDataByteSize, bytes));
        }
      }
      else
      {
        for (UInt32 ch = 0; ch < io_data->mNumberBuffers && ch < 2; ++ch)
        {
          float* dst = static_cast<float*>(io_data->mBuffers[ch].mData);
          const float* src = sound->m_stereo_temp_float.data() + ch;
          for (size_t f = 0; f < frames; ++f) dst[f] = src[f * 2];
        }
      }
    }
    else
    {
      // Int16 output (existing behavior)
      for (UInt32 i = 0; i < io_data->mNumberBuffers; i++)
      {
        const AudioBuffer buffer = io_data->mBuffers[i];
        sound->m_mixer->Mix(static_cast<short*>(buffer.mData), buffer.mDataByteSize >> 2);
      }
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

  // Try to configure 6-channel Float32 interleaved output. If unsupported, fall back to stereo int16.
  {
    AudioStreamBasicDescription fmt6;
    FillOutASBDForLPCM(fmt6, m_mixer->GetSampleRate(), 6, 32, 32, true, false, false);
    err = AudioUnitSetProperty(audio_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                               &fmt6, sizeof(AudioStreamBasicDescription));
    if (err == noErr)
    {
      m_output_channels = 6;
      m_output_interleaved = (fmt6.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0;
      m_output_is_float = (fmt6.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
      m_surround = std::make_unique<AudioCommon::SurroundDecoder>(m_mixer->GetSampleRate(), m_surround_block_size);
    }
    else
    {
      FillOutASBDForLPCM(format, m_mixer->GetSampleRate(), 2, 16, 16, false, false, false);
      err = AudioUnitSetProperty(audio_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                 &format, sizeof(AudioStreamBasicDescription));
      if (err != noErr)
      {
        ERROR_LOG_FMT(AUDIO, "error setting audio format");
        return false;
      }
      m_output_channels = 2;
      m_output_interleaved = true;
      m_output_is_float = false;
      m_surround.reset();
    }

    // Query back the actual client format in case AU altered it
    UInt32 size = sizeof(AudioStreamBasicDescription);
    AudioStreamBasicDescription got = {};
    if (AudioUnitGetProperty(audio_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &got, &size) == noErr)
    {
      m_output_channels = static_cast<int>(got.mChannelsPerFrame);
      m_output_interleaved = (got.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0;
      m_output_is_float = (got.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
      if (m_output_channels != 6)
        m_surround.reset();
    }
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
