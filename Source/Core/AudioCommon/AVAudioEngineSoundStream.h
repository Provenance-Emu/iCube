// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#ifdef IPHONEOS

#include "AudioCommon/SoundStream.h"
#include "AudioCommon/SurroundDecoder.h"

#include <atomic>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#ifdef __OBJC__
@class AVAudioEngine;
@class AVAudioEnvironmentNode;
@class AVAudioPlayerNode;
@class AVAudioFormat;
@class AVAudioPCMBuffer;
@class CMMotionManager;
@class AVAudioUnitEffect;
#else
typedef void AVAudioEngine;
typedef void AVAudioEnvironmentNode;
typedef void AVAudioPlayerNode;
typedef void AVAudioFormat;
typedef void AVAudioPCMBuffer;
typedef void CMMotionManager;
typedef void AVAudioUnitEffect;
#endif

/// SoundStream backend using AVAudioEngine + AVAudioEnvironmentNode to provide headphone spatial audio
class AVAudioEngineSound final : public SoundStream
{
public:
  bool Init() override;
  bool SetRunning(bool running) override;
  void SetVolume(int volume) override;
  static bool IsValid() { return true; }
  static AVAudioEngineSound* Active();
  // FX chain management (public for bridging)
  bool addEffectWithIdentifier(const char* identifier);
  void removeEffectAt(size_t index);
  void moveEffect(size_t from, size_t to);
  void setEffectBypass(size_t index, bool bypassed);
  void reconnectGraph();
  void requestEffectUI(size_t index);
  size_t fxCount() const { return m_fx_units.size(); }
  AVAudioUnitEffect* fxAt(size_t i) const { return (i < m_fx_units.size()) ? m_fx_units[i] : nullptr; }

private:
  void audioThreadMain();
  void stopThread();
  void teardownEngine();
  bool buildAndStartEngine();
  void registerAudioSessionObservers();
  void unregisterAudioSessionObservers();
  void startHeadTracking();
  void stopHeadTracking();

  AVAudioEngine* m_engine = nullptr;
  AVAudioEnvironmentNode* m_environment = nullptr;
  AVAudioPlayerNode* m_nodes[6] = {0,0,0,0,0,0};
  AVAudioFormat* m_monoFloatFormat = nullptr;
  CMMotionManager* m_motion = nullptr;
#ifdef __OBJC__
  id m_routeToken = nil;
  id m_interruptToken = nil;
#else
  void* m_routeToken = nullptr;
  void* m_interruptToken = nullptr;
#endif

  std::unique_ptr<AudioCommon::SurroundDecoder> m_surround;
  std::vector<short> m_stereo_temp;
  std::vector<float> m_surround_temp;
  std::vector<AVAudioUnitEffect*> m_fx_units;

  std::atomic<bool> m_running{false};
  std::thread m_audio_thread;
  // Serializes engine/node graph teardown+rebuild (route/interruption handlers,
  // main queue) against the audio thread that schedules buffers on those nodes.
  std::mutex m_engine_mutex;

  int m_volume_percent = 100;
  const uint32_t kSampleRate = 48000;
  std::atomic<uint32_t> m_chunkFrames{256};
  static AVAudioEngineSound* s_active;
};

#endif // IPHONEOS
