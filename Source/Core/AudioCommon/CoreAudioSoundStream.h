// Copyright 2008 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#ifdef IPHONEOS
#include <AudioUnit/AudioUnit.h>

#include <atomic>
#include <memory>
#include <mutex>

#include "AudioCommon/AudioDSPChain.h"
#include "Common/Config/Config.h"
#endif

#include "AudioCommon/SoundStream.h"

/// RemoteIO output. Stereo 16-bit by default; 5.1 float when surround decoding is on and the route
/// (HDMI, a multichannel adapter) can carry six channels. Runs the shared AudioDSPChain and a
/// software master volume in the render callback, and survives interruptions, route changes and a
/// media-services reset.
class CoreAudioSound final : public SoundStream
{
#ifdef IPHONEOS
public:
  CoreAudioSound();
  ~CoreAudioSound() override;

  bool Init() override;
  bool SetRunning(bool running) override;
  void SetVolume(int volume) override;

  static bool IsValid() { return true; }

  AudioCommon::AudioDSPChain& GetDSPChain() { return m_dsp; }
  /// True while the unit renders six discrete channels.
  bool IsSurroundOutput() const { return m_surround.load(); }

private:
  static OSStatus RenderCallback(void* ref_con, AudioUnitRenderActionFlags* action_flags,
                                 const AudioTimeStamp* timestamp, UInt32 bus_number,
                                 UInt32 number_frames, AudioBufferList* io_data);
  OSStatus Render(UInt32 number_frames, AudioBufferList* io_data);

  bool OpenUnitLocked();
  void CloseUnitLocked();
  bool StartUnitLocked();
  void StopUnitLocked();
  /// Close and reopen the unit for the current route and settings. Caller holds m_guard->mutex.
  void RebuildLocked();
  bool WantsSurround() const;
  /// Surround that the current settings and route call for (what a build would try).
  bool SurroundIntended() const;
  void RegisterObservers();
  void UnregisterObservers();
  void RefreshFromConfig();

  /// Serializes the unit against the session observers' main-queue blocks. Shared with those
  /// blocks so a block that fires after the stream is destroyed finds `alive` false.
  struct Guard
  {
    std::mutex mutex;
    bool alive = true;
  };
  std::shared_ptr<Guard> m_guard = std::make_shared<Guard>();
  AudioUnit m_unit = nullptr;
  std::atomic<bool> m_should_run{false};
  std::atomic<bool> m_unit_running{false};
  std::atomic<bool> m_surround{false};
  /// What the last build tried for; compared against SurroundIntended() so a 5.1 request the
  /// route turned down does not trigger a rebuild on every notification.
  std::atomic<bool> m_surround_intended{false};
  u32 m_channels = 2;
  int m_volume = 100;

  AudioCommon::AudioDSPChain m_dsp;

  // ARC-managed in CoreAudioSoundStream.mm; opaque elsewhere.
#ifdef __OBJC__
  id m_route_token = nil;
  id m_interrupt_token = nil;
  id m_reset_token = nil;
#else
  void* m_route_token = nullptr;
  void* m_interrupt_token = nullptr;
  void* m_reset_token = nullptr;
#endif
  Config::ConfigChangedCallbackID m_config_callback;
  bool m_has_config_callback = false;
#endif
};
