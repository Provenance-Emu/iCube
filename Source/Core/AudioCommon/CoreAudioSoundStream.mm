// Copyright 2008 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#ifdef IPHONEOS

#import <AVFoundation/AVFoundation.h>
#include <AudioUnit/AudioUnit.h>

#include "AudioCommon/CoreAudioSoundStream.h"

#include <algorithm>
#include <cstring>

#include "AudioCommon/IOSAudioSession.h"
#include "Common/Logging/Log.h"
#include "Core/Config/MainSettings.h"

namespace
{
constexpr UInt32 kOutputBus = 0;
constexpr UInt32 kInputBus = 1;
constexpr UInt32 kMaxFramesPerSlice = 4096;
constexpr u32 kSurroundChannels = 6;
}  // namespace

CoreAudioSound::CoreAudioSound() = default;

CoreAudioSound::~CoreAudioSound()
{
  UnregisterObservers();
  if (m_has_config_callback)
    Config::RemoveConfigChangedCallback(m_config_callback);
  std::lock_guard lock(m_guard->mutex);
  m_guard->alive = false;
  CloseUnitLocked();
}

OSStatus CoreAudioSound::RenderCallback(void* ref_con, AudioUnitRenderActionFlags*,
                                        const AudioTimeStamp*, UInt32, UInt32 number_frames,
                                        AudioBufferList* io_data)
{
  return static_cast<CoreAudioSound*>(ref_con)->Render(number_frames, io_data);
}

OSStatus CoreAudioSound::Render(UInt32 number_frames, AudioBufferList* io_data)
{
  for (UInt32 i = 0; i < io_data->mNumberBuffers; i++)
  {
    AudioBuffer& buffer = io_data->mBuffers[i];
    if (m_surround.load(std::memory_order_relaxed))
    {
      // Interleaved float, six channels: 24 bytes per frame.
      const std::size_t frames = buffer.mDataByteSize / (kSurroundChannels * sizeof(float));
      float* out = static_cast<float*>(buffer.mData);
      const std::size_t mixed = m_mixer->MixSurround(out, frames);
      if (mixed < frames)
        std::memset(out + mixed * kSurroundChannels, 0,
                    (frames - mixed) * kSurroundChannels * sizeof(float));
      m_dsp.Process(out, frames);
    }
    else
    {
      // 16-bit stereo: 4 bytes per frame.
      const std::size_t frames = buffer.mDataByteSize >> 2;
      s16* out = static_cast<s16*>(buffer.mData);
      m_mixer->Mix(out, frames);
      // Skips the int16 -> float -> int16 round trip when nothing is enabled and volume is 100 %.
      m_dsp.ProcessS16(out, frames);
    }
  }
  return noErr;
}

bool CoreAudioSound::WantsSurround() const
{
  return Config::Get(Config::MAIN_DPL2_DECODER);
}

bool CoreAudioSound::OpenUnitLocked()
{
  if (m_unit)
    return true;

  const u32 sample_rate = m_mixer->GetSampleRate();
  const bool wants_surround = WantsSurround();
  const auto route = AudioCommon::IOSAudioSession::QueryRoute();
  u32 channels = 2;
  if (wants_surround && route.max_output_channels >= static_cast<int>(kSurroundChannels))
  {
    const int granted = AudioCommon::IOSAudioSession::RequestOutputChannels(kSurroundChannels);
    if (granted >= static_cast<int>(kSurroundChannels))
      channels = kSurroundChannels;
  }
  else if (route.output_channels > 2)
  {
    // A previous surround build left the session on six channels; go back to stereo.
    AudioCommon::IOSAudioSession::RequestOutputChannels(2);
  }
  AudioCommon::IOSAudioSession::SetSupportsMultichannelContent(wants_surround);

  AudioComponentDescription desc{};
  desc.componentType = kAudioUnitType_Output;
  desc.componentSubType = kAudioUnitSubType_RemoteIO;
  desc.componentManufacturer = kAudioUnitManufacturer_Apple;
  AudioComponent component = AudioComponentFindNext(nullptr, &desc);
  if (component == nullptr)
  {
    ERROR_LOG_FMT(AUDIO, "CoreAudio: RemoteIO component not found");
    return false;
  }
  OSStatus err = AudioComponentInstanceNew(component, &m_unit);
  if (err != noErr)
  {
    ERROR_LOG_FMT(AUDIO, "CoreAudio: AudioComponentInstanceNew failed ({})", err);
    m_unit = nullptr;
    return false;
  }
  auto fail = [&](const char* what) {
    ERROR_LOG_FMT(AUDIO, "CoreAudio: {} failed ({})", what, err);
    AudioComponentInstanceDispose(m_unit);
    m_unit = nullptr;
    return false;
  };

  // Output only: the microphone devices open their own input unit.
  UInt32 disable_io = 0;
  AudioUnitSetProperty(m_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, kInputBus,
                       &disable_io, sizeof(disable_io));
  UInt32 max_frames = kMaxFramesPerSlice;
  AudioUnitSetProperty(m_unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global,
                       0, &max_frames, sizeof(max_frames));

  AudioStreamBasicDescription format;
  if (channels == kSurroundChannels)
    FillOutASBDForLPCM(format, sample_rate, kSurroundChannels, 32, 32, true, false, false);
  else
    FillOutASBDForLPCM(format, sample_rate, 2, 16, 16, false, false, false);
  err = AudioUnitSetProperty(m_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                             kOutputBus, &format, sizeof(format));
  if (err != noErr)
    return fail("setting the stream format");

  if (channels == kSurroundChannels)
  {
    // Mixer::MixSurround order: L R C LFE Ls Rs.
    AudioChannelLayout layout{};
    layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A;
    err = AudioUnitSetProperty(m_unit, kAudioUnitProperty_AudioChannelLayout, kAudioUnitScope_Input,
                               kOutputBus, &layout, sizeof(layout));
    if (err != noErr)
      WARN_LOG_FMT(AUDIO, "CoreAudio: setting the 5.1 channel layout failed ({})", err);
  }

  AURenderCallbackStruct callback_struct{};
  callback_struct.inputProc = RenderCallback;
  callback_struct.inputProcRefCon = this;
  err = AudioUnitSetProperty(m_unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
                             kOutputBus, &callback_struct, sizeof(callback_struct));
  if (err != noErr)
    return fail("setting the render callback");

  err = AudioUnitInitialize(m_unit);
  if (err != noErr)
    return fail("AudioUnitInitialize");

  m_channels = channels;
  m_dsp.Configure(sample_rate, channels);
  m_surround.store(channels == kSurroundChannels);
  INFO_LOG_FMT(AUDIO, "CoreAudio: {} channels at {} Hz on {}", channels, sample_rate,
               route.description);
  return true;
}

void CoreAudioSound::CloseUnitLocked()
{
  if (!m_unit)
    return;
  StopUnitLocked();
  AudioUnitUninitialize(m_unit);
  AudioComponentInstanceDispose(m_unit);
  m_unit = nullptr;
}

bool CoreAudioSound::StartUnitLocked()
{
  if (!m_unit || m_unit_running.load())
    return m_unit != nullptr;
  const OSStatus err = AudioOutputUnitStart(m_unit);
  if (err != noErr)
  {
    ERROR_LOG_FMT(AUDIO, "CoreAudio: AudioOutputUnitStart failed ({})", err);
    return false;
  }
  m_unit_running.store(true);
  return true;
}

void CoreAudioSound::StopUnitLocked()
{
  if (!m_unit || !m_unit_running.load())
    return;
  const OSStatus err = AudioOutputUnitStop(m_unit);
  if (err != noErr)
    ERROR_LOG_FMT(AUDIO, "CoreAudio: AudioOutputUnitStop failed ({})", err);
  m_unit_running.store(false);
}

void CoreAudioSound::RebuildLocked()
{
  CloseUnitLocked();
  if (OpenUnitLocked() && m_should_run.load())
    StartUnitLocked();
}

void CoreAudioSound::RefreshFromConfig()
{
  m_dsp.LoadFromConfig();
  // Surround on/off needs a different unit format; everything else is live.
  const bool wants_surround = WantsSurround();
  const auto route = AudioCommon::IOSAudioSession::QueryRoute();
  const bool can_surround = route.max_output_channels >= static_cast<int>(kSurroundChannels);
  if ((wants_surround && can_surround) != m_surround.load())
  {
    std::shared_ptr<Guard> guard = m_guard;
    CoreAudioSound* self_ptr = this;
    dispatch_async(dispatch_get_main_queue(), ^{
      std::lock_guard lock(guard->mutex);
      if (guard->alive)
        self_ptr->RebuildLocked();
    });
  }
}

void CoreAudioSound::RegisterObservers()
{
  AVAudioSession* session = [AVAudioSession sharedInstance];
  NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
  CoreAudioSound* self_ptr = this;
  std::shared_ptr<Guard> guard = m_guard;

  m_interrupt_token = [center
      addObserverForName:AVAudioSessionInterruptionNotification
                  object:session
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(NSNotification* note) {
                const auto type = (AVAudioSessionInterruptionType)
                    [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
                std::lock_guard lock(guard->mutex);
                if (!guard->alive)
                  return;
                if (type == AVAudioSessionInterruptionTypeBegan)
                {
                  INFO_LOG_FMT(AUDIO, "CoreAudio: interruption began");
                  self_ptr->StopUnitLocked();
                  return;
                }
                const auto options = (AVAudioSessionInterruptionOptions)
                    [note.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
                INFO_LOG_FMT(AUDIO, "CoreAudio: interruption ended (should resume: {})",
                             (options & AVAudioSessionInterruptionOptionShouldResume) != 0);
                [session setActive:YES error:nil];
                if (self_ptr->m_should_run.load())
                  self_ptr->StartUnitLocked();
              }];

  m_route_token = [center
      addObserverForName:AVAudioSessionRouteChangeNotification
                  object:session
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(NSNotification* note) {
                (void)note;
                std::lock_guard lock(guard->mutex);
                if (!guard->alive)
                  return;
                // RemoteIO follows the route by itself; only a change in how many channels the
                // route can carry needs a new unit.
                const auto route = AudioCommon::IOSAudioSession::QueryRoute();
                const bool can_surround =
                    route.max_output_channels >= static_cast<int>(kSurroundChannels);
                const bool want = self_ptr->WantsSurround() && can_surround;
                if (want != self_ptr->m_surround.load())
                  self_ptr->RebuildLocked();
              }];

  m_reset_token = [center addObserverForName:AVAudioSessionMediaServicesWereResetNotification
                                      object:session
                                       queue:[NSOperationQueue mainQueue]
                                  usingBlock:^(NSNotification* note) {
                                    (void)note;
                                    std::lock_guard lock(guard->mutex);
                                    if (!guard->alive)
                                      return;
                                    WARN_LOG_FMT(AUDIO, "CoreAudio: media services reset");
                                    [session setActive:YES error:nil];
                                    self_ptr->RebuildLocked();
                                  }];
}

void CoreAudioSound::UnregisterObservers()
{
  NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
  if (m_interrupt_token)
    [center removeObserver:m_interrupt_token];
  if (m_route_token)
    [center removeObserver:m_route_token];
  if (m_reset_token)
    [center removeObserver:m_reset_token];
  m_interrupt_token = nil;
  m_route_token = nil;
  m_reset_token = nil;
}

bool CoreAudioSound::Init()
{
  m_dsp.LoadFromConfig();
  SetVolume(m_volume);
  m_config_callback = Config::AddConfigChangedCallback([this] { RefreshFromConfig(); });
  m_has_config_callback = true;

  bool ok;
  {
    std::lock_guard lock(m_guard->mutex);
    ok = OpenUnitLocked();
  }
  if (!ok)
    return false;
  RegisterObservers();
  return true;
}

bool CoreAudioSound::SetRunning(bool running)
{
  m_should_run.store(running);
  std::lock_guard lock(m_guard->mutex);
  if (running)
    return StartUnitLocked();
  StopUnitLocked();
  return true;
}

void CoreAudioSound::SetVolume(int volume)
{
  // RemoteIO has no output volume parameter on iOS: apply the gain in the render callback.
  m_volume = std::clamp(volume, 0, 100);
  auto params = m_dsp.GetParameters();
  params.gain = m_volume / 100.0f;
  m_dsp.SetParameters(params);
}

#endif  // IPHONEOS
