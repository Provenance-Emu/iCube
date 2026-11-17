// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
#import <XCTest/XCTest.h>
#import "../Common/Bridging/DOLConfigBridge.h"

#include <memory>
#include "Common/Config/Config.h"
#include "Common/Config/Layer.h"
#include "Core/Config/MainSettings.h"
#include "Core/Core.h"
#include "Core/System.h"

@interface DOLConfigBridge (ResetKeepsGameSettingsTests)
+ (void)resetGameplayConfigKeys;
@end

namespace
{
/// A game layer that lives in memory only, standing in for the ones a boot adds.
class MemoryLoader final : public Config::ConfigLayerLoader
{
public:
  using Config::ConfigLayerLoader::ConfigLayerLoader;
  void Load(Config::Layer*) override {}
  void Save(Config::Layer*) override {}
};
}  // namespace

/// Reset All Settings is reachable from the pause menu. A key it deleted from the booted game's
/// LocalGame layer was then written out of `GameSettings/<id>.ini` by `Config::Save()`.
@interface ResetKeepsGameSettingsTests : XCTestCase
{
  Config::LayerMap _savedBase;
  BOOL _ownsGameLayers;
}
@end

@implementation ResetKeepsGameSettingsTests
- (void)setUp
{
  [super setUp];
  self.continueAfterFailure = NO;
  const auto base = Config::GetLayer(Config::LayerType::Base);
  XCTAssertTrue(base != nullptr, @"App host must initialize the Base Config layer");
  // Never add or remove game layers under a running game.
  XCTAssertTrue(Core::GetState(Core::System::GetInstance()) == Core::State::Uninitialized);
  XCTAssertTrue(Config::GetLayer(Config::LayerType::LocalGame) == nullptr);
  XCTAssertTrue(Config::GetLayer(Config::LayerType::GlobalGame) == nullptr);
  _savedBase = base->GetLayerMap();
  Config::AddLayer(std::make_unique<MemoryLoader>(Config::LayerType::GlobalGame));
  Config::AddLayer(std::make_unique<MemoryLoader>(Config::LayerType::LocalGame));
  _ownsGameLayers = YES;
}

- (void)tearDown
{
  if (_ownsGameLayers)
  {
    Config::RemoveLayer(Config::LayerType::LocalGame);
    Config::RemoveLayer(Config::LayerType::GlobalGame);
    if (const auto base = Config::GetLayer(Config::LayerType::Base))
    {
      base->DeleteAllKeys();
      for (const auto& [location, value] : _savedBase)
      {
        if (value)
          base->Set(location, *value);
      }
    }
    Config::OnConfigChanged();
  }
  [super tearDown];
}

- (void)testResetKeepsTheBootedGamesSavedAndShippedOverrides
{
  Config::SetBase(Config::MAIN_EMULATION_SPEED, 2.0f);
  Config::GetLayer(Config::LayerType::LocalGame)->Set(Config::MAIN_EMULATION_SPEED, 0.5f);
  Config::GetLayer(Config::LayerType::GlobalGame)->Set(Config::MAIN_FAST_DISC_SPEED, false);

  [DOLConfigBridge resetGameplayConfigKeys];

  XCTAssertFalse(Config::GetLayer(Config::LayerType::Base)->Exists(Config::MAIN_EMULATION_SPEED.GetLocation()),
                 @"Reset must still clear the global value");
  XCTAssertTrue(Config::GetLayer(Config::LayerType::LocalGame)->Exists(Config::MAIN_EMULATION_SPEED.GetLocation()),
                @"Reset must not delete the game's saved override");
  XCTAssertTrue(Config::GetLayer(Config::LayerType::GlobalGame)->Exists(Config::MAIN_FAST_DISC_SPEED.GetLocation()),
                @"Reset must not delete the game's shipped fix");
}
@end
