// Copyright 2008 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#ifdef IPHONEOS
#include <AudioUnit/AudioUnit.h>
#endif

#include "AudioCommon/SoundStream.h"

#include <memory>
#include <vector>

namespace AudioCommon {
class SurroundDecoder;
}

class CoreAudioSound final : public SoundStream
{
#ifdef IPHONEOS
public:
  bool Init() override;
  bool SetRunning(bool running) override;
  void SetVolume(int volume) override;

  static bool IsValid() { return true; }

private:
  AudioUnit audio_unit;
  int m_volume;
  /// Number of output channels configured for the AudioUnit (2 or 6)
  int m_output_channels = 2;
  /// Whether the configured client format is interleaved
  bool m_output_interleaved = true;
  /// Whether the configured client format is float
  bool m_output_is_float = true;
  /// Optional Dolby Pro Logic II surround decoder when outputting 6 channels
  std::unique_ptr<AudioCommon::SurroundDecoder> m_surround;
  /// Temporary stereo buffer used to feed the surround decoder (interleaved int16)
  std::vector<short> m_stereo_temp;
  /// Temporary stereo float buffer for float output conversion
  std::vector<float> m_stereo_temp_float;
  /// Temporary 6-channel float buffer produced by the surround decoder (interleaved float)
  std::vector<float> m_surround_temp;
  /// Decoder frame block size used by SurroundDecoder
  unsigned int m_surround_block_size = 256u;

  static OSStatus callback(void* ref_con, AudioUnitRenderActionFlags* action_flags,
                           const AudioTimeStamp* timestamp, UInt32 bus_number, UInt32 number_frames,
                           AudioBufferList* io_data);
#endif
};
