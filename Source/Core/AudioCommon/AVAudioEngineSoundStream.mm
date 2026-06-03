// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#ifdef IPHONEOS

#import <AVFoundation/AVFoundation.h>
#if TARGET_OS_IOS
#import <CoreMotion/CoreMotion.h>
#endif

#include "AudioCommon/AVAudioEngineSoundStream.h"
#include "AudioCommon/Mixer.h"
#include "Common/Logging/Log.h"

#include <chrono>
#include <condition_variable>

AVAudioEngineSound* AVAudioEngineSound::s_active = nullptr;

static const AVAudio3DPoint kSpeakerPositions[6] = {
  { -1.0f, 0.0f, 1.0f },  // FL
  {  1.0f, 0.0f, 1.0f },  // FR
  {  0.0f, 0.0f, 1.5f },  // FC (slightly forward)
  {  0.0f, 0.0f, 0.5f },  // LFE (co-located with center)
  { -1.0f, 0.0f,-1.0f },  // BL
  {  1.0f, 0.0f,-1.0f },  // BR
};

AVAudioEngineSound* AVAudioEngineSound::Active() { return s_active; }

bool AVAudioEngineSound::buildAndStartEngine()
{
  // Insurance: AVAudioEngine is far pickier than CoreAudio's RemoteIO about an
  // active Playback session. The app layer (AudioSessionCategoryService) already
  // sets category=Playback + setActive:YES at launch, but re-assert here so the
  // engine never starts against an inactive/ambient session (a classic silent-
  // AVAudioEngine cause). Idempotent; failures are non-fatal (logged only).
#if !TARGET_OS_OSX
  {
    AVAudioSession* session = [AVAudioSession sharedInstance];
    NSError* sessErr = nil;
    if (session.category != AVAudioSessionCategoryPlayback)
    {
      [session setCategory:AVAudioSessionCategoryPlayback
               withOptions:(AVAudioSessionCategoryOptionAllowBluetoothA2DP |
                            AVAudioSessionCategoryOptionAllowAirPlay)
                     error:&sessErr];
    }
    if (![session setActive:YES error:&sessErr] && sessErr)
    {
      WARN_LOG_FMT(AUDIO, "AVAudioEngine: setActive failed: {}",
                   sessErr.localizedDescription.UTF8String);
    }
  }
#endif

  // Track the engine against the Mixer's real output rate, not a hardcoded 48k.
  // AudioInterface::Init has finalized the rate by the time the backend inits
  // (CoreAudio reads the same value), so a game running at 32 kHz stays in pitch.
  const double sampleRate = m_mixer ? (double)m_mixer->GetSampleRate() : (double)kSampleRate;

  m_engine = [[AVAudioEngine alloc] init];
  m_environment = [[AVAudioEnvironmentNode alloc] init];
  m_environment.distanceAttenuationParameters.distanceAttenuationModel = AVAudioEnvironmentDistanceAttenuationModelLinear;
  // outputType drives how `.auto` (and HRTF on non-headphone routes) spatializes.
  // `.auto` follows the live route so the env node renders audibly to speakers,
  // headphones, or external out instead of a route-mismatched (silent) default.
  if (@available(iOS 14.0, tvOS 14.0, macOS 11.0, *))
  {
    m_environment.outputType = AVAudioEnvironmentOutputTypeAuto;
  }
  [m_engine attachNode:m_environment];

  AVAudioFormat* outFmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sampleRate channels:2];
  [m_engine connect:m_environment to:m_engine.mainMixerNode format:outFmt];

  AVAudioFormat* monoFmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sampleRate channels:1];
  m_monoFloatFormat = monoFmt;
  for (int i = 0; i < 6; ++i)
  {
    AVAudioPlayerNode* node = [[AVAudioPlayerNode alloc] init];
    m_nodes[i] = node;
    [m_engine attachNode:node];
    [m_engine connect:node to:m_environment format:monoFmt];
    node.volume = 1.0f;
    node.position = kSpeakerPositions[i];
    // renderingAlgorithm is an AVAudio3DMixing *per-source-bus* property. It must
    // be set on the source (player) nodes, NOT on the environment node. The old
    // code set it on m_environment, which was a no-op and left each source at the
    // default — a key reason this backend rendered no usable output. HRTF needs a
    // mono source (monoFmt above satisfies that).
    node.renderingAlgorithm = AVAudio3DMixingRenderingAlgorithmHRTF;
  }

  NSError* err = nil;
  if (![m_engine startAndReturnError:&err])
  {
    ERROR_LOG_FMT(AUDIO, "AVAudioEngine start error: {}",
                  err ? err.localizedDescription.UTF8String : "unknown");
    return false;
  }
  // Start every player node here, so this covers BOTH the initial build and every
  // route-change / interruption rebuild. A freshly-allocated AVAudioPlayerNode
  // produces no sound until `play` is sent even with the engine running and
  // buffers scheduled; the rebuild path used to skip this and went permanently
  // silent on the very route change (e.g. plugging in headphones) that this
  // spatial backend exists for.
  for (int i = 0; i < 6; ++i)
    [m_nodes[i] play];
  s_active = this;
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
    s_active = nullptr;
    m_fx_units.clear();
  }
}

void AVAudioEngineSound::registerAudioSessionObservers()
{
#if !TARGET_OS_OSX
  AVAudioSession* session = [AVAudioSession sharedInstance];
  AVAudioEngineSound* selfPtr = this;
  m_routeToken = [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification object:session queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification* note){
    (void)note;
    if (!selfPtr) return;
    // Hold the lock across teardown+rebuild so the audio thread never schedules
    // a buffer on a node that's being swapped out / set to nil mid-rebuild.
    std::lock_guard<std::mutex> lock(selfPtr->m_engine_mutex);
    selfPtr->teardownEngine();
    selfPtr->buildAndStartEngine();
  }];
  m_interruptToken = [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionInterruptionNotification object:session queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification* note){
    NSNumber* typeNum = note.userInfo[AVAudioSessionInterruptionTypeKey];
    AVAudioSessionInterruptionType type = (AVAudioSessionInterruptionType)typeNum.unsignedIntegerValue;
    if (type == AVAudioSessionInterruptionTypeEnded) {
      if (!selfPtr) return;
      std::lock_guard<std::mutex> lock(selfPtr->m_engine_mutex);
      selfPtr->teardownEngine();
      selfPtr->buildAndStartEngine();
    }
  }];
#endif
}

void AVAudioEngineSound::unregisterAudioSessionObservers()
{
#if !TARGET_OS_OSX
  if (m_routeToken) [[NSNotificationCenter defaultCenter] removeObserver:m_routeToken];
  if (m_interruptToken) [[NSNotificationCenter defaultCenter] removeObserver:m_interruptToken];
  m_routeToken = nil;
  m_interruptToken = nil;
#endif
}

void AVAudioEngineSound::startHeadTracking()
{
#if TARGET_OS_IOS
  if (m_motion) return;
  m_motion = [[CMMotionManager alloc] init];
  if (!m_motion.isDeviceMotionAvailable) return;
  m_motion.deviceMotionUpdateInterval = 1.0 / 60.0;
  AVAudioEngineSound* selfPtr = this;
  [m_motion startDeviceMotionUpdatesToQueue:[NSOperationQueue mainQueue] withHandler:^(CMDeviceMotion* motion, NSError* error){
    (void)error;
    if (!selfPtr || !motion) return;
    CMAttitude* a = motion.attitude;
    selfPtr->m_environment.listenerAngularOrientation = (AVAudio3DAngularOrientation){ (float)a.yaw, (float)a.pitch, (float)a.roll };
  }];
#endif
}

void AVAudioEngineSound::stopHeadTracking()
{
#if TARGET_OS_IOS
  if (m_motion) { [m_motion stopDeviceMotionUpdates]; m_motion = nil; }
#endif
}

bool AVAudioEngineSound::Init()
{
  @autoreleasepool {
    m_surround = std::make_unique<AudioCommon::SurroundDecoder>(kSampleRate, m_chunkFrames.load());

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
    // removeObserver doesn't cancel a route/interruption block already dispatched
    // to the main queue; that block also takes m_engine_mutex around its
    // teardown+rebuild. Take it here too so shutdown can't race a late rebuild.
    std::lock_guard<std::mutex> lock(m_engine_mutex);
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
    // Fixed chunk size: with the adaptive tap removed, chunk == the surround
    // decoder's frame_block_size for the life of the stream (no drift glitch).
    const uint32_t chunk = m_chunkFrames.load();

    // Bounded number of buffer-groups (one buffer per channel = a "group") kept
    // in flight. Completion-handler-driven backpressure replaces the old fragile
    // sleep(chunkMicros/3) loop, which fed ~3x faster than playback and grew an
    // unbounded backlog. We feed a group, then block until a group drains.
    constexpr int kTargetGroups = 3;
    std::atomic<int> groupsInFlight{0};
    std::mutex drainMutex;
    std::condition_variable drainCv;

    auto fillAndScheduleGroup = [&]() {
      const size_t neededStereo = m_surround->QueryFramesNeededForSurroundOutput(chunk);
      if (neededStereo > 0)
      {
        m_stereo_temp.resize(neededStereo * 2);
        m_mixer->Mix(m_stereo_temp.data(), static_cast<u32>(neededStereo));
        m_surround->PutFrames(m_stereo_temp.data(), neededStereo);
      }
      m_surround_temp.resize(static_cast<size_t>(chunk) * 6);
      m_surround->ReceiveFrames(m_surround_temp.data(), chunk);

      // Touch the node graph under the lock so a route/interruption rebuild can't
      // swap m_nodes out from under us mid-schedule.
      std::lock_guard<std::mutex> graphLock(m_engine_mutex);
      if (!m_engine)
        return;  // mid-rebuild; skip this group, we'll catch up next iteration.

      // Increment only once we've confirmed the channel-0 node exists, since the
      // ch==0 completion is what decrements. Bailing after an unmatched increment
      // would leak the count upward and stall feeding (eventual silence).
      if (!m_nodes[0])
        return;
      groupsInFlight.fetch_add(1);
      for (int ch = 0; ch < 6; ++ch)
      {
        AVAudioPlayerNode* node = m_nodes[ch];
        if (!node)
          continue;
        // Per-buffer allocation kept (AVAudioPCMBuffer can't be safely mutated
        // while scheduled/in flight); but it's now bounded by kTargetGroups
        // instead of an unbounded backlog.
        AVAudioPCMBuffer* buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:m_monoFloatFormat frameCapacity:chunk];
        buf.frameLength = chunk;
        float* dst = buf.floatChannelData[0];
        const float* src = m_surround_temp.data() + ch;
        for (uint32_t f = 0; f < chunk; ++f)
          dst[f] = src[f * 6];
        // Count one completion per group (channel 0 only) so the in-flight count
        // tracks groups, not individual buffers.
        void (^completion)(void) = nil;
        if (ch == 0)
        {
          completion = ^{
            {
              // Decrement under the lock the waiter holds during wait_for so the
              // predicate-check + notify can't interleave into a lost wakeup.
              std::lock_guard<std::mutex> l(drainMutex);
              groupsInFlight.fetch_sub(1);
            }
            drainCv.notify_one();
          };
        }
        [node scheduleBuffer:buf completionHandler:completion];
      }
    };

    // Prime a couple of groups. The player nodes are already `play`ing (started
    // in buildAndStartEngine, which also re-arms them after every rebuild), so
    // primed buffers begin output as soon as they're scheduled.
    fillAndScheduleGroup();
    fillAndScheduleGroup();

    while (m_running.load())
    {
      // Backpressure: only feed when below the in-flight target. Wait (with a
      // timeout so we never deadlock if a completion is missed during a rebuild)
      // for a group to drain.
      if (groupsInFlight.load() >= kTargetGroups)
      {
        std::unique_lock<std::mutex> l(drainMutex);
        drainCv.wait_for(l, std::chrono::milliseconds(50), [&]{
          return groupsInFlight.load() < kTargetGroups || !m_running.load();
        });
      }
      if (!m_running.load())
        break;
      @autoreleasepool {
        fillAndScheduleGroup();
      }
    }

    // Stop nodes (flushes/cancels scheduled buffers, firing pending completion
    // handlers) under the graph lock.
    {
      std::lock_guard<std::mutex> graphLock(m_engine_mutex);
      for (int i = 0; i < 6; ++i)
        if (m_nodes[i]) [m_nodes[i] stop];
    }
    // CRITICAL: the completion blocks capture drainMutex/drainCv/groupsInFlight
    // by reference to this stack frame. We must not return until every in-flight
    // group's completion has run, or a late callback would touch freed stack.
    {
      std::unique_lock<std::mutex> l(drainMutex);
      drainCv.wait_for(l, std::chrono::milliseconds(500), [&]{
        return groupsInFlight.load() <= 0;
      });
    }
  }
}

// MARK: - FX chain management
bool AVAudioEngineSound::addEffectWithIdentifier(const char* identifier)
{
  if (!m_engine || !identifier) return false;
  NSString* ident = [NSString stringWithUTF8String:identifier];
  AVAudioUnitEffect* unit = nil;
  // Try to parse identifier as type/sub/manu triple: "type:%u sub:%u manu:%u"
  unsigned int t = 0, s = 0, m = 0;
  BOOL parsed = NO;
  const char* cstr = [ident UTF8String];
  int matched = cstr ? sscanf(cstr, "type:%u sub:%u manu:%u", &t, &s, &m) : 0;
  parsed = (matched == 3) ? YES : NO;
  NSLog(@"[FX/Engine] addEffect ident=%@ parsed=%d t=%u s=%u m=%u", ident, parsed, t, s, m);

  AVAudioUnitComponentManager* mgr = [AVAudioUnitComponentManager sharedAudioUnitComponentManager];
  AVAudioUnitComponent* chosen = nil;
  if (parsed) {
    AudioComponentDescription d; memset(&d, 0, sizeof(d));
    d.componentType = (OSType)t;
    d.componentSubType = (OSType)s;
    d.componentManufacturer = (OSType)m;
    NSArray<AVAudioUnitComponent*>* comps = [mgr componentsMatchingDescription:d];
    chosen = comps.firstObject;
  }
  if (!chosen) {
    // Fallback: name contains
    NSArray<AVAudioUnitComponent*>* comps = [mgr componentsMatchingPredicate:[NSPredicate predicateWithFormat:@"name CONTAINS[c] %@", ident]];
    chosen = comps.firstObject;
  }
  if (!chosen) { NSLog(@"[FX/Engine] No matching component for %@", ident); return false; }
  __block AVAudioUnit* newUnit = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  [AVAudioUnit instantiateWithComponentDescription:chosen.audioComponentDescription options:0 completionHandler:^(AVAudioUnit* _Nullable avu, NSError* _Nullable err){
    if (err) NSLog(@"[FX/Engine] instantiate error: %@", err.localizedDescription);
    newUnit = avu; dispatch_semaphore_signal(sem);
  }];
  (void)dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
  if (!newUnit) { NSLog(@"[FX/Engine] instantiate timed out or failed for %@", ident); return false; }
  unit = (AVAudioUnitEffect*)newUnit;
  [m_engine attachNode:unit];
  m_fx_units.push_back(unit);
  reconnectGraph();
  NSLog(@"[FX/Engine] Added effect: %@", unit.name ?: @"(unnamed)");
  return true;
}

void AVAudioEngineSound::removeEffectAt(size_t index)
{
  if (!m_engine) return;
  if (index >= m_fx_units.size()) return;
  AVAudioUnitEffect* unit = m_fx_units[index];
  [m_engine detachNode:unit];
  m_fx_units.erase(m_fx_units.begin() + index);
  reconnectGraph();
}

void AVAudioEngineSound::moveEffect(size_t from, size_t to)
{
  if (from >= m_fx_units.size() || to >= m_fx_units.size() || from == to) return;
  AVAudioUnitEffect* u = m_fx_units[from];
  m_fx_units.erase(m_fx_units.begin() + from);
  m_fx_units.insert(m_fx_units.begin() + to, u);
  reconnectGraph();
}

void AVAudioEngineSound::setEffectBypass(size_t index, bool bypassed)
{
  if (index >= m_fx_units.size()) return;
  m_fx_units[index].bypass = bypassed;
}

void AVAudioEngineSound::reconnectGraph()
{
  if (!m_engine) return;
  // Disconnect environment tail and rebuild: env -> fx0 -> fx1 -> ... -> mainMixer
  [m_engine disconnectNodeOutput:m_environment];
  AVAudioNode* tail = m_environment;
  for (AVAudioUnitEffect* u : m_fx_units)
  {
    [m_engine connect:tail to:u format:[m_engine.mainMixerNode outputFormatForBus:0]];
    tail = u;
  }
  [m_engine connect:tail to:m_engine.mainMixerNode format:[m_engine.mainMixerNode outputFormatForBus:0]];
}

void AVAudioEngineSound::requestEffectUI(size_t index)
{
  (void)index; // UI will be handled by Swift layer requesting AVAudioUnit’s view controller
}

#endif // IPHONEOS
