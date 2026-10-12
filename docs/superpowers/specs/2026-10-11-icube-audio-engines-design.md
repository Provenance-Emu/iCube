# iCube audio engines: finish AVAudioEngine, filters on both backends, surround, spatial, microphones

Written 2026-10-11. Scope: `Source/Core/AudioCommon` (iOS backends), the microphone devices under
`Source/Core/Core`, `Source/iOS/App/Common/Audio`, the Audio / GameCube / Wii settings leaves and
their bridge methods.

## Goal

Both iOS audio backends work end to end on iOS and tvOS, share one set of filters, output surround
to a 5.1 route (HDMI on Apple TV, or an adapter) and spatial audio to headphones, and the GameCube
microphone and Wii Speak capture from the device microphone on iOS. The Audio settings screen
describes what each option really does.

## Audit findings that drive the design

| # | Finding | Where |
|---|---------|-------|
| 1 | Pause then resume kills AVAudioEngine audio for good. `SetRunning(false)` (every core pause) tears the engine down; `SetRunning(true)` only restarts the feeder thread, which finds no engine and returns forever. | `AVAudioEngineSoundStream.mm` |
| 2 | Every route change rebuilds the engine and clears the AUv3 chain, so plugging in headphones silently drops the user's effects. Nothing persists the chain between sessions. | same |
| 3 | HRTF renders six sources even on the built-in speaker or HDMI. There is no discrete 5.1 output on either backend. | both backends |
| 4 | Head tracking uses `CMMotionManager` (the phone's attitude), so the sound field turns with the device, not the head. | `AVAudioEngineSoundStream.mm` |
| 5 | The surround decoder runs at a fixed 256-frame block, below the lowest quality the Mixer uses (512), and six `AVAudioPCMBuffer`s are allocated per 5 ms. Node volume is reset to 1.0 by every rebuild. | same |
| 6 | CoreAudio filter parameters are plain fields written from the main thread while the render callback reads them. `setDelayMs` resizes the delay vectors under the callback (crash risk). | `CoreAudioSoundStream.cpp` |
| 7 | The CoreAudio backend handles neither interruptions nor media-services reset. | same |
| 8 | The filter chain and its persistence are CoreAudio only: `ca_fx_*` UserDefaults replayed from `EmulationScreen` when the backend string is `CoreAudio`, and the editor compiles on iOS only (SwiftUI `Slider`). | `AudioEffectEditors.swift`, `EmulationScreen+TouchAndMotion.swift` |
| 9 | "Enable Audio Stretching" and "Stretch Latency" write `MAIN_AUDIO_LATENCY`, which only WASAPI and OpenAL read. The Mixer's real knobs (`MAIN_AUDIO_BUFFER_SIZE`, `MAIN_AUDIO_FILL_GAPS`, `MAIN_AUDIO_PRESERVE_PITCH`) are not exposed. | `ConfigAudioModelBuilder.swift`, `DOLConfigBridge.mm` |
| 10 | Microphones cannot work: `ENABLE_CUBEB` is off for iOS, so `EXI_DeviceMic.cpp` is not compiled and `Microphone.cpp` (Wii Speak, Logitech) is the empty stub. No usage description, no permission request, no session category change, no UI for the slot or the device. | `CMakeLists.txt`, `Core/CMakeLists.txt` |
| 11 | The session category is applied once at launch, so toggling "Use Mute Hardware Switch" does nothing until relaunch. tvOS posts `DOLSuggestAudioBackend`, which nothing observes. | `AudioSessionManager.mm` |
| 12 | `MAIN_AUDIO_USE_COMPUTE_MIXER` is never read. | config lint |

## Design

### 1. One DSP chain for both backends (`AudioCommon/AudioDSPChain.{h,cpp}`)

Platform-neutral C++ (so it gets a gtest). Processes interleaved float frames of N channels in
place: echo (time, feedback, fixed 30 % wet), 3-band EQ (150 Hz low shelf, 1 kHz peak, 6 kHz high
shelf), bitcrusher (bits, hold), then master gain. Real-time safe:

- parameters are `std::atomic`; biquad coefficients are double-buffered and flipped with an atomic
  index, state is reset on the render thread when the flip is seen;
- delay lines are allocated once at `Configure(sample_rate, channels)` for the 2000 ms maximum and
  the active length is an atomic; no allocation after that;
- `IsActive()` lets a backend skip the int16 → float → int16 round trip when nothing is enabled and
  gain is unity (bit-identical output, as today).

Settings live in Config (new keys in `iOSSettings.{h,cpp}`, section `iOS`):
`MAIN_AUDIO_FX_DELAY_ENABLED/MS/FEEDBACK`, `MAIN_AUDIO_FX_CRUSH_ENABLED/BITS/DOWNSAMPLE`,
`MAIN_AUDIO_FX_EQ_ENABLED/LOW_DB/MID_DB/HIGH_DB`. The chain refreshes itself from a
`Config::AddConfigChangedCallback`, so the UI only writes Config and nothing replays UserDefaults.
`DOLConfigBridge` migrates the old `ca_fx_*` UserDefaults into Config once and removes them.

### 2. CoreAudio backend (RemoteIO)

- `CoreAudioSoundStream.cpp` becomes `.mm` so it can observe `AVAudioSession`.
- Output format is chosen at build: if surround is on and the route's
  `maximumOutputNumberOfChannels >= 6`, ask for six channels and, when granted, render 6 × float32
  from `Mixer::MixSurround` with channel layout `MPEG_5_1_A` (L R C LFE Ls Rs, the Mixer's order).
  Otherwise stereo int16 from `Mixer::Mix`.
- The render callback runs the shared DSP chain and a software volume gain (RemoteIO ignores the
  HAL volume parameter on iOS).
- Observers: interruption began → stop the unit; ended with ShouldResume → start it if the stream
  should be running; route change that alters the channel count → rebuild under a mutex; media
  services reset → rebuild.
- `MaximumFramesPerSlice` 4096 so a 6-channel route cannot overflow the slice.

### 3. AVAudioEngine backend

Three graph modes, picked from the live route when the engine is built and re-picked only when a
route change moves between them:

| Mode | When | Graph |
|------|------|-------|
| Discrete 5.1 | surround on, route offers ≥ 6 channels | one player node, 6-ch float → FX → main mixer → output at 6 ch |
| Spatial | surround on, spatial on, route is headphones / Bluetooth | six mono player nodes at the 5.1 positions → `AVAudioEnvironmentNode` (HRTF, `outputType = .auto`) → FX → main mixer |
| Stereo | everything else | one stereo player node → FX → main mixer |

Fixes and changes:

- Pause: `SetRunning(false)` stops the feeder and pauses the engine; `SetRunning(true)` starts the
  engine again, re-arms the player nodes and restarts the feeder. The graph is torn down only in the
  destructor or for a mode change.
- Configuration changes (`AVAudioEngineConfigurationChangeNotification`) restart the engine in
  place; route changes rebuild only when the mode or channel count differs. Both run under
  `m_engine_mutex`; the feeder skips a group while the engine is not running.
- Head tracking: `listenerHeadTrackingEnabled` on iOS 18 / tvOS 18 and later; on iOS 17 a
  `CMHeadphoneMotionManager` drives `listenerAngularOrientation` (needs `NSMotionUsageDescription`).
  `CMMotionManager` is removed.
- Feeder: 512-frame chunks, a pool of reusable `AVAudioPCMBuffer`s per node (no per-chunk
  allocation), named thread with user-interactive QoS, surround block size from
  `MAIN_DPL2_QUALITY`, volume on `mainMixerNode.outputVolume` (survives rebuilds).
- AUv3 chain: `MAIN_AUDIO_AU_CHAIN` stores `type:sub:manu|bypass|base64(fullState)` entries;
  restored after every build, saved on add / remove / move / bypass and when a plug-in's view is
  dismissed. Chain edits take `m_engine_mutex`.

Surround decoding on iOS reads `MAIN_DPL2_DECODER` directly instead of `ShouldUseDPL2Decoder()`
(which also requires DSP LLE). The decoder is a FreeSurround upmix of whatever stereo the DSP
produces; with HLE it still gives a usable 5.1 field, with LLE it is the game's real DPL2 encode.
The setting text says so.

### 4. Microphones (iOS only; tvOS has no app-accessible microphone)

- `AudioCommon/IOSAudioInput.{h,mm}`: a capture stream (RemoteIO, input bus only) that delivers
  mono int16 at a requested rate through a linear-interpolation resampler, one instance per client.
  Starting it requests record permission through `AVAudioApplication` and asks the app, through a
  registered hook, to move the session to `PlayAndRecord` while any input stream is open.
- `EXI_DeviceMic.cpp` and `Microphone.cpp` get an `IPHONEOS` path beside the cubeb one; CMake
  compiles the EXI mic on iOS; `EXI_Device.cpp` creates it when either backend exists.
- `AudioSessionManager` owns the category: `PlayAndRecord` + `defaultToSpeaker` +
  `allowBluetoothA2DP` while a microphone is open, the playback category otherwise. It also
  re-applies the category when the mute-switch setting changes and drops the unobserved
  tvOS notification.
- `Info.plist` gains `NSMicrophoneUsageDescription` and `NSMotionUsageDescription`.
- UI: GameCube leaf gets "Microphone in Slot B" (`MAIN_SLOT_B` Microphone / None, boot-time). Wii
  leaf's USB / SD section gets "Emulate Wii Speak", "Mute Wii Speak" and "Wii Speak Volume"
  (-50 … 50 dB). The GameCube remap screen gets the "Microphone" button group (PadGroup 6).

### 5. Audio settings screen

Sections, in order: Output (backend, volume), Surround & Spatial (surround toggle, quality,
spatial-on-headphones, head tracking, a caption with the live route and channel count), Effects
(echo, EQ, bitcrusher as engine rows; the Audio Unit plug-in editor stays an iOS-only custom row
under AVAudioEngine), Timing (buffer size 16 … 200 ms, fill gaps, preserve pitch), Misc (mute on
speed-limit off; the mute-switch row is iOS only), Microphone (iOS: permission state with an action
that requests or opens Settings).

Removed: the stretch rows and their bridge methods, the "AVAudioEngine is in development"
confirmation, `MAIN_AUDIO_LATENCY` from the reset list (replaced by the real keys).
`MAIN_AUDIO_USE_COMPUTE_MIXER` is deleted (never read).

## Testing

- `AudioDSPChainTests` (gtest, platform-neutral): bypass is bit-identical, gain scales, bitcrusher
  quantises, echo repeats at the configured delay, parameter changes never allocate.
- Swift: `ConfigAudioModelBuilderTests`, `ConfigGameCubeModelBuilderTests`,
  `ConfigWiiModelBuilderTests`, `RemapModelTests` updated for the new rows; `check_localized_keys`
  and `icube_config_lint` stay green.
- Device checklist (owner): both backends on iPhone speaker, AirPods (spatial, head turn), HDMI
  from Apple TV (5.1 on the receiver), pause / resume and a phone call on each backend, GC mic in
  Mario Party 6 or Karaoke Revolution, Wii Speak in Monster Hunter Tri's loudness meter.
