// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#ifdef IPHONEOS

#include <functional>
#include <string>

#include "Common/CommonTypes.h"

/// What the audio backends need to know about the AVAudioSession route, plus the hook the app
/// registers so the core can ask for a recording-capable session while a microphone is open. The
/// app (AudioSessionManager) owns the category; the core only reports its needs.
namespace AudioCommon::IOSAudioSession
{
struct RouteInfo
{
  /// Channels the current hardware route can carry at most (6 on an HDMI 5.1 path).
  int max_output_channels = 2;
  /// Channels the session is currently configured for.
  int output_channels = 2;
  double sample_rate = 48000.0;
  /// Wired headphones, Bluetooth A2DP/LE or similar personal listening routes.
  bool headphones = false;
  bool hdmi = false;
  bool input_available = false;
  /// "HDMI:Living Room TV, BluetoothA2DP:AirPods Pro" for logs and the settings caption.
  std::string description;
};

RouteInfo QueryRoute();

/// Asks the session for `count` output channels. Returns the number actually granted.
int RequestOutputChannels(int count);

/// Marks the session as carrying multichannel content so headphone routes may spatialize it.
void SetSupportsMultichannelContent(bool enabled);

using MicrophoneSessionHook = std::function<void(bool active)>;
/// Registered once by the app. Called with true when the first microphone client opens and false
/// when the last one closes, always on the main queue.
void SetMicrophoneSessionHook(MicrophoneSessionHook hook);
void AddMicrophoneClient();
void RemoveMicrophoneClient();
}  // namespace AudioCommon::IOSAudioSession

#endif  // IPHONEOS
