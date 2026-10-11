// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#ifdef IPHONEOS

#import <AVFoundation/AVFoundation.h>
#if TARGET_OS_IOS && __has_include(<CoreMotion/CoreMotion.h>)
#import <CoreMotion/CoreMotion.h>
#define DOL_HAS_HEADPHONE_MOTION 1
#else
#define DOL_HAS_HEADPHONE_MOTION 0
#endif

#include "AudioCommon/AVAudioEngineSoundStream.h"

#include <pthread.h>

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <sstream>

#include "AudioCommon/Enums.h"
#include "AudioCommon/IOSAudioSession.h"
#include "AudioCommon/Mixer.h"
#include "Common/Logging/Log.h"
#include "Common/StringUtil.h"
#include "Common/Thread.h"
#include "Core/Config/MainSettings.h"
#include "Core/Config/iOSSettings.h"

AVAudioEngineSound* AVAudioEngineSound::s_active = nullptr;

namespace
{
constexpr int kSurroundChannels = 6;
/// Frames per scheduled buffer (10.7 ms at 48 kHz).
constexpr uint32_t kChunkFrames = 512;
/// Buffer groups kept scheduled ahead of the player.
constexpr int kTargetGroups = 3;
/// Reusable buffers per player. A buffer is reused only after its group's completion fired, so this
/// just needs to exceed kTargetGroups by a margin.
constexpr int kPoolSize = 8;
constexpr double kInstantiateTimeoutSeconds = 5.0;

// Mixer::MixSurround order: FL FR FC LFE BL BR.
const AVAudio3DPoint kSpeakerPositions[kSurroundChannels] = {
    {-1.0f, 0.0f, 1.0f},  // FL
    {1.0f, 0.0f, 1.0f},   // FR
    {0.0f, 0.0f, 1.5f},   // FC
    {0.0f, 0.0f, 0.5f},   // LFE (centre, close)
    {-1.0f, 0.0f, -1.0f}, // BL
    {1.0f, 0.0f, -1.0f},  // BR
};

// Mirrors the mapping Mixer.cpp uses for its own decoder.
u32 FrameBlockSizeForQuality(AudioCommon::DPL2Quality quality)
{
  switch (quality)
  {
  case AudioCommon::DPL2Quality::Lowest:
    return 512;
  case AudioCommon::DPL2Quality::Low:
    return 1024;
  case AudioCommon::DPL2Quality::Highest:
    return 4096;
  default:
    return 2048;
  }
}

const char* ModeName(AVAudioEngineSound::Mode mode)
{
  switch (mode)
  {
  case AVAudioEngineSound::Mode::Stereo:
    return "stereo";
  case AVAudioEngineSound::Mode::Spatial:
    return "spatial";
  case AVAudioEngineSound::Mode::Discrete51:
    return "discrete 5.1";
  }
  return "?";
}

AVAudioFormat* FiveOneFormat(double sample_rate)
{
  AVAudioChannelLayout* layout =
      [[AVAudioChannelLayout alloc] initWithLayoutTag:kAudioChannelLayoutTag_MPEG_5_1_A];
  return [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                          sampleRate:sample_rate
                                         interleaved:NO
                                       channelLayout:layout];
}

NSString* Base64(NSData* data)
{
  return [data base64EncodedStringWithOptions:0];
}
}  // namespace

AVAudioEngineSound* AVAudioEngineSound::Active()
{
  return s_active;
}

AVAudioEngineSound::AVAudioEngineSound()
{
  m_players = [NSMutableArray array];
  m_buffer_pools = [NSMutableArray array];
}

AVAudioEngineSound::~AVAudioEngineSound()
{
  stopFeeder();
  unregisterObservers();
  if (m_has_config_callback)
    Config::RemoveConfigChangedCallback(m_config_callback);
  std::lock_guard lock(m_guard->mutex);
  m_guard->alive = false;
  teardownGraphLocked();
}

// MARK: - Mode and graph

AVAudioEngineSound::Mode AVAudioEngineSound::chooseMode() const
{
  if (!Config::Get(Config::MAIN_DPL2_DECODER))
    return Mode::Stereo;
  const auto route = AudioCommon::IOSAudioSession::QueryRoute();
  if (route.max_output_channels >= kSurroundChannels)
    return Mode::Discrete51;
  if (route.headphones && Config::Get(Config::MAIN_AUDIO_SPATIAL))
    return Mode::Spatial;
  return Mode::Stereo;
}

bool AVAudioEngineSound::buildGraphLocked()
{
  teardownGraphLocked();

  // AVAudioEngine is pickier than RemoteIO about an active session. The app owns the category
  // (playback, or play-and-record while a microphone is open); only activation is asserted here.
  {
    NSError* err = nil;
    if (![[AVAudioSession sharedInstance] setActive:YES error:&err] && err)
      WARN_LOG_FMT(AUDIO, "AVAudioEngine: setActive failed: {}", err.localizedDescription.UTF8String);
  }

  const double sample_rate = static_cast<double>(m_mixer->GetSampleRate());
  Mode mode = chooseMode();
  m_surround_decoding = mode != Mode::Stereo;
  if (mode == Mode::Discrete51)
  {
    const int granted = AudioCommon::IOSAudioSession::RequestOutputChannels(kSurroundChannels);
    if (granted < kSurroundChannels)
      mode = AudioCommon::IOSAudioSession::QueryRoute().headphones &&
                     Config::Get(Config::MAIN_AUDIO_SPATIAL) ?
                 Mode::Spatial :
                 Mode::Stereo;
  }
  if (mode != Mode::Discrete51 && AudioCommon::IOSAudioSession::QueryRoute().output_channels > 2)
    AudioCommon::IOSAudioSession::RequestOutputChannels(2);
  AudioCommon::IOSAudioSession::SetSupportsMultichannelContent(m_surround_decoding);

  m_output_channels = mode == Mode::Discrete51 ? kSurroundChannels : 2;
  m_engine = [[AVAudioEngine alloc] init];

  // The format the effect chain and main mixer carry.
  m_chain_format = mode == Mode::Discrete51 ?
                       FiveOneFormat(sample_rate) :
                       [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sample_rate channels:2];
  [m_engine connect:m_engine.mainMixerNode to:m_engine.outputNode format:m_chain_format];

  const int player_count = mode == Mode::Spatial ? kSurroundChannels : 1;
  switch (mode)
  {
  case Mode::Stereo:
    m_player_format = m_chain_format;
    break;
  case Mode::Discrete51:
    m_player_format = m_chain_format;
    break;
  case Mode::Spatial:
    m_player_format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sample_rate channels:1];
    m_environment = [[AVAudioEnvironmentNode alloc] init];
    m_environment.distanceAttenuationParameters.distanceAttenuationModel =
        AVAudioEnvironmentDistanceAttenuationModelLinear;
    m_environment.outputType = AVAudioEnvironmentOutputTypeAuto;
    [m_engine attachNode:m_environment];
    break;
  }

  // The best binaural algorithm this device offers for mono sources.
  AVAudio3DMixingRenderingAlgorithm algorithm = AVAudio3DMixingRenderingAlgorithmEqualPowerPanning;
  if (mode == Mode::Spatial)
  {
    NSArray<NSNumber*>* applicable = m_environment.applicableRenderingAlgorithms;
    for (AVAudio3DMixingRenderingAlgorithm candidate :
         {AVAudio3DMixingRenderingAlgorithmHRTFHQ, AVAudio3DMixingRenderingAlgorithmHRTF,
          AVAudio3DMixingRenderingAlgorithmSphericalHead})
    {
      if ([applicable containsObject:@(candidate)])
      {
        algorithm = candidate;
        break;
      }
    }
  }

  for (int i = 0; i < player_count; ++i)
  {
    AVAudioPlayerNode* node = [[AVAudioPlayerNode alloc] init];
    [m_engine attachNode:node];
    if (mode == Mode::Spatial)
    {
      [m_engine connect:node to:m_environment format:m_player_format];
      node.position = kSpeakerPositions[i];
      // renderingAlgorithm is a per-source property: it must be set on the player nodes.
      node.renderingAlgorithm = algorithm;
    }
    node.volume = 1.0f;
    [m_players addObject:node];

    NSMutableArray<AVAudioPCMBuffer*>* pool = [NSMutableArray arrayWithCapacity:kPoolSize];
    for (int b = 0; b < kPoolSize; ++b)
    {
      AVAudioPCMBuffer* buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:m_player_format
                                                             frameCapacity:kChunkFrames];
      [pool addObject:buf];
    }
    [m_buffer_pools addObject:pool];
  }

  m_surround = std::make_unique<AudioCommon::SurroundDecoder>(
      m_mixer->GetSampleRate(), FrameBlockSizeForQuality(Config::Get(Config::MAIN_DPL2_QUALITY)));
  m_dsp.Configure(m_mixer->GetSampleRate(), mode == Mode::Stereo ? 2 : kSurroundChannels);
  m_mode.store(mode);

  restoreEffectChainLocked();
  reconnectGraphLocked();
  m_engine.mainMixerNode.outputVolume = m_volume_percent / 100.0f;
  applyHeadTrackingLocked();

  const auto route = AudioCommon::IOSAudioSession::QueryRoute();
  INFO_LOG_FMT(AUDIO, "AVAudioEngine: {} graph, {} output channels, {} effects, route {}",
               ModeName(mode), m_output_channels, m_fx_units.size(), route.description);

  if (!startEngineLocked())
    return false;
  s_active = this;
  return true;
}

bool AVAudioEngineSound::startEngineLocked()
{
  if (!m_engine)
    return false;
  if (!m_engine.running)
  {
    NSError* err = nil;
    if (![m_engine startAndReturnError:&err])
    {
      ERROR_LOG_FMT(AUDIO, "AVAudioEngine start error: {}",
                    err ? err.localizedDescription.UTF8String : "unknown");
      if (!m_fx_units.empty())
      {
        // A plug-in that rejects this format keeps the whole engine from starting. Drop the chain
        // rather than go silent; the user's chain is still in Config for the next route.
        WARN_LOG_FMT(AUDIO, "AVAudioEngine: retrying without the {} Audio Unit effects",
                     m_fx_units.size());
        for (AVAudioUnit* unit : m_fx_units)
          [m_engine detachNode:unit];
        m_fx_units.clear();
        reconnectGraphLocked();
        err = nil;
        if (![m_engine startAndReturnError:&err])
          return false;
      }
      else
      {
        return false;
      }
    }
  }
  // A freshly attached or paused player produces nothing until it is told to play; this covers
  // the first build, every rebuild and every resume.
  for (AVAudioPlayerNode* node in m_players)
    [node play];
  return true;
}

void AVAudioEngineSound::teardownGraphLocked()
{
  @autoreleasepool
  {
    stopHeadTrackingLocked();
    for (AVAudioPlayerNode* node in m_players)
      [node stop];
    if (m_engine)
      [m_engine stop];
    [m_players removeAllObjects];
    [m_buffer_pools removeAllObjects];
    m_fx_units.clear();
    m_environment = nil;
    m_player_format = nil;
    m_chain_format = nil;
    m_engine = nil;
    if (s_active == this)
      s_active = nullptr;
  }
}

void AVAudioEngineSound::rebuildLocked()
{
  if (!buildGraphLocked())
    ERROR_LOG_FMT(AUDIO, "AVAudioEngine: rebuild failed; output is silent until the next change");
}

void AVAudioEngineSound::reconnectGraphLocked()
{
  if (!m_engine)
    return;
  // source(s) -> fx0 -> fx1 -> ... -> main mixer
  AVAudioNode* head = m_environment ? (AVAudioNode*)m_environment : m_players.firstObject;
  if (!head)
    return;
  [m_engine disconnectNodeOutput:head];
  for (AVAudioUnit* unit : m_fx_units)
    [m_engine disconnectNodeOutput:unit];
  AVAudioNode* tail = head;
  for (AVAudioUnit* unit : m_fx_units)
  {
    [m_engine connect:tail to:unit format:m_chain_format];
    tail = unit;
  }
  [m_engine connect:tail to:m_engine.mainMixerNode format:m_chain_format];
}

// MARK: - Head tracking

void AVAudioEngineSound::applyHeadTrackingLocked()
{
  if (!m_environment)
    return;
  const bool wanted = Config::Get(Config::MAIN_AUDIO_SPATIAL_HEAD_TRACKING);
  if (@available(iOS 18.0, tvOS 18.0, *))
  {
    m_environment.listenerHeadTrackingEnabled = wanted;
    return;
  }
#if DOL_HAS_HEADPHONE_MOTION
  if (!wanted)
  {
    stopHeadTrackingLocked();
    return;
  }
  if (m_headphone_motion)
    return;
  CMHeadphoneMotionManager* motion = [[CMHeadphoneMotionManager alloc] init];
  if (!motion.isDeviceMotionAvailable)
    return;
  m_headphone_motion = motion;
  std::shared_ptr<Guard> guard = m_guard;
  AVAudioEngineSound* self_ptr = this;
  [motion startDeviceMotionUpdatesToQueue:[NSOperationQueue mainQueue]
                              withHandler:^(CMDeviceMotion* dm, NSError* error) {
                                (void)error;
                                if (!dm)
                                  return;
                                std::lock_guard lock(guard->mutex);
                                if (!guard->alive || !self_ptr->m_environment)
                                  return;
                                CMAttitude* a = dm.attitude;
                                constexpr double kDeg = 180.0 / M_PI;
                                self_ptr->m_environment.listenerAngularOrientation =
                                    (AVAudio3DAngularOrientation){(float)(a.yaw * kDeg),
                                                                  (float)(a.pitch * kDeg),
                                                                  (float)(a.roll * kDeg)};
                              }];
#endif
}

void AVAudioEngineSound::stopHeadTrackingLocked()
{
#if DOL_HAS_HEADPHONE_MOTION
  if (m_headphone_motion)
  {
    [m_headphone_motion stopDeviceMotionUpdates];
    m_headphone_motion = nil;
  }
  if (m_environment)
    m_environment.listenerAngularOrientation = (AVAudio3DAngularOrientation){0, 0, 0};
#endif
}

// MARK: - Observers

void AVAudioEngineSound::registerObservers()
{
  AVAudioSession* session = [AVAudioSession sharedInstance];
  NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
  std::shared_ptr<Guard> guard = m_guard;
  AVAudioEngineSound* self_ptr = this;

  // Route changes: the engine reconfigures itself for the new hardware, but the *graph* only
  // follows when the mode changes (headphones in: stereo -> spatial).
  m_route_token = [center addObserverForName:AVAudioSessionRouteChangeNotification
                                      object:session
                                       queue:[NSOperationQueue mainQueue]
                                  usingBlock:^(NSNotification* note) {
                                    (void)note;
                                    std::lock_guard lock(guard->mutex);
                                    if (!guard->alive || !self_ptr->m_engine)
                                      return;
                                    if (self_ptr->chooseMode() != self_ptr->m_mode.load())
                                      self_ptr->rebuildLocked();
                                  }];

  // The engine stopped itself because the output format changed; start it again in place.
  m_config_change_token = [center
      addObserverForName:AVAudioEngineConfigurationChangeNotification
                  object:nil
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(NSNotification* note) {
                std::lock_guard lock(guard->mutex);
                if (!guard->alive || !self_ptr->m_engine || note.object != self_ptr->m_engine)
                  return;
                INFO_LOG_FMT(AUDIO, "AVAudioEngine: configuration change");
                if (self_ptr->chooseMode() != self_ptr->m_mode.load())
                  self_ptr->rebuildLocked();
                else if (self_ptr->m_should_run.load())
                  self_ptr->startEngineLocked();
              }];

  m_interrupt_token = [center
      addObserverForName:AVAudioSessionInterruptionNotification
                  object:session
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(NSNotification* note) {
                const auto type = (AVAudioSessionInterruptionType)
                    [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
                std::lock_guard lock(guard->mutex);
                if (!guard->alive || !self_ptr->m_engine)
                  return;
                if (type == AVAudioSessionInterruptionTypeBegan)
                {
                  INFO_LOG_FMT(AUDIO, "AVAudioEngine: interruption began");
                  [self_ptr->m_engine pause];
                  return;
                }
                INFO_LOG_FMT(AUDIO, "AVAudioEngine: interruption ended");
                [session setActive:YES error:nil];
                if (self_ptr->m_should_run.load())
                  self_ptr->startEngineLocked();
              }];

  m_reset_token = [center addObserverForName:AVAudioSessionMediaServicesWereResetNotification
                                      object:session
                                       queue:[NSOperationQueue mainQueue]
                                  usingBlock:^(NSNotification* note) {
                                    (void)note;
                                    std::lock_guard lock(guard->mutex);
                                    if (!guard->alive)
                                      return;
                                    WARN_LOG_FMT(AUDIO, "AVAudioEngine: media services reset");
                                    [session setActive:YES error:nil];
                                    self_ptr->rebuildLocked();
                                  }];
}

void AVAudioEngineSound::unregisterObservers()
{
  NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
  for (id token : {m_route_token, m_interrupt_token, m_config_change_token, m_reset_token})
  {
    if (token)
      [center removeObserver:token];
  }
  m_route_token = nil;
  m_interrupt_token = nil;
  m_config_change_token = nil;
  m_reset_token = nil;
}

void AVAudioEngineSound::refreshFromConfig()
{
  m_dsp.LoadFromConfig();
  std::shared_ptr<Guard> guard = m_guard;
  AVAudioEngineSound* self_ptr = this;
  dispatch_async(dispatch_get_main_queue(), ^{
    std::lock_guard lock(guard->mutex);
    if (!guard->alive || !self_ptr->m_engine)
      return;
    if (self_ptr->chooseMode() != self_ptr->m_mode.load())
      self_ptr->rebuildLocked();
    else
      self_ptr->applyHeadTrackingLocked();
  });
}

// MARK: - SoundStream

bool AVAudioEngineSound::Init()
{
  @autoreleasepool
  {
    m_dsp.LoadFromConfig();
    bool ok;
    {
      std::lock_guard lock(m_guard->mutex);
      ok = buildGraphLocked();
    }
    if (!ok)
      return false;
    registerObservers();
    m_config_callback = Config::AddConfigChangedCallback([this] { refreshFromConfig(); });
    m_has_config_callback = true;
    return true;
  }
}

bool AVAudioEngineSound::SetRunning(bool running)
{
  m_should_run.store(running);
  if (running)
  {
    {
      std::lock_guard lock(m_guard->mutex);
      if (m_engine)
        startEngineLocked();
      else
        rebuildLocked();
    }
    startFeeder();
  }
  else
  {
    stopFeeder();
    // Keep the graph (and the effect chain) alive across a pause; only the clock stops.
    std::lock_guard lock(m_guard->mutex);
    if (m_engine)
      [m_engine pause];
  }
  return true;
}

void AVAudioEngineSound::SetVolume(int volume)
{
  m_volume_percent = std::clamp(volume, 0, 100);
  std::lock_guard lock(m_guard->mutex);
  if (m_engine)
    m_engine.mainMixerNode.outputVolume = m_volume_percent / 100.0f;
}

// MARK: - Feeder thread

void AVAudioEngineSound::startFeeder()
{
  if (m_audio_thread.joinable())
    return;
  m_feeder_running.store(true);
  m_audio_thread = std::thread(&AVAudioEngineSound::audioThreadMain, this);
}

void AVAudioEngineSound::stopFeeder()
{
  m_feeder_running.store(false);
  if (m_audio_thread.joinable())
    m_audio_thread.join();
}

void AVAudioEngineSound::audioThreadMain()
{
  Common::SetCurrentThreadName("AVAudioEngine Feeder");
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

  // Completion-driven backpressure: feed a group (one buffer per player), then block until a
  // group drains. The completion blocks capture these stack objects, so the thread waits for
  // every in-flight group before returning.
  std::atomic<int> groups_in_flight{0};
  std::mutex drain_mutex;
  std::condition_variable drain_cv;
  int pool_cursor = 0;

  auto fill_and_schedule = [&]() {
    std::lock_guard lock(m_guard->mutex);
    if (!m_engine || !m_engine.running || m_players.count == 0)
      return false;

    const Mode mode = m_mode.load();
    const u32 chunk = kChunkFrames;
    const u32 channels = mode == Mode::Stereo ? 2 : kSurroundChannels;
    m_float_temp.resize(static_cast<size_t>(chunk) * channels);

    if (mode == Mode::Stereo)
    {
      m_stereo_temp.resize(static_cast<size_t>(chunk) * 2);
      m_mixer->Mix(m_stereo_temp.data(), chunk);
      for (size_t i = 0; i < m_stereo_temp.size(); ++i)
        m_float_temp[i] = m_stereo_temp[i] / 32768.0f;
    }
    else
    {
      const size_t needed = m_surround->QueryFramesNeededForSurroundOutput(chunk);
      if (needed > 0)
      {
        m_stereo_temp.resize(needed * 2);
        m_mixer->Mix(m_stereo_temp.data(), static_cast<u32>(needed));
        m_surround->PutFrames(m_stereo_temp.data(), needed);
      }
      m_surround->ReceiveFrames(m_float_temp.data(), chunk);
    }
    m_dsp.Process(m_float_temp.data(), chunk);

    const int slot = pool_cursor;
    pool_cursor = (pool_cursor + 1) % kPoolSize;
    groups_in_flight.fetch_add(1);
    const NSUInteger player_count = m_players.count;
    for (NSUInteger p = 0; p < player_count; ++p)
    {
      AVAudioPlayerNode* node = m_players[p];
      AVAudioPCMBuffer* buf = m_buffer_pools[p][slot];
      buf.frameLength = chunk;
      float* const* dst = buf.floatChannelData;
      if (mode == Mode::Spatial)
      {
        // Player p carries surround channel p.
        const float* src = m_float_temp.data() + p;
        for (u32 f = 0; f < chunk; ++f)
          dst[0][f] = src[f * kSurroundChannels];
      }
      else
      {
        for (u32 c = 0; c < channels; ++c)
        {
          const float* src = m_float_temp.data() + c;
          for (u32 f = 0; f < chunk; ++f)
            dst[c][f] = src[f * channels];
        }
      }
      void (^completion)(void) = nil;
      if (p == 0)
      {
        completion = ^{
          {
            std::lock_guard l(drain_mutex);
            groups_in_flight.fetch_sub(1);
          }
          drain_cv.notify_one();
        };
      }
      [node scheduleBuffer:buf completionHandler:completion];
    }
    return true;
  };

  while (m_feeder_running.load())
  {
    if (groups_in_flight.load() >= kTargetGroups)
    {
      std::unique_lock l(drain_mutex);
      drain_cv.wait_for(l, std::chrono::milliseconds(50), [&] {
        return groups_in_flight.load() < kTargetGroups || !m_feeder_running.load();
      });
      continue;
    }
    bool fed;
    @autoreleasepool
    {
      fed = fill_and_schedule();
    }
    if (!fed)
    {
      // Paused, interrupted or mid-rebuild: nothing to do until the engine runs again.
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
  }

  // Flush scheduled buffers so their completions fire, then wait for them: the blocks reference
  // this frame.
  {
    std::lock_guard lock(m_guard->mutex);
    for (AVAudioPlayerNode* node in m_players)
      [node stop];
  }
  std::unique_lock l(drain_mutex);
  drain_cv.wait_for(l, std::chrono::milliseconds(500),
                    [&] { return groups_in_flight.load() <= 0; });
}

// MARK: - Audio Unit effect chain

bool AVAudioEngineSound::instantiateEffect(const std::string& identifier, AVAudioUnit** out_unit)
{
  *out_unit = nil;
  NSString* ident = [NSString stringWithUTF8String:identifier.c_str()];
  AVAudioUnitComponentManager* mgr = [AVAudioUnitComponentManager sharedAudioUnitComponentManager];
  AVAudioUnitComponent* chosen = nil;
  unsigned int t = 0, s = 0, m = 0;
  if (sscanf(identifier.c_str(), "type:%u sub:%u manu:%u", &t, &s, &m) == 3)
  {
    AudioComponentDescription d{};
    d.componentType = (OSType)t;
    d.componentSubType = (OSType)s;
    d.componentManufacturer = (OSType)m;
    chosen = [mgr componentsMatchingDescription:d].firstObject;
  }
  if (!chosen)
  {
    NSPredicate* by_name = [NSPredicate predicateWithFormat:@"name CONTAINS[c] %@", ident];
    chosen = [mgr componentsMatchingPredicate:by_name].firstObject;
  }
  if (!chosen)
  {
    WARN_LOG_FMT(AUDIO, "AVAudioEngine: no Audio Unit matches '{}'", identifier);
    return false;
  }
  __block AVAudioUnit* new_unit = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  [AVAudioUnit instantiateWithComponentDescription:chosen.audioComponentDescription
                                           options:0
                                 completionHandler:^(AVAudioUnit* unit, NSError* err) {
                                   if (err)
                                     WARN_LOG_FMT(AUDIO, "AVAudioEngine: instantiate failed: {}",
                                                  err.localizedDescription.UTF8String);
                                   new_unit = unit;
                                   dispatch_semaphore_signal(sem);
                                 }];
  dispatch_semaphore_wait(
      sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kInstantiateTimeoutSeconds * NSEC_PER_SEC)));
  if (!new_unit)
  {
    WARN_LOG_FMT(AUDIO, "AVAudioEngine: instantiating '{}' timed out", identifier);
    return false;
  }
  *out_unit = new_unit;
  return true;
}

std::string AVAudioEngineSound::serializeEffectChainLocked() const
{
  std::ostringstream out;
  bool first = true;
  for (AVAudioUnit* unit : m_fx_units)
  {
    const AudioComponentDescription d = unit.audioComponentDescription;
    if (!first)
      out << ';';
    first = false;
    out << "type:" << (unsigned)d.componentType << " sub:" << (unsigned)d.componentSubType
        << " manu:" << (unsigned)d.componentManufacturer << '|' << (unit.AUAudioUnit.shouldBypassEffect ? 1 : 0)
        << '|';
    NSDictionary* state = unit.AUAudioUnit.fullState;
    if (state)
    {
      NSError* err = nil;
      NSData* data = [NSKeyedArchiver archivedDataWithRootObject:state
                                           requiringSecureCoding:NO
                                                           error:&err];
      if (data && !err)
        out << Base64(data).UTF8String;
    }
  }
  return out.str();
}

void AVAudioEngineSound::restoreEffectChainLocked()
{
  const std::string stored = Config::Get(Config::MAIN_AUDIO_AU_CHAIN);
  if (stored.empty() || !m_engine)
    return;
  for (const std::string& entry : SplitString(stored, ';'))
  {
    const std::vector<std::string> fields = SplitString(entry, '|');
    if (fields.empty() || fields[0].empty())
      continue;
    AVAudioUnit* unit = nil;
    if (!instantiateEffect(fields[0], &unit))
      continue;
    [m_engine attachNode:unit];
    if (fields.size() > 1)
      unit.AUAudioUnit.shouldBypassEffect = fields[1] == "1";
    if (fields.size() > 2 && !fields[2].empty())
    {
      NSData* data = [[NSData alloc]
          initWithBase64EncodedString:[NSString stringWithUTF8String:fields[2].c_str()]
                             options:0];
      if (data)
      {
        NSError* err = nil;
        NSDictionary* state = [NSKeyedUnarchiver unarchivedObjectOfClasses:
                                                    [NSSet setWithObjects:NSDictionary.class,
                                                                          NSArray.class,
                                                                          NSString.class,
                                                                          NSNumber.class,
                                                                          NSData.class,
                                                                          NSDate.class, nil]
                                                                 fromData:data
                                                                    error:&err];
        if (state && !err)
          unit.AUAudioUnit.fullState = state;
      }
    }
    m_fx_units.push_back(unit);
  }
}

void AVAudioEngineSound::saveEffectChain()
{
  std::string chain;
  {
    std::lock_guard lock(m_guard->mutex);
    chain = serializeEffectChainLocked();
  }
  Config::SetBaseOrCurrent(Config::MAIN_AUDIO_AU_CHAIN, chain);
}

bool AVAudioEngineSound::addEffectWithIdentifier(const char* identifier)
{
  if (!identifier)
    return false;
  AVAudioUnit* unit = nil;
  if (!instantiateEffect(identifier, &unit))
    return false;
  {
    std::lock_guard lock(m_guard->mutex);
    if (!m_engine)
      return false;
    [m_engine attachNode:unit];
    m_fx_units.push_back(unit);
    reconnectGraphLocked();
    INFO_LOG_FMT(AUDIO, "AVAudioEngine: added effect {}", unit.name.UTF8String ?: "(unnamed)");
  }
  saveEffectChain();
  return true;
}

void AVAudioEngineSound::removeEffectAt(size_t index)
{
  {
    std::lock_guard lock(m_guard->mutex);
    if (!m_engine || index >= m_fx_units.size())
      return;
    AVAudioUnit* unit = m_fx_units[index];
    [m_engine disconnectNodeOutput:unit];
    [m_engine detachNode:unit];
    m_fx_units.erase(m_fx_units.begin() + index);
    reconnectGraphLocked();
  }
  saveEffectChain();
}

void AVAudioEngineSound::moveEffect(size_t from, size_t to)
{
  {
    std::lock_guard lock(m_guard->mutex);
    if (from >= m_fx_units.size() || to >= m_fx_units.size() || from == to)
      return;
    AVAudioUnit* unit = m_fx_units[from];
    m_fx_units.erase(m_fx_units.begin() + from);
    m_fx_units.insert(m_fx_units.begin() + to, unit);
    reconnectGraphLocked();
  }
  saveEffectChain();
}

void AVAudioEngineSound::setEffectBypass(size_t index, bool bypassed)
{
  {
    std::lock_guard lock(m_guard->mutex);
    if (index >= m_fx_units.size())
      return;
    m_fx_units[index].AUAudioUnit.shouldBypassEffect = bypassed;
  }
  saveEffectChain();
}

size_t AVAudioEngineSound::fxCount() const
{
  std::lock_guard lock(m_guard->mutex);
  return m_fx_units.size();
}

AVAudioUnit* AVAudioEngineSound::fxAt(size_t i) const
{
  std::lock_guard lock(m_guard->mutex);
  return i < m_fx_units.size() ? m_fx_units[i] : nil;
}

#endif  // IPHONEOS
