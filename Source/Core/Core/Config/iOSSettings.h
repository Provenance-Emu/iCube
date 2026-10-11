// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <string>

#include "Common/Config/Config.h"

namespace Config
{
// Main.iOS

extern const Info<float> MAIN_TOUCH_PAD_OPACITY;
extern const Info<int> MAIN_TOUCH_PAD_IR_MODE;
extern const Info<int> MAIN_SELECTED_STATE_SLOT;
extern const Info<int> MAIN_MUTE_SWITCH_MODE;

// Audio filters shared by the CoreAudio and AVAudioEngine backends (AudioCommon/AudioDSPChain).
extern const Info<bool> MAIN_AUDIO_FX_DELAY_ENABLED;
extern const Info<int> MAIN_AUDIO_FX_DELAY_MS;
extern const Info<float> MAIN_AUDIO_FX_DELAY_FEEDBACK;
extern const Info<bool> MAIN_AUDIO_FX_CRUSH_ENABLED;
extern const Info<int> MAIN_AUDIO_FX_CRUSH_BITS;
extern const Info<int> MAIN_AUDIO_FX_CRUSH_DOWNSAMPLE;
extern const Info<bool> MAIN_AUDIO_FX_EQ_ENABLED;
extern const Info<float> MAIN_AUDIO_FX_EQ_LOW_DB;
extern const Info<float> MAIN_AUDIO_FX_EQ_MID_DB;
extern const Info<float> MAIN_AUDIO_FX_EQ_HIGH_DB;

// AVAudioEngine backend: binaural rendering of the decoded surround field on headphone routes, and
// whether the listener follows the user's head.
extern const Info<bool> MAIN_AUDIO_SPATIAL;
extern const Info<bool> MAIN_AUDIO_SPATIAL_HEAD_TRACKING;
// AVAudioEngine backend: the persisted Audio Unit plug-in chain. Entries separated by ';', each
// "type:sub:manu|bypass|base64(fullState)" (see AVAudioEngineSound::SerializeEffectChain).
extern const Info<std::string> MAIN_AUDIO_AU_CHAIN;

}  // namespace Config
