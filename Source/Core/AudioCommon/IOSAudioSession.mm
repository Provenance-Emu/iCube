// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#ifdef IPHONEOS

#import <AVFoundation/AVFoundation.h>

#include "AudioCommon/IOSAudioSession.h"

#include <atomic>
#include <mutex>

#include "Common/Logging/Log.h"

namespace AudioCommon::IOSAudioSession
{
namespace
{
std::mutex s_hook_mutex;
MicrophoneSessionHook s_microphone_hook;
std::atomic<int> s_microphone_clients{0};

bool IsHeadphonePort(NSString* port_type)
{
  return [port_type isEqualToString:AVAudioSessionPortHeadphones] ||
         [port_type isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
         [port_type isEqualToString:AVAudioSessionPortBluetoothLE] ||
         [port_type isEqualToString:AVAudioSessionPortBluetoothHFP];
}

void CallHook(bool active)
{
  MicrophoneSessionHook hook;
  {
    std::lock_guard lock(s_hook_mutex);
    hook = s_microphone_hook;
  }
  if (!hook)
  {
    WARN_LOG_FMT(AUDIO, "Microphone session hook not registered; the session stays playback-only");
    return;
  }
  if ([NSThread isMainThread])
    hook(active);
  else
    dispatch_async(dispatch_get_main_queue(), ^{ hook(active); });
}
}  // namespace

RouteInfo QueryRoute()
{
  @autoreleasepool
  {
    AVAudioSession* session = [AVAudioSession sharedInstance];
    RouteInfo info;
    info.max_output_channels = static_cast<int>(session.maximumOutputNumberOfChannels);
    info.output_channels = static_cast<int>(session.outputNumberOfChannels);
    info.sample_rate = session.sampleRate;
    info.input_available = session.isInputAvailable;
    NSMutableArray<NSString*>* parts = [NSMutableArray array];
    for (AVAudioSessionPortDescription* out in session.currentRoute.outputs)
    {
      if (IsHeadphonePort(out.portType))
        info.headphones = true;
      if ([out.portType isEqualToString:AVAudioSessionPortHDMI])
        info.hdmi = true;
      [parts addObject:[NSString stringWithFormat:@"%@:%@", out.portType, out.portName]];
    }
    info.description = parts.count > 0 ? [parts componentsJoinedByString:@", "].UTF8String : "(none)";
    return info;
  }
}

int RequestOutputChannels(int count)
{
  @autoreleasepool
  {
    AVAudioSession* session = [AVAudioSession sharedInstance];
    const int max = static_cast<int>(session.maximumOutputNumberOfChannels);
    const int wanted = std::min(count, std::max(max, 1));
    NSError* error = nil;
    if (![session setPreferredOutputNumberOfChannels:wanted error:&error])
    {
      WARN_LOG_FMT(AUDIO, "setPreferredOutputNumberOfChannels({}) failed: {}", wanted,
                   error.localizedDescription.UTF8String ?: "unknown");
    }
    const int granted = static_cast<int>(session.outputNumberOfChannels);
    INFO_LOG_FMT(AUDIO, "Output channels: wanted {} (route max {}), got {}", count, max, granted);
    return granted;
  }
}

void SetSupportsMultichannelContent(bool enabled)
{
  @autoreleasepool
  {
    NSError* error = nil;
    if (![[AVAudioSession sharedInstance] setSupportsMultichannelContent:enabled error:&error])
    {
      WARN_LOG_FMT(AUDIO, "setSupportsMultichannelContent({}) failed: {}", enabled,
                   error.localizedDescription.UTF8String ?: "unknown");
    }
  }
}

void SetMicrophoneSessionHook(MicrophoneSessionHook hook)
{
  std::lock_guard lock(s_hook_mutex);
  s_microphone_hook = std::move(hook);
}

void AddMicrophoneClient()
{
  if (s_microphone_clients.fetch_add(1) == 0)
    CallHook(true);
}

void RemoveMicrophoneClient()
{
  if (s_microphone_clients.fetch_sub(1) == 1)
    CallHook(false);
}
}  // namespace AudioCommon::IOSAudioSession

#endif  // IPHONEOS
