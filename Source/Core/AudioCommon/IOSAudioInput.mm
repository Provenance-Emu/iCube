// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#ifdef IPHONEOS

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

#include "AudioCommon/IOSAudioInput.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <mutex>
#include <vector>

#include "AudioCommon/IOSAudioSession.h"
#include "Common/Logging/Log.h"

@class IOSAudioInputObserver;

/// Everything that outlives a Start/Stop cycle. Shared with the deferred permission and
/// route-change blocks, so a late block finds `dead` set instead of freed memory.
struct IOSAudioInput::Impl
{
  Impl(std::string name_, Callback callback_) : name(std::move(name_)), callback(std::move(callback_))
  {
    render_buffer.resize(kMaxFramesPerSlice);
  }

  static constexpr UInt32 kInputBus = 1;
  static constexpr UInt32 kOutputBus = 0;
  static constexpr UInt32 kMaxFramesPerSlice = 4096;

  bool OpenUnit();
  void CloseUnit();
  void Shutdown();
  void HandleRouteChange();
  OSStatus RenderInput(AudioUnitRenderActionFlags* flags, const AudioTimeStamp* ts, UInt32 bus,
                       UInt32 frames);
  void HandleInput(const float* in, std::size_t frames);

  const std::string name;
  const Callback callback;

  std::mutex mutex;  // guards unit, observer, session_client, dead and the resampler setup
  AudioComponentInstance unit = nullptr;
  IOSAudioInputObserver* observer = nil;
  bool session_client = false;
  bool dead = false;

  std::atomic<bool> running{false};
  std::atomic<bool> want_running{false};
  u32 target_rate = 0;
  double hardware_rate = 0;

  // Render-thread state.
  std::vector<float> render_buffer;
  std::vector<s16> out_buffer;
  double phase = 0;
  float last_sample = 0;
};

namespace
{
OSStatus InputProc(void* ref_con, AudioUnitRenderActionFlags* flags, const AudioTimeStamp* ts,
                   UInt32 bus, UInt32 frames, AudioBufferList*)
{
  return static_cast<IOSAudioInput::Impl*>(ref_con)->RenderInput(flags, ts, bus, frames);
}
}  // namespace

@interface IOSAudioInputObserver : NSObject
{
  std::weak_ptr<IOSAudioInput::Impl> _impl;
}
- (instancetype)initWithImpl:(std::shared_ptr<IOSAudioInput::Impl>)impl;
@end

@implementation IOSAudioInputObserver
- (instancetype)initWithImpl:(std::shared_ptr<IOSAudioInput::Impl>)impl
{
  if ((self = [super init]))
  {
    _impl = impl;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(routeChanged:)
                                                 name:AVAudioSessionRouteChangeNotification
                                               object:[AVAudioSession sharedInstance]];
  }
  return self;
}
- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}
- (void)routeChanged:(NSNotification*)note
{
  (void)note;
  std::weak_ptr<IOSAudioInput::Impl> weak = _impl;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (auto impl = weak.lock())
      impl->HandleRouteChange();
  });
}
@end

// MARK: - Impl

bool IOSAudioInput::Impl::OpenUnit()
{
  std::lock_guard lock(mutex);
  if (dead || unit)
    return unit != nullptr;

  // Ask the app for a recording category first. The hook runs synchronously on the main queue,
  // which is where OpenUnit is always called from.
  if (!session_client)
  {
    AudioCommon::IOSAudioSession::AddMicrophoneClient();
    session_client = true;
  }

  AudioComponentDescription desc{};
  desc.componentType = kAudioUnitType_Output;
  desc.componentSubType = kAudioUnitSubType_RemoteIO;
  desc.componentManufacturer = kAudioUnitManufacturer_Apple;
  AudioComponent component = AudioComponentFindNext(nullptr, &desc);
  if (!component)
  {
    ERROR_LOG_FMT(AUDIO, "{}: RemoteIO component not found", name);
    return false;
  }
  OSStatus err = AudioComponentInstanceNew(component, &unit);
  if (err != noErr)
  {
    ERROR_LOG_FMT(AUDIO, "{}: AudioComponentInstanceNew failed ({})", name, err);
    unit = nullptr;
    return false;
  }

  auto fail = [&](const char* what) {
    ERROR_LOG_FMT(AUDIO, "{}: {} failed ({})", name, what, err);
    AudioComponentInstanceDispose(unit);
    unit = nullptr;
    return false;
  };

  UInt32 enable = 1, disable = 0;
  AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, kInputBus,
                       &enable, sizeof(enable));
  AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, kOutputBus,
                       &disable, sizeof(disable));

  hardware_rate = [AVAudioSession sharedInstance].sampleRate;
  if (hardware_rate <= 0)
    hardware_rate = 48000.0;
  AudioStreamBasicDescription format{};
  format.mSampleRate = hardware_rate;
  format.mFormatID = kAudioFormatLinearPCM;
  format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
  format.mChannelsPerFrame = 1;
  format.mBitsPerChannel = 32;
  format.mBytesPerFrame = 4;
  format.mFramesPerPacket = 1;
  format.mBytesPerPacket = 4;
  err = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
                             kInputBus, &format, sizeof(format));
  if (err != noErr)
    return fail("setting the input format");

  UInt32 max_frames = kMaxFramesPerSlice;
  AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                       &max_frames, sizeof(max_frames));

  AURenderCallbackStruct input_callback{};
  input_callback.inputProc = InputProc;
  input_callback.inputProcRefCon = this;
  err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                             kAudioUnitScope_Global, kInputBus, &input_callback,
                             sizeof(input_callback));
  if (err != noErr)
    return fail("setting the input callback");

  err = AudioUnitInitialize(unit);
  if (err != noErr)
    return fail("AudioUnitInitialize");

  phase = 0;
  last_sample = 0;
  out_buffer.resize(static_cast<std::size_t>(kMaxFramesPerSlice * target_rate / hardware_rate) +
                    4);
  err = AudioOutputUnitStart(unit);
  if (err != noErr)
  {
    AudioUnitUninitialize(unit);
    return fail("AudioOutputUnitStart");
  }
  running.store(true);
  INFO_LOG_FMT(AUDIO, "{}: capturing at {} Hz (hardware {} Hz)", name, target_rate,
               hardware_rate);
  return true;
}

void IOSAudioInput::Impl::CloseUnit()
{
  std::lock_guard lock(mutex);
  running.store(false);
  if (unit)
  {
    // AudioOutputUnitStop returns only after an in-flight input callback has finished.
    AudioOutputUnitStop(unit);
    AudioUnitUninitialize(unit);
    AudioComponentInstanceDispose(unit);
    unit = nullptr;
  }
  if (session_client && !want_running.load())
  {
    AudioCommon::IOSAudioSession::RemoveMicrophoneClient();
    session_client = false;
  }
}

void IOSAudioInput::Impl::Shutdown()
{
  want_running.store(false);
  CloseUnit();
  std::lock_guard lock(mutex);
  dead = true;
  observer = nil;
}

void IOSAudioInput::Impl::HandleRouteChange()
{
  if (!want_running.load() || !running.load())
    return;
  const double rate = [AVAudioSession sharedInstance].sampleRate;
  if (rate > 0 && std::fabs(rate - hardware_rate) < 1.0)
    return;
  INFO_LOG_FMT(AUDIO, "{}: hardware rate changed {} -> {}, reopening", name, hardware_rate, rate);
  CloseUnit();
  OpenUnit();
}

OSStatus IOSAudioInput::Impl::RenderInput(AudioUnitRenderActionFlags* flags,
                                          const AudioTimeStamp* ts, UInt32 bus, UInt32 frames)
{
  // The unit is only disposed under `mutex` after AudioOutputUnitStop returned, so `unit` and
  // `render_buffer` are valid for the duration of this callback.
  if (!unit || frames == 0)
    return noErr;
  frames = std::min<UInt32>(frames, static_cast<UInt32>(render_buffer.size()));
  AudioBufferList list;
  list.mNumberBuffers = 1;
  list.mBuffers[0].mNumberChannels = 1;
  list.mBuffers[0].mDataByteSize = frames * sizeof(float);
  list.mBuffers[0].mData = render_buffer.data();
  const OSStatus err = AudioUnitRender(unit, flags, ts, bus, frames, &list);
  if (err != noErr)
    return err;
  HandleInput(render_buffer.data(), frames);
  return noErr;
}

void IOSAudioInput::Impl::HandleInput(const float* in, std::size_t frames)
{
  if (frames == 0 || target_rate == 0)
    return;
  // Linear interpolation. `phase` is the read position + 1 within the virtual stream
  // v[-1] = last_sample, v[k] = in[k], so an index of 0 means "between v[-1] and in[0]".
  const double step = hardware_rate / static_cast<double>(target_rate);
  double q = phase;
  std::size_t out = 0;
  const std::size_t capacity = out_buffer.size();
  while (q < static_cast<double>(frames) && out < capacity)
  {
    const std::size_t idx = static_cast<std::size_t>(q);
    const float a = idx == 0 ? last_sample : in[idx - 1];
    const float b = in[idx];
    const float frac = static_cast<float>(q - static_cast<double>(idx));
    const float v = std::clamp(a + (b - a) * frac, -1.0f, 1.0f);
    out_buffer[out++] = static_cast<s16>(std::lrint(v * 32767.0f));
    q += step;
  }
  phase = q - static_cast<double>(frames);
  last_sample = in[frames - 1];
  if (out > 0 && callback)
    callback(out_buffer.data(), out);
}

// MARK: - IOSAudioInput

IOSAudioInput::IOSAudioInput(std::string name, Callback callback)
    : m_impl(std::make_shared<Impl>(std::move(name), std::move(callback)))
{
}

IOSAudioInput::~IOSAudioInput()
{
  m_impl->Shutdown();
}

bool IOSAudioInput::IsRunning() const
{
  return m_impl->running.load();
}

bool IOSAudioInput::IsSupported()
{
#if TARGET_OS_TV
  return false;
#else
  return [AVAudioSession sharedInstance].isInputAvailable;
#endif
}

IOSAudioInput::Permission IOSAudioInput::GetPermission()
{
#if TARGET_OS_TV
  return Permission::Denied;
#else
  switch ([AVAudioApplication sharedInstance].recordPermission)
  {
  case AVAudioApplicationRecordPermissionGranted:
    return Permission::Granted;
  case AVAudioApplicationRecordPermissionDenied:
    return Permission::Denied;
  default:
    return Permission::Undetermined;
  }
#endif
}

void IOSAudioInput::RequestPermission(std::function<void(bool granted)> completion)
{
#if TARGET_OS_TV
  if (completion)
    completion(false);
#else
  [AVAudioApplication requestRecordPermissionWithCompletionHandler:^(BOOL granted) {
    if (completion)
      completion(granted);
  }];
#endif
}

bool IOSAudioInput::Start(u32 sample_rate)
{
  Impl& impl = *m_impl;
  if (!IsSupported())
  {
    WARN_LOG_FMT(AUDIO, "{}: no microphone available on this device", impl.name);
    return false;
  }
  impl.target_rate = std::max<u32>(1, sample_rate);
  impl.want_running.store(true);

  const Permission permission = GetPermission();
  if (permission == Permission::Denied)
  {
    WARN_LOG_FMT(AUDIO, "{}: microphone permission denied; capturing silence", impl.name);
    return false;
  }

  // The unit is opened on the main queue so the app's session hook (which runs synchronously
  // there) has switched to a recording category before the input bus is initialized.
  std::weak_ptr<Impl> weak = m_impl;
  auto open_on_main = [weak] {
    dispatch_async(dispatch_get_main_queue(), ^{
      auto impl = weak.lock();
      if (!impl)
        return;
      if (impl->want_running.load() && !impl->running.load())
      {
        {
          std::lock_guard lock(impl->mutex);
          if (impl->dead)
            return;
          if (!impl->observer)
            impl->observer = [[IOSAudioInputObserver alloc] initWithImpl:impl];
        }
        impl->OpenUnit();
      }
    });
  };

  if (permission == Permission::Granted)
  {
    open_on_main();
    return true;
  }
  RequestPermission([open_on_main, name = impl.name](bool granted) {
    if (granted)
      open_on_main();
    else
      WARN_LOG_FMT(AUDIO, "{}: microphone permission refused", name);
  });
  return true;
}

void IOSAudioInput::Stop()
{
  m_impl->want_running.store(false);
  m_impl->CloseUnit();
}

#endif  // IPHONEOS
