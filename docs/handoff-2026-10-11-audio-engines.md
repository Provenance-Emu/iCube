# Handoff: audio engines (CoreAudio + AVAudioEngine, filters, 5.1, spatial, microphones)

Written 2026-10-11 on branch `claude/icube-audio-engine-809825`. Spec:
`docs/superpowers/specs/2026-10-11-icube-audio-engines-design.md` (its audit table is the "why").

## What changed

**Core (`Source/Core/AudioCommon`)**
- `AudioDSPChain.{h,cpp}`: the echo / 3-band EQ / bitcrusher / gain chain both backends run. Real-time
  safe (atomics, try_lock pickup, no allocation after `Configure`). Reads `MAIN_AUDIO_FX_*` from
  `Core/Config/iOSSettings.h`. gtest: `Source/UnitTests/AudioCommon/AudioDSPChainTest.cpp`.
- `CoreAudioSoundStream.mm` (was `.cpp`): stereo int16, or 6 × float32 (`MPEG_5_1_A`) when
  `MAIN_DPL2_DECODER` is on and the route offers ≥ 6 channels. Software volume. Handles interruption,
  route change (rebuild only when the channel capability changes) and media-services reset.
- `AVAudioEngineSoundStream.mm`: three graphs (stereo / spatial / discrete 5.1) picked from the route
  in `chooseMode()`. Pause keeps the graph (`[engine pause]`); resume restarts and re-`play`s nodes.
  Pooled `AVAudioPCMBuffer`s, 512-frame chunks, named user-interactive feeder thread. Audio Unit chain
  persisted in `MAIN_AUDIO_AU_CHAIN` (`type:sub:manu|bypass|base64(fullState)`), restored on every
  build. Head tracking: `listenerHeadTrackingEnabled` (iOS/tvOS 18+), `CMHeadphoneMotionManager` on
  iOS 17.
- `IOSAudioInput.{h,mm}`: RemoteIO input-only capture with a linear resampler, one per emulated mic,
  built around a shared `Impl` so a late permission/route block never touches a destroyed device.
  `IOSAudioSession.{h,mm}`: route queries, output-channel requests, and the microphone hook the app
  registers (`AudioSessionManager`) to flip the category to PlayAndRecord.
- `EXI_DeviceMic.cpp` compiles on iOS (`Core/CMakeLists.txt`) with an `IPHONEOS` path;
  `Microphone.cpp` (Wii Speak / Logitech) likewise. `EXI_Device.cpp` creates the mic when either
  cubeb or iOS is available.

**App (`Source/iOS/App`)**
- `ConfigAudio{State,ModelBuilder,View}.swift`: new Audio screen (see spec §5). `ConfigAudioSync`
  is the one place that reads/writes the bridge; `AudioEffectsSheet` (in `AudioEffectEditors.swift`)
  reuses it for the in-game sheet. `CoreAudioDSPEditor` and the `ca_fx_*` UserDefaults replay are gone;
  `DOLConfigBridge.migrateLegacyAudioEffectDefaults` moves old values into Config once at launch.
- `AudioFXBridge` is now read-only state + plug-in chain + microphone permission.
  `AudioSessionManager` owns the category (Playback / SoloAmbient / PlayAndRecord).
- GameCube: `Microphone in Slot B` (`MAIN_SLOT_B`). Wii: Wii Speak emulate / mute / volume.
  `RemapGroup.gamecube` gained the Microphone group (PadGroup 6) so a pad button can be bound.
- `Info.plist`: `NSMicrophoneUsageDescription`, `NSMotionUsageDescription`.
- Touch overlay (2026-10-12): the GameCube pad has a `gcMicrophone` group, a pill labelled MIC
  stacked above Start, shown only while `MAIN_SLOT_B` holds the Microphone
  (`TouchOverlayDefaults.shown`). It writes `BUTTON_MIC = 22` (`ButtonType.h`, mirrored in
  `TCButtonType.swift`, registered in `Touchscreen.mm` and `StateManager.cpp`; `GetButtonPressed`
  uses `.at()`, so an unregistered id would throw). The bundled `GCPad/Touchscreen.ini` binds
  `Microphone/Button`; for a mapping the user kept from before, `assignTouchscreenToGCPort`
  (`TVControllerMappingBridge.mm`) binds the empty Microphone control to `Button 22` and leaves
  every other binding alone. Delta skins have no microphone input; a skin user binds a pad button.

## Traps

- **The core is built without ARC.** `AudioCommon/CMakeLists.txt` turns `-fobjc-arc` on per file for
  the four `.mm` audio sources; their constructors/destructors are defined in the `.mm` so member
  lifetimes are managed. Keep that pattern for any new ObjC++ in the core.
- `ShouldUseDPL2Decoder()` (upstream) also demands DSP LLE. The iOS backends read
  `MAIN_DPL2_DECODER` directly on purpose (see spec §3).
- `MAIN_AUDIO_LATENCY` is dead on iOS (WASAPI/OpenAL only). The real knobs are
  `MAIN_AUDIO_BUFFER_SIZE`, `MAIN_AUDIO_FILL_GAPS`, `MAIN_AUDIO_PRESERVE_PITCH`.
- Dolphin ships Wii Speak **muted** (`MAIN_WII_SPEAK_MUTED` default true); the Wii screen's "Mute
  Wii Speak" toggle is what makes it capture.
- Microphones are iOS only; tvOS has no app-accessible mic (`IOSAudioInput::IsSupported()` is
  false, the settings rows are `#if os(iOS)`).

## Verification done / still owed

- Done: an independent review of the backends (threading, ARC, Core Audio use); its two crash
  findings (feeder completions capturing the stack, a microphone open/close race) and the medium
  ones are fixed in `fix(audio): review fixes for the iOS backends`.
- Done: `AudioDSPChainTest` (7 tests) compiled and run standalone against the main checkout's gtest;
  every changed core TU syntax-checked against the simulator compile database (with `-fobjc-arc` for
  the `.mm` files); `check_localized_keys.py --check` and `icube_config_lint.py` show no new findings.
- Owed (device): both backends on iPhone speaker, AirPods (spatial, head turn), Apple TV over HDMI to a
  5.1 receiver, pause/resume and a phone call on each backend, GC mic in Mario Party 6, Wii Speak in
  Monster Hunter Tri, and the overlay's MIC button in Mario Party 6 (it only appears with
  "Microphone in Slot B" on).
