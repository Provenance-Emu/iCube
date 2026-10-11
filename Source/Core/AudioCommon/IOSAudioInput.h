// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#ifdef IPHONEOS

#include <cstddef>
#include <functional>
#include <memory>
#include <string>

#include "Common/CommonTypes.h"

/// Microphone capture for the emulated GameCube microphone and the Wii Speak / Logitech USB
/// microphones, standing in for the cubeb input stream those devices use on desktop.
///
/// One instance per emulated device. Delivers mono signed 16-bit frames at the requested rate from
/// the Core Audio input thread; the callback must be cheap (the devices copy into a ring buffer).
/// Starting a stream asks for record permission on first use and tells the app, through
/// IOSAudioSession's microphone hook, to move the session into a recording category.
///
/// The destructor stops capture synchronously: once it returns the callback is never invoked again.
class IOSAudioInput final
{
public:
  using Callback = std::function<void(const s16* samples, std::size_t frames)>;

  enum class Permission
  {
    Undetermined,
    Denied,
    Granted,
  };

  IOSAudioInput(std::string name, Callback callback);
  ~IOSAudioInput();

  IOSAudioInput(const IOSAudioInput&) = delete;
  IOSAudioInput& operator=(const IOSAudioInput&) = delete;

  /// Starts capture at `sample_rate` Hz. Returns false when the platform has no microphone (tvOS)
  /// or permission is denied; when permission is still undetermined the stream starts once the
  /// user answers the prompt.
  bool Start(u32 sample_rate);
  void Stop();
  bool IsRunning() const;

  /// False where no app-accessible microphone exists (tvOS, or no input route).
  static bool IsSupported();
  static Permission GetPermission();
  /// Shows the system prompt when undetermined; `completion` runs on an arbitrary queue.
  static void RequestPermission(std::function<void(bool granted)> completion);

  struct Impl;

private:
  std::shared_ptr<Impl> m_impl;
};

#endif  // IPHONEOS
