// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#ifdef IPHONEOS

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "AudioCommon/AudioDSPChain.h"
#include "AudioCommon/SoundStream.h"
#include "AudioCommon/SurroundDecoder.h"
#include "Common/Config/Config.h"

#ifdef __OBJC__
@class AVAudioEngine;
@class AVAudioEnvironmentNode;
@class AVAudioPlayerNode;
@class AVAudioFormat;
@class AVAudioPCMBuffer;
@class AVAudioUnit;
@class CMHeadphoneMotionManager;
@class NSMutableArray;
#else
typedef void AVAudioEngine;
typedef void AVAudioEnvironmentNode;
typedef void AVAudioPlayerNode;
typedef void AVAudioFormat;
typedef void AVAudioPCMBuffer;
typedef void AVAudioUnit;
typedef void CMHeadphoneMotionManager;
typedef void NSMutableArray;
#endif

/// AVAudioEngine output. Picks one of three graphs from the live route:
///  - Discrete 5.1: surround on and the route carries six channels (HDMI, multichannel adapter).
///  - Spatial: surround on, spatial on, headphones or Bluetooth: six mono sources placed around an
///    AVAudioEnvironmentNode, rendered binaurally, optionally head tracked.
///  - Stereo: everything else.
/// Audio Unit effects (AUv3, iOS) sit between the sources and the main mixer and persist in
/// Config; the shared AudioDSPChain runs on the feeder thread before scheduling.
class AVAudioEngineSound final : public SoundStream
{
public:
  enum class Mode
  {
    Stereo,
    Spatial,
    Discrete51,
  };

  AVAudioEngineSound();
  ~AVAudioEngineSound() override;

  bool Init() override;
  bool SetRunning(bool running) override;
  void SetVolume(int volume) override;
  static bool IsValid() { return true; }
  static AVAudioEngineSound* Active();

  Mode GetMode() const { return m_mode.load(); }
  AudioCommon::AudioDSPChain& GetDSPChain() { return m_dsp; }

  // Audio Unit plug-in chain. Main thread. `identifier` is "type:%u sub:%u manu:%u" or a name.
  bool addEffectWithIdentifier(const char* identifier);
  void removeEffectAt(size_t index);
  void moveEffect(size_t from, size_t to);
  void setEffectBypass(size_t index, bool bypassed);
  size_t fxCount() const;
  AVAudioUnit* fxAt(size_t i) const;
  /// Writes the chain (components, bypass flags and each unit's full state) to Config. Call after
  /// a plug-in's own view has been dismissed so parameter edits survive a rebuild.
  void saveEffectChain();

private:
  struct Guard
  {
    std::mutex mutex;
    bool alive = true;
  };

  void audioThreadMain();
  void startFeeder();
  void stopFeeder();

  Mode chooseMode() const;
  bool buildGraphLocked();
  void teardownGraphLocked();
  bool startEngineLocked();
  void rebuildLocked();
  bool modeChangedLocked() const { return chooseMode() != m_intended_mode.load(); }
  void reconnectGraphLocked();
  /// Persists the live chain (including parameter edits) to Config without taking the lock again.
  void saveEffectChainLocked();
  void applyHeadTrackingLocked();
  void stopHeadTrackingLocked();

  bool instantiateEffect(const std::string& identifier, AVAudioUnit** out_unit);
  std::string serializeEffectChainLocked() const;
  void restoreEffectChainLocked();

  void registerObservers();
  void unregisterObservers();
  void refreshFromConfig();

  std::shared_ptr<Guard> m_guard = std::make_shared<Guard>();
  AVAudioEngine* m_engine = nullptr;
  AVAudioEnvironmentNode* m_environment = nullptr;
  NSMutableArray* m_players = nullptr;        // AVAudioPlayerNode, 1 or 6
  NSMutableArray* m_buffer_pools = nullptr;   // one NSMutableArray<AVAudioPCMBuffer*> per player
  AVAudioFormat* m_player_format = nullptr;
  AVAudioFormat* m_chain_format = nullptr;
  CMHeadphoneMotionManager* m_headphone_motion = nullptr;
  std::vector<AVAudioUnit*> m_fx_units;

  std::atomic<Mode> m_mode{Mode::Stereo};
  /// chooseMode()'s answer when the graph was built. Compared against a fresh chooseMode() so a
  /// 5.1 request the route turned down (built as stereo) does not rebuild on every notification.
  std::atomic<Mode> m_intended_mode{Mode::Stereo};
  int m_output_channels = 2;
  bool m_surround_decoding = false;
  std::unique_ptr<AudioCommon::SurroundDecoder> m_surround;
  std::vector<short> m_stereo_temp;
  std::vector<float> m_float_temp;
  AudioCommon::AudioDSPChain m_dsp;

  std::atomic<bool> m_feeder_running{false};
  std::atomic<bool> m_should_run{false};
  std::thread m_audio_thread;

  int m_volume_percent = 100;

#ifdef __OBJC__
  id m_route_token = nil;
  id m_interrupt_token = nil;
  id m_config_change_token = nil;
  id m_reset_token = nil;
#else
  void* m_route_token = nullptr;
  void* m_interrupt_token = nullptr;
  void* m_config_change_token = nullptr;
  void* m_reset_token = nullptr;
#endif
  Config::ConfigChangedCallbackID m_config_callback;
  bool m_has_config_callback = false;

  static AVAudioEngineSound* s_active;
};

#endif  // IPHONEOS
