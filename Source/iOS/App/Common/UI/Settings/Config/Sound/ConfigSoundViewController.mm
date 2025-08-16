// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "ConfigSoundViewController.h"

#import "Core/Config/iOSSettings.h"
#import "Core/Config/MainSettings.h"

#import "AudioSessionManager.h"
#import "FoundationStringUtil.h"
#import "LocalizationUtil.h"

#import "Swift.h"

@interface ConfigSoundViewController ()

@end

@implementation ConfigSoundViewController

- (void)viewDidLoad {
  [super viewDidLoad];

  bool stretchingEnabled = Config::Get(Config::MAIN_AUDIO_LATENCY) > 0;

  self.stretchingSwitch.on = stretchingEnabled;
  [self.stretchingSwitch addValueChangedTarget:self action:@selector(stretchingChanged)];

#if !TARGET_OS_TV
  int volume = Config::Get(Config::MAIN_AUDIO_VOLUME);
  self.volumeSlider.value = volume;
#endif
  [self updateVolumeLabel];

#if !TARGET_OS_TV
  self.bufferSizeSlider.value = Config::Get(Config::MAIN_AUDIO_LATENCY);
  self.bufferSizeSlider.enabled = stretchingEnabled;
#endif

  [self updateBufferSizeLabel];

  self.muteSpeedLimitSwitch.on = Config::Get(Config::MAIN_AUDIO_MUTE_ON_DISABLED_SPEED_LIMIT);
  [self.muteSpeedLimitSwitch addValueChangedTarget:self action:@selector(muteSpeedLimitChanged)];

  AudioMuteSwitchMode muteSwitchMode = (AudioMuteSwitchMode)Config::Get(Config::MAIN_MUTE_SWITCH_MODE);
  self.muteModeSwitch.on = muteSwitchMode == AudioMuteSwitchModeObey;
  [self.muteModeSwitch addValueChangedTarget:self action:@selector(muteModeSwitchChanged)];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];

  self.backendLabel.text = CppToFoundationString(Config::Get(Config::MAIN_AUDIO_BACKEND));
}

- (IBAction)volumeChanged:(id)sender {
#if !TARGET_OS_TV
  Config::SetBaseOrCurrent(Config::MAIN_AUDIO_VOLUME, (int)self.volumeSlider.value);
#endif

  [self updateVolumeLabel];
}

- (void)updateVolumeLabel {
  int volume = Config::Get(Config::MAIN_AUDIO_VOLUME);
  self.volumeLabel.text = [NSString stringWithFormat:@"%d%%", volume];
}

- (void)stretchingChanged {
  bool stretchingEnabled = self.stretchingSwitch.on;

#if !TARGET_OS_TV
  // Map to non-zero latency for enabled, else zero
  Config::SetBaseOrCurrent(Config::MAIN_AUDIO_LATENCY, stretchingEnabled ? MAX(1, (int)self.bufferSizeSlider.value) : 0);
  
  self.bufferSizeSlider.enabled = stretchingEnabled;

  // There is a bug on iOS 14+ where a UISlider won't update its appearance when enabled is toggled.
  [self.bufferSizeSlider setNeedsLayout];
  [self.bufferSizeSlider layoutIfNeeded];
#endif
}

- (IBAction)bufferSizeChanged:(id)sender {
#if !TARGET_OS_TV
  Config::SetBaseOrCurrent(Config::MAIN_AUDIO_LATENCY, (int)self.bufferSizeSlider.value);
#endif

  [self updateBufferSizeLabel];
}

- (void)updateBufferSizeLabel {
  int bufferSize = Config::Get(Config::MAIN_AUDIO_LATENCY);
  self.bufferSizeLabel.text = [NSString stringWithFormat:DOLCoreLocalizedStringWithArgs(@"%1 ms", @"d"), bufferSize];
}

- (void)muteSpeedLimitChanged {
  Config::SetBaseOrCurrent(Config::MAIN_AUDIO_MUTE_ON_DISABLED_SPEED_LIMIT, self.muteSpeedLimitSwitch.on);
}

- (void)muteModeSwitchChanged {
  AudioMuteSwitchMode mode;

  if (self.muteModeSwitch.on) {
    mode = AudioMuteSwitchModeObey;
  } else {
    mode = AudioMuteSwitchModeIgnore;
  }

  Config::SetBaseOrCurrent(Config::MAIN_MUTE_SWITCH_MODE, (int)mode);

  [[AudioSessionManager shared] setSessionCategory];
}

@end
