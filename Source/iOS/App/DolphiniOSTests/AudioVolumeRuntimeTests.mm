// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
#import <XCTest/XCTest.h>
#import "../Common/Bridging/DOLConfigBridge.h"
#import "../Common/Emulation/TVEmulationBridge.h"
#import "HostQueue.h"

// The packaged core uses this platform guard for its iOS/tvOS backend class.
#ifndef IPHONEOS
#define IPHONEOS 1
#endif
#import "../Common/Bridging/AudioVolumeRuntime.h"
#include <array>
#include <memory>
#include <optional>
#include <string>
#include <vector>
#include "AudioCommon/CoreAudioSoundStream.h"
#include "Common/Config/Config.h"
#include "Core/Config/MainSettings.h"
#include "Core/Core.h"
#include "Core/System.h"

namespace
{
struct SavedAudioSetting
{
  Config::LayerType layer;
  Config::Location location;
  std::optional<std::string> value;
};

/// Owns an actual backend/DSP, but never calls Init: no AudioUnit, device or ROM.
/// The caller must establish that no game/stream exists before constructing it.
struct AudioFixture
{
  Core::System& system = Core::System::GetInstance();
  std::vector<SavedAudioSetting> saved;
  CoreAudioSound* sound = nullptr;

  AudioFixture()
  {
    for (const auto layer : {Config::LayerType::Base, Config::LayerType::CurrentRun})
    {
      for (const auto& location : {Config::MAIN_AUDIO_VOLUME.GetLocation(),
                                   Config::MAIN_AUDIO_MUTED.GetLocation(),
                                   Config::MAIN_EMULATION_SPEED.GetLocation(),
                                   Config::MAIN_AUDIO_MUTE_ON_DISABLED_SPEED_LIMIT.GetLocation()})
      {
        saved.push_back({layer, location, Config::GetLayer(layer)->Get<std::string>(location)});
      }
    }
    Config::SetCurrent(Config::MAIN_AUDIO_MUTED, false);
    Config::SetCurrent(Config::MAIN_AUDIO_VOLUME, 70);
    auto backend = std::make_unique<CoreAudioSound>();
    sound = backend.get();
    sound->GetDSPChain().Configure(48000, 2);
    system.SetSoundStream(std::move(backend));
  }

  ~AudioFixture()
  {
    system.SetSoundStream(nullptr);
    for (const auto& entry : saved)
    {
      const auto layer = Config::GetLayer(entry.layer);
      if (!layer)
        continue;
      if (entry.value)
        layer->Set(entry.location, *entry.value);
      else
        layer->DeleteKey(entry.location);
    }
    Config::OnConfigChanged();
    if (Config::GetLayer(Config::LayerType::Base))
      [DOLConfigBridge flushSettingsToDisk];
  }
};
}  // namespace

@interface AudioVolumeRuntimeTests : XCTestCase
{
  std::unique_ptr<AudioFixture> _fixture;
}
@end

@implementation AudioVolumeRuntimeTests
- (void)setUp
{
  [super setUp];
  self.continueAfterFailure = NO;
  // App-host initialization supplies both layers. Fail safely rather than
  // dereferencing a missing layer if this suite is launched in another host.
  const auto base = Config::GetLayer(Config::LayerType::Base);
  const auto current = Config::GetLayer(Config::LayerType::CurrentRun);
  XCTAssertTrue(base != nullptr, @"App host must initialize the Base Config layer");
  XCTAssertTrue(current != nullptr, @"App host must initialize the CurrentRun Config layer");
  if (!base || !current)
    return;
  auto& system = Core::System::GetInstance();
  // Never replace an owner's running game's backend, even if this suite is misrouted.
  XCTAssertTrue(Core::GetState(system) == Core::State::Uninitialized);
  XCTAssertTrue(system.GetSoundStream() == nullptr);
  if (Core::GetState(system) != Core::State::Uninitialized || system.GetSoundStream())
    return;
  _fixture = std::make_unique<AudioFixture>();
}

- (void)tearDown
{
  if (_fixture)
  {
    [self waitForAudioUpdates];
    _fixture.reset();
  }
  [super tearDown];
}

/// Barrier after the production setter's main/host queue hops. Waiting pumps main,
/// so this also works when XCTest invokes the test method on the main thread.
- (void)waitForAudioUpdates
{
  XCTestExpectation* finished = [self expectationWithDescription:@"audio host queue drained"];
  dispatch_async(dispatch_get_main_queue(), ^{
    DOLHostQueueRunAsync(^{
      dispatch_async(dispatch_get_main_queue(), ^{ [finished fulfill]; });
    });
  });
  [self waitForExpectations:@[finished] timeout:5];
}

- (void)assertOutputGain:(float)gain
{
  XCTAssertTrue(_fixture && _fixture->sound);
  if (!_fixture || !_fixture->sound)
    return;
  auto& dsp = _fixture->sound->GetDSPChain();
  auto parameters = dsp.GetParameters();
  XCTAssertEqualWithAccuracy(parameters.gain, gain, 0.000001f);
  // Isolate sample scaling from an owner's saved effects or future backend
  // initialization changes. Keep the ACTUAL gain above: never seed the expected
  // gain into the DSP, which would hide a missing production SetVolume call.
  parameters.delay_enabled = false;
  parameters.crush_enabled = false;
  parameters.eq_enabled = false;
  dsp.SetParameters(parameters);
  std::array<float, 4> pcm{0.5f, -0.5f, 0.25f, -0.25f};
  dsp.Process(pcm.data(), 2);
  XCTAssertEqualWithAccuracy(pcm[0], 0.5f * gain, 0.000001f);
  XCTAssertEqualWithAccuracy(pcm[1], -0.5f * gain, 0.000001f);
  XCTAssertEqualWithAccuracy(pcm[2], 0.25f * gain, 0.000001f);
  XCTAssertEqualWithAccuracy(pcm[3], -0.25f * gain, 0.000001f);
}

- (void)testMasterVolumeMutesAndRestoresRealCoreAudioOutput
{
  // A failed setup must leave a live game or uninitialized host untouched.
  if (!_fixture)
    return;
  [DOLConfigBridge setAudioVolume:70];
  [self waitForAudioUpdates];
  [self assertOutputGain:0.7f];
  [DOLConfigBridge setAudioVolume:0];
  [self waitForAudioUpdates];
  [self assertOutputGain:0];
  [DOLConfigBridge setAudioVolume:70];
  [self waitForAudioUpdates];
  [self assertOutputGain:0.7f];
}

- (void)testPauseMenuVolumeUpdatesRealCoreAudioOutputAndKeepsBaseSetting
{
  // A failed setup must leave a live game or uninitialized host untouched.
  if (!_fixture)
    return;
  const int base = Config::Get(Config::LayerType::Base, Config::MAIN_AUDIO_VOLUME);
  [TVEmulationBridge setAudioVolumePercent:0];
  [self waitForAudioUpdates];
  [self assertOutputGain:0];
  [TVEmulationBridge setAudioVolumePercent:40];
  [self waitForAudioUpdates];
  [self assertOutputGain:0.4f];
  XCTAssertEqual(Config::Get(Config::LayerType::Base, Config::MAIN_AUDIO_VOLUME), base);
}

- (void)testUnchangedConfigValueStillReachesTheLiveBackend
{
  // A failed setup must leave a live game or uninitialized host untouched.
  if (!_fixture)
    return;
  Config::SetCurrent(Config::MAIN_AUDIO_VOLUME, 0);
  // Setting Config alone has never changed this newly constructed backend's gain.
  [self assertOutputGain:1];
  [DOLConfigBridge setAudioVolume:0];
  [self waitForAudioUpdates];
  [self assertOutputGain:0];
}

- (void)testMasterMuteFlagStillWinsOverNonzeroVolume
{
  // A failed setup must leave a live game or uninitialized host untouched.
  if (!_fixture)
    return;
  Config::SetCurrent(Config::MAIN_AUDIO_MUTED, true);
  [DOLConfigBridge setAudioVolume:70];
  [self waitForAudioUpdates];
  [self assertOutputGain:0];
  Config::SetCurrent(Config::MAIN_AUDIO_MUTED, false);
  [DOLConfigBridge setAudioVolume:70];
  [self waitForAudioUpdates];
  [self assertOutputGain:0.7f];
}

- (void)testReadinessReplayAppliesVolumeChangedAfterInitialBackendGain
{
  if (!_fixture)
    return;
  // Establish the gain already applied by the core's initial sound setup.
  [DOLConfigBridge setAudioVolume:70];
  [self waitForAudioUpdates];
  [self assertOutputGain:0.7f];

  // Model a later Config edit whose runtime update was deferred during Starting.
  // No ROM/CPU is started: this checks the replay against the actual backend.
  Config::SetCurrent(Config::MAIN_AUDIO_VOLUME, 0);
  [self assertOutputGain:0.7f];
  ICubeUpdateAudioVolumeAsync();
  [self waitForAudioUpdates];
  [self assertOutputGain:0];
}

- (void)testMasterVolumeClampsBackendGainWithoutChangingStoredRequest
{
  if (!_fixture)
    return;
  [DOLConfigBridge setAudioVolume:-15];
  [self waitForAudioUpdates];
  [self assertOutputGain:0];
  XCTAssertEqual([DOLConfigBridge audioVolume], -15);
  [DOLConfigBridge setAudioVolume:130];
  [self waitForAudioUpdates];
  [self assertOutputGain:1];
  XCTAssertEqual([DOLConfigBridge audioVolume], 130);
}

- (void)testPauseMenuVolumeClampsBothStoredVolumeAndBackendGain
{
  if (!_fixture)
    return;
  [TVEmulationBridge setAudioVolumePercent:-15];
  [self waitForAudioUpdates];
  [self assertOutputGain:0];
  XCTAssertEqual([TVEmulationBridge audioVolumePercent], 0);
  [TVEmulationBridge setAudioVolumePercent:130];
  [self waitForAudioUpdates];
  [self assertOutputGain:1];
  XCTAssertEqual([TVEmulationBridge audioVolumePercent], 100);
}

- (void)testFastForwardMuteAndRestoreReachRealCoreAudioOutput
{
  if (!_fixture)
    return;
  NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
  NSString* const speedKey = @"fast_forward_speed_percent";
  id savedPercent = [defaults objectForKey:speedKey];
  const bool savedThrottler = Core::GetIsThrottlerTempDisabled();
  NSUInteger toggles = 0;
  @try
  {
    [defaults setInteger:200 forKey:speedKey];
    Config::SetCurrent(Config::MAIN_AUDIO_MUTE_ON_DISABLED_SPEED_LIMIT, true);
    // FF removes its CurrentRun mute override on exit. An owner's Base mute
    // must not obscure the restoration being checked; the fixture restores it.
    Config::SetBase(Config::MAIN_AUDIO_MUTED, false);
    Config::SetCurrent(Config::MAIN_AUDIO_MUTED, false);
    [DOLConfigBridge setAudioVolume:70];
    [self waitForAudioUpdates];
    [self assertOutputGain:0.7f];

    ++toggles;
    const BOOL enabled = [TVEmulationBridge toggleFastForward];
    XCTAssertTrue(enabled, @"This idle test host must start with fast-forward off");
    if (!enabled)
      return;
    [self waitForAudioUpdates];
    [self assertOutputGain:0];

    ++toggles;
    const BOOL disabled = [TVEmulationBridge toggleFastForward];
    XCTAssertFalse(disabled);
    [self waitForAudioUpdates];
    [self assertOutputGain:0.7f];
  }
  @finally
  {
    // XCTest can raise on an assertion because continueAfterFailure is NO.
    // An even number of production toggles restores the private FF flag even
    // when the test failed after only its first toggle. Never infer that flag
    // from isFastForwardEnabled(), which derives speed/throttler instead.
    if (toggles % 2 != 0)
      [TVEmulationBridge toggleFastForward];
    Core::SetIsThrottlerTempDisabled(savedThrottler);
    if (savedPercent)
      [defaults setObject:savedPercent forKey:speedKey];
    else
      [defaults removeObjectForKey:speedKey];
    // The fixture drains queued gain updates before restoring Base/CurrentRun
    // speed, volume, master-mute and mute-on-fast-forward settings in tearDown.
  }
}

- (void)testVolumeCanChangeWithoutALiveSoundStream
{
  // A failed setup must leave a live game or uninitialized host untouched.
  if (!_fixture)
    return;
  _fixture->system.SetSoundStream(nullptr);
  _fixture->sound = nullptr;
  [DOLConfigBridge setAudioVolume:42];
  [TVEmulationBridge setAudioVolumePercent:23];
  [self waitForAudioUpdates];
  XCTAssertTrue(_fixture->system.GetSoundStream() == nullptr);
  XCTAssertEqual([DOLConfigBridge audioVolume], 23);
}
@end
