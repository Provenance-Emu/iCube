// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#ifdef IPHONEOS

#import <AVFoundation/AVFoundation.h>
#if TARGET_OS_IOS
#import <CoreMotion/CoreMotion.h>
#endif

#include "AudioCommon/AVAudioEngineSoundStream.h"
#include "Common/Logging/Log.h"

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

  // Add a tap to monitor render timing and adapt chunk size
  AVAudioMixerNode* mixer = m_engine.mainMixerNode;
  const AVAudioFrameCount tapBuf = 256;
  [mixer installTapOnBus:0 bufferSize:tapBuf format:[mixer outputFormatForBus:0] block:^(AVAudioPCMBuffer* buffer, AVAudioTime* when){
    (void)buffer; (void)when;
    static int counter = 0; counter = (counter + 1) % 30;
    if (counter == 0) {
      uint32_t cur = m_chunkFrames.load();
      if (cur < 256) cur += 32; else if (cur > 256) cur -= 32;
      cur = std::max<uint32_t>(128, std::min<uint32_t>(512, cur));
      m_chunkFrames.store(cur);
    }
  }];

  NSError* err = nil;
  if (![m_engine startAndReturnError:&err])
  {
    ERROR_LOG_FMT(AUDIO, "AVAudioEngine start error: {}", err.localizedDescription.UTF8String);
    return false;
  }
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
    if (m_engine && m_engine.mainMixerNode) {
      [m_engine.mainMixerNode removeTapOnBus:0];
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
    selfPtr->teardownEngine();
    selfPtr->buildAndStartEngine();
  }];
  m_interruptToken = [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionInterruptionNotification object:session queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification* note){
    NSNumber* typeNum = note.userInfo[AVAudioSessionInterruptionTypeKey];
    AVAudioSessionInterruptionType type = (AVAudioSessionInterruptionType)typeNum.unsignedIntegerValue;
    if (type == AVAudioSessionInterruptionTypeEnded) {
      if (!selfPtr) return;
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
    const int warmBuffers = 2;
    for (int warm = 0; warm < warmBuffers; ++warm)
    {
      const uint32_t chunk = m_chunkFrames.load();
      const size_t neededStereo = m_surround->QueryFramesNeededForSurroundOutput(chunk);
      if (neededStereo > 0)
      {
        m_stereo_temp.resize(neededStereo * 2);
        m_mixer->Mix(m_stereo_temp.data(), static_cast<u32>(neededStereo));
        m_surround->PutFrames(m_stereo_temp.data(), neededStereo);
      }
      m_surround_temp.resize(static_cast<size_t>(chunk) * 6);
      m_surround->ReceiveFrames(m_surround_temp.data(), chunk);
      for (int ch = 0; ch < 6; ++ch)
      {
        AVAudioPCMBuffer* buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:m_monoFloatFormat frameCapacity:chunk];
        buf.frameLength = chunk;
        float* dst = buf.floatChannelData[0];
        const float* src = m_surround_temp.data() + ch;
        for (uint32_t f = 0; f < chunk; ++f)
          dst[f] = src[f * 6];
        [m_nodes[ch] scheduleBuffer:buf completionHandler:nil];
      }
    }
    for (int i = 0; i < 6; ++i) [m_nodes[i] play];

    while (m_running.load())
    {
      const uint32_t chunk = m_chunkFrames.load();
      const size_t neededStereo = m_surround->QueryFramesNeededForSurroundOutput(chunk);
      if (neededStereo > 0)
      {
        m_stereo_temp.resize(neededStereo * 2);
        m_mixer->Mix(m_stereo_temp.data(), static_cast<u32>(neededStereo));
        m_surround->PutFrames(m_stereo_temp.data(), neededStereo);
      }

      m_surround_temp.resize(static_cast<size_t>(chunk) * 6);
      m_surround->ReceiveFrames(m_surround_temp.data(), chunk);

      for (int ch = 0; ch < 6; ++ch)
      {
        AVAudioPCMBuffer* buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:m_monoFloatFormat frameCapacity:chunk];
        buf.frameLength = chunk;
        float* dst = buf.floatChannelData[0];
        const float* src = m_surround_temp.data() + ch;
        for (uint32_t f = 0; f < chunk; ++f)
          dst[f] = src[f * 6];
        [m_nodes[ch] scheduleBuffer:buf completionHandler:nil];
      }

      const uint32_t chunkMicros = static_cast<uint32_t>((1000000ULL * chunk) / kSampleRate);
      std::this_thread::sleep_for(std::chrono::microseconds(chunkMicros / 3));
    }

    for (int i = 0; i < 6; ++i)
      [m_nodes[i] stop];
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
