// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#ifdef IPHONEOS

#include "AudioCommon/SoundStream.h"
#include "AudioCommon/SurroundDecoder.h"

#include <atomic>
#include <memory>
#include <thread>
#include <vector>

#ifdef __OBJC__
@class AVAudioEngine;
@class AVAudioEnvironmentNode;
@class AVAudioPlayerNode;
@class AVAudioFormat;
@class AVAudioPCMBuffer;
@class CMMotionManager;
#else
typedef void AVAudioEngine;
typedef void AVAudioEnvironmentNode;
typedef void AVAudioPlayerNode;
typedef void AVAudioFormat;
typedef void AVAudioPCMBuffer;
typedef void CMMotionManager;
#endif

/// SoundStream backend using AVAudioEngine + AVAudioEnvironmentNode to provide headphone spatial audio
class AVAudioEngineSound final : public SoundStream
{
public:
  bool Init() override;
  bool SetRunning(bool running) override;
  void SetVolume(int volume) override;
  static bool IsValid() { return true; }

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

  std::atomic<bool> m_running{false};
  std::thread m_audio_thread;

  int m_volume_percent = 100;
  const uint32_t kSampleRate = 48000;
  const uint32_t kChunkFrames = 256;
};

#endif // IPHONEOS
