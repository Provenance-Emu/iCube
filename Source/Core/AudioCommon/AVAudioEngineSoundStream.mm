// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#ifdef IPHONEOS

#import <AVFoundation/AVFoundation.h>
#import <CoreMotion/CoreMotion.h>

#include "AudioCommon/AVAudioEngineSoundStream.h"
#include "Common/Logging/Log.h"

static const AVAudio3DPoint kSpeakerPositions[6] = {
  { -1.0f, 0.0f, 1.0f },  // FL
  {  1.0f, 0.0f, 1.0f },  // FR
  {  0.0f, 0.0f, 1.5f },  // FC (slightly forward)
  {  0.0f, 0.0f, 0.5f },  // LFE (co-located with center)
  { -1.0f, 0.0f,-1.0f },  // BL
  {  1.0f, 0.0f,-1.0f },  // BR
};

bool AVAudioEngineSound::buildAndStartEngine()
{
  m_engine = [[AVAudioEngine alloc] init];
  m_environment = [[AVAudioEnvironmentNode alloc] init];
  m_environment.renderingAlgorithm = AVAudio3DMixingRenderingAlgorithmHRTF;
  m_environment.distanceAttenuationParameters.distanceAttenuationModel = AVAudioEnvironmentDistanceAttenuationModelLinear;
  [m_engine attachNode:m_environment];

  AVAudioFormat* outFmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kSampleRate channels:2];
  [m_engine connect:m_environment to:m_engine.mainMixerNode format:outFmt];

  AVAudioFormat* monoFmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kSampleRate channels:1];
  m_monoFloatFormat = monoFmt;
  for (int i = 0; i < 6; ++i)
  {
    AVAudioPlayerNode* node = [[AVAudioPlayerNode alloc] init];
    m_nodes[i] = node;
    [m_engine attachNode:node];
    [m_engine connect:node to:m_environment format:monoFmt];
    node.volume = 1.0f;
    node.position = kSpeakerPositions[i];
  }

  NSError* err = nil;
  if (![m_engine startAndReturnError:&err])
  {
    ERROR_LOG_FMT(AUDIO, "AVAudioEngine start error: {}", err.localizedDescription.UTF8String);
    return false;
  }
  return true;
}

void AVAudioEngineSound::teardownEngine()
{
  @autoreleasepool {
    for (int i = 0; i < 6; ++i)
    {
      if (m_nodes[i]) { [m_nodes[i] stop]; m_nodes[i] = nil; }
    }
    if (m_engine) { [m_engine stop]; }
    m_environment = nil;
    m_engine = nil;
  }
}

void AVAudioEngineSound::registerAudioSessionObservers()
{
  AVAudioSession* session = [AVAudioSession sharedInstance];
  __weak typeof(self) weakSelf = this;
  m_routeToken = [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification object:session queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification* note){
    (void)note;
    typeof(self) strongSelf = weakSelf;
    if (!strongSelf) return;
    strongSelf->teardownEngine();
    strongSelf->buildAndStartEngine();
  }];
  m_interruptToken = [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionInterruptionNotification object:session queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification* note){
    NSNumber* typeNum = note.userInfo[AVAudioSessionInterruptionTypeKey];
    AVAudioSessionInterruptionType type = (AVAudioSessionInterruptionType)typeNum.unsignedIntegerValue;
    if (type == AVAudioSessionInterruptionTypeEnded) {
      typeof(self) strongSelf = weakSelf;
      if (!strongSelf) return;
      strongSelf->teardownEngine();
      strongSelf->buildAndStartEngine();
    }
  }];
}

void AVAudioEngineSound::unregisterAudioSessionObservers()
{
  if (m_routeToken) [[NSNotificationCenter defaultCenter] removeObserver:m_routeToken];
  if (m_interruptToken) [[NSNotificationCenter defaultCenter] removeObserver:m_interruptToken];
  m_routeToken = nil;
  m_interruptToken = nil;
}

void AVAudioEngineSound::startHeadTracking()
{
  if (m_motion) return;
  m_motion = [[CMMotionManager alloc] init];
  if (!m_motion.isDeviceMotionAvailable) return;
  m_motion.deviceMotionUpdateInterval = 1.0 / 60.0;
  __weak typeof(self) weakSelf = this;
  [m_motion startDeviceMotionUpdatesToQueue:[NSOperationQueue mainQueue] withHandler:^(CMDeviceMotion* motion, NSError* error){
    (void)error;
    typeof(self) strongSelf = weakSelf;
    if (!strongSelf || !motion) return;
    // Map yaw/pitch/roll to environment listener angles (in radians)
    CMAttitude* a = motion.attitude;
    strongSelf->m_environment.listenerAngularOrientation = (AVAudio3DAngularOrientation){ (float)a.yaw, (float)a.pitch, (float)a.roll };
  }];
}

void AVAudioEngineSound::stopHeadTracking()
{
  if (m_motion) { [m_motion stopDeviceMotionUpdates]; m_motion = nil; }
}

bool AVAudioEngineSound::Init()
{
  @autoreleasepool {
    m_surround = std::make_unique<AudioCommon::SurroundDecoder>(kSampleRate, kChunkFrames);

    if (!buildAndStartEngine()) return false;
    registerAudioSessionObservers();
    startHeadTracking();

    m_running.store(true);
    m_audio_thread = std::thread(&AVAudioEngineSound::audioThreadMain, this);
    return true;
  }
}

bool AVAudioEngineSound::SetRunning(bool running)
{
  if (running == m_running.load())
    return true;

  if (running)
  {
    m_running.store(true);
    if (!m_audio_thread.joinable())
      m_audio_thread = std::thread(&AVAudioEngineSound::audioThreadMain, this);
  }
  else
  {
    stopThread();
    stopHeadTracking();
    unregisterAudioSessionObservers();
    teardownEngine();
  }
  return true;
}

void AVAudioEngineSound::stopThread()
{
  m_running.store(false);
  if (m_audio_thread.joinable())
    m_audio_thread.join();
}

void AVAudioEngineSound::SetVolume(int volume)
{
  m_volume_percent = volume;
  const float scalar = std::max(0, std::min(100, volume)) / 100.0f;
  for (int i = 0; i < 6; ++i)
  {
    [m_nodes[i] setVolume:scalar];
  }
}

void AVAudioEngineSound::audioThreadMain()
{
  @autoreleasepool {
    // Pre-warm: enqueue two buffers before starting playback
    const int warmBuffers = 2;
    for (int warm = 0; warm < warmBuffers; ++warm)
    {
      const size_t neededStereo = m_surround->QueryFramesNeededForSurroundOutput(kChunkFrames);
      if (neededStereo > 0)
      {
        m_stereo_temp.resize(neededStereo * 2);
        m_mixer->Mix(m_stereo_temp.data(), static_cast<u32>(neededStereo));
        m_surround->PutFrames(m_stereo_temp.data(), neededStereo);
      }
      m_surround_temp.resize(static_cast<size_t>(kChunkFrames) * 6);
      m_surround->ReceiveFrames(m_surround_temp.data(), kChunkFrames);
      for (int ch = 0; ch < 6; ++ch)
      {
        AVAudioPCMBuffer* buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:m_monoFloatFormat frameCapacity:kChunkFrames];
        buf.frameLength = kChunkFrames;
        float* dst = buf.floatChannelData[0];
        const float* src = m_surround_temp.data() + ch;
        for (uint32_t f = 0; f < kChunkFrames; ++f)
          dst[f] = src[f * 6];
        [m_nodes[ch] scheduleBuffer:buf completionHandler:nil];
      }
    }
    for (int i = 0; i < 6; ++i) [m_nodes[i] play];

    while (m_running.load())
    {
      // Ask decoder how many stereo frames we need to produce kChunkFrames surround frames
      const size_t neededStereo = m_surround->QueryFramesNeededForSurroundOutput(kChunkFrames);
      if (neededStereo > 0)
      {
        m_stereo_temp.resize(neededStereo * 2);
        m_mixer->Mix(m_stereo_temp.data(), static_cast<u32>(neededStereo));
        m_surround->PutFrames(m_stereo_temp.data(), neededStereo);
      }

      // Pull 6-channel float frames (interleaved)
      m_surround_temp.resize(static_cast<size_t>(kChunkFrames) * 6);
      m_surround->ReceiveFrames(m_surround_temp.data(), kChunkFrames);

      // Schedule per-channel mono buffers
      for (int ch = 0; ch < 6; ++ch)
      {
        AVAudioPCMBuffer* buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:m_monoFloatFormat frameCapacity:kChunkFrames];
        buf.frameLength = kChunkFrames;
        float* dst = buf.floatChannelData[0];
        const float* src = m_surround_temp.data() + ch;
        for (uint32_t f = 0; f < kChunkFrames; ++f)
          dst[f] = src[f * 6];
        [m_nodes[ch] scheduleBuffer:buf completionHandler:nil];
      }

      // Aim to keep a small lead; sleep a fraction of chunk duration
      const uint32_t chunkMicros = static_cast<uint32_t>((1000000ULL * kChunkFrames) / kSampleRate);
      std::this_thread::sleep_for(std::chrono::microseconds(chunkMicros / 3));
    }

    for (int i = 0; i < 6; ++i)
      [m_nodes[i] stop];
  }
}

#endif // IPHONEOS
