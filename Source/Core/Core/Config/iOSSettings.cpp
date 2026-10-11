// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Core/Config/iOSSettings.h"

namespace Config
{
// Main.iOS

const Info<float> MAIN_TOUCH_PAD_OPACITY{{System::Main, "iOS", "TouchPadOpacity"}, 0.50f};
const Info<int> MAIN_TOUCH_PAD_IR_MODE{{System::Main, "iOS", "TouchPadIRMode"}, 2};
const Info<int> MAIN_SELECTED_STATE_SLOT{{System::Main, "iOS", "SelectedStateSlot"}, 1};
const Info<int> MAIN_MUTE_SWITCH_MODE{{System::Main, "iOS", "MuteSwitchMode"}, 0};

const Info<bool> MAIN_AUDIO_FX_DELAY_ENABLED{{System::Main, "iOS", "AudioFXDelayEnabled"}, false};
const Info<int> MAIN_AUDIO_FX_DELAY_MS{{System::Main, "iOS", "AudioFXDelayMs"}, 200};
const Info<float> MAIN_AUDIO_FX_DELAY_FEEDBACK{{System::Main, "iOS", "AudioFXDelayFeedback"},
                                               0.35f};
const Info<bool> MAIN_AUDIO_FX_CRUSH_ENABLED{{System::Main, "iOS", "AudioFXCrushEnabled"}, false};
const Info<int> MAIN_AUDIO_FX_CRUSH_BITS{{System::Main, "iOS", "AudioFXCrushBits"}, 16};
const Info<int> MAIN_AUDIO_FX_CRUSH_DOWNSAMPLE{{System::Main, "iOS", "AudioFXCrushDownsample"}, 1};
const Info<bool> MAIN_AUDIO_FX_EQ_ENABLED{{System::Main, "iOS", "AudioFXEQEnabled"}, false};
const Info<float> MAIN_AUDIO_FX_EQ_LOW_DB{{System::Main, "iOS", "AudioFXEQLowDb"}, 0.0f};
const Info<float> MAIN_AUDIO_FX_EQ_MID_DB{{System::Main, "iOS", "AudioFXEQMidDb"}, 0.0f};
const Info<float> MAIN_AUDIO_FX_EQ_HIGH_DB{{System::Main, "iOS", "AudioFXEQHighDb"}, 0.0f};

const Info<bool> MAIN_AUDIO_SPATIAL{{System::Main, "iOS", "AudioSpatial"}, true};
const Info<bool> MAIN_AUDIO_SPATIAL_HEAD_TRACKING{{System::Main, "iOS", "AudioSpatialHeadTracking"},
                                                  true};
const Info<std::string> MAIN_AUDIO_AU_CHAIN{{System::Main, "iOS", "AudioAUChain"}, ""};

}  // namespace Config
