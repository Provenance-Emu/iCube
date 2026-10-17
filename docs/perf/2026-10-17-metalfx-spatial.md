# MetalFX spatial upscaling: prototype results

Date: 2026-10-17. Commits `a6098f82b6`, `70da05ee1f` (core) and `a501a1aa00`, `0d01169258` (app).

**Verdict:** ship it as an opt-in toggle, off by default, that stacks on any Upscaling level. Don't
present it as a power saver or a cheaper alternative to a higher internal resolution:

- On both devices, in both scenes, going up an internal step was cheaper than adding MetalFX, and it
  looked better.
- If "2x doesn't fill my screen" is the complaint, the fix is a higher internal resolution, or Auto
  (fit window).
- Keep `gpuFrameMs` and `gpuUpscaleMs` whatever happens to MetalFX.

## What was built

- `GFX_MTL_METALFX_SPATIAL_UPSCALE` (off by default; settings key `gfxMetalFXSpatialUpscale`,
  hot-swappable). When does it run? When it is on, stereo is off, HDR is off, and the XFB at the
  current internal resolution is smaller than the picture rect on both axes. At any scale where the
  internal picture already meets the screen, it skips itself.
  - `Presenter::Present` asks the backend for an upscaled copy before the backbuffer pass opens.
  - Metal runs `MTLFXSpatialScaler` (perceptual mode) on its own command buffer.
  - The post-processing blit, the OSD and iCube's shader chain then draw the upscaled picture 1:1.
  - Frame dumps and screenshots use the upscaled picture too.
- UI, shown only where `MTLFXSpatialScalerDescriptor.supportsDevice` passes (so never on tvOS or the
  Simulator):
  - a "MetalFX Upscaling" row under Graphics ▸ Enhancements ▸ Internal Resolution;
  - a "MetalFX" toggle tile right after the pause menu's Upscaling tile.
  - The Upscaling ladder stays plain scales.
  - The app looks the class up at runtime instead of linking MetalFX.
- Built only for iOS devices:
  - The iOS Simulator SDK has no `MetalFX.framework`.
  - Apple TV GPUs don't support MetalFX, and the tvOS slice must not hard-link it.
- `/api/perf/live` gains `gpuFrameMs` and `gpuUpscaleMs`.
  - `gpuFrameMs` is the GPU time of every Metal command buffer, summed per presented frame and averaged
    over 120 presents. Command buffers overlap on the GPU, so this sum overstates busy time; NSMBW
    holds 60 fps at a "16 ms" sum. Compare it only between settings.
  - `gpuUpscaleMs` is the MetalFX command buffer alone. Treat it as an upper bound: the buffer is
    committed right after the Draw buffer that writes the XFB, so its interval can include time spent
    waiting on that work.

## "Our 2x isn't really 2x"

The drawable is sized at `screen.scale` (native pixels), and `GFX_EFB_SCALE` multiplies the console's
640×528. The bilinear stretch from the internal picture to the screen picture is therefore:

| Screen picture | 1x | 2x | 3x | 4x |
|---|---|---|---|---|
| iPad Pro 12.9", Luigi's Mansion (~2351×1934) | 3.7× | 1.8× | 1.2× | already covers the screen |
| iPhone 16 Pro Max landscape (~1530×1320) | 2.5× | 1.25× | already covers the screen | already covers the screen |
| iPhone 16 Pro Max portrait (~1200×1000) | 1.9× | already covers the screen | already covers the screen | already covers the screen |

## Measurements

- Devices:
  - iPad Pro 12.9" 4th gen (A12Z), 2732×2048 screen;
  - iPhone 16 Pro Max (A18 Pro), 2868×1320.
- Build: iCube DEV (Debug app, Release core), Metal backend, thermal state nominal.
- Each setting replays the same stretch from one save state (the same state file on both devices), in
  two interleaved rounds. Ten samples per setting, taken after a 9 s settle.
- Values are GPU ms per presented frame: `gpuFrameMs`, with `gpuUpscaleMs` in brackets. "skips" means
  the internal picture already covers the screen picture, so MetalFX didn't run.

| Device / scene | 1x | 1x+MFX | 2x | 2x+MFX | 3x | 3x+MFX | 4x |
|---|---|---|---|---|---|---|---|
| iPad, Luigi's Mansion map (30 fps) | 4.15 | 16.6 (6.8) | 6.8 | 19.0 (7.4) | 8.8 | 22.5 (8.3) | 9.8 |
| iPad, NSMBW dialog (60 fps) | 3.3 | 15.5 (6.5) | 7.5 | 14.9 (5.4) | 8.6¹ | 18.4 (6.7) | 8.5 |
| iPhone landscape, Luigi's Mansion | 3.2 | 12.1 (4.4) | 6.6 | 17.2 (6.0) | 8.7 | skips | 9.0 |
| iPhone portrait, Luigi's Mansion | 2.9 | 9.8 (3.3) | 6.6 | skips | 8.5 | skips | 8.8 |

¹ The measured 11.0 included 2.4 ms of MetalFX left over from the previous setting's window; 8.6 is
with that removed.

- **Stacking never won.**
  - 2x + MetalFX cost about twice as much as plain 3x on every device and scene, and more than 4x.
  - 3x + MetalFX cost about twice as much as 4x.
  - GameCube/Wii scenes are cheap to render: each internal step adds roughly 1–2 ms.
  - MetalFX costs 3–8 ms per frame.
- **The scaler's cost tracks output size, plus some input cost.**
  - On the iPad it ranged 5.4–8.3 ms on a ~4.5 MP output, rising with input in Luigi's Mansion.
  - On the iPhone it was 3.3–6 ms. A18 Pro pays roughly half the A12Z's cost, not the 10× the
    M2 Max harness suggested (0.63 ms for 640×480 → 2731×2048).
- No fps differences at these loads: both games hit their caps at every setting.

## Image quality

1:1 crops of the real display, every column the same emulated frame. Sheets:
`lm-ipad-stack.png`, `nsmbw-ipad-stack.png`, `lm-iphone-landscape-stack.png` in the session notes.

- **MetalFX sharpens; it doesn't resolve.**
  - Banner lettering and geometry edges get crisper than bilinear, and the stair-steps on silhouettes
    get harder.
  - A higher internal resolution adds real edge detail and smoother silhouettes.
  - Texture detail is the same at every setting (native-resolution textures).
- **iPhone landscape, 2x vs 2x + MetalFX:** the 1.25× stretch is small enough that MetalFX's
  improvement is slight. 4x is visibly cleaner.
- **2D/UI (NSMBW):** small differences everywhere; the UI is fixed-resolution textures. MetalFX
  darkens glyph outlines a little. No ringing on the stripes or gradients (texture detail, not dither).
- **Dithered 480p is untested.** Force 24-bit Color is on by default, which removes dithering, so the
  case is moot at the default. The settings table has no key to turn it off.

## UX recommendation

- **A separate MetalFX toggle that stacks on any Upscaling level, not either/or ladder steps.** This is
  what is implemented.
  - Either/or steps ("Native + MetalFX", "2x + MetalFX", …) would double the ladder.
  - They would also mix two kinds of setting on one tile: one sets resolution, the other only filters
    the final stretch.
  - Since MetalFX now skips itself where the internal picture covers the screen, a single toggle
    behaves sensibly at every scale.
- Keep it off by default and hidden where `supportsDevice` is false (tvOS, Simulator, unsupported GPUs).
  Its caption says a higher internal resolution is often cheaper.
- Better for "2x isn't 2x" than MetalFX: make the default internal resolution follow the screen.
  - Auto (fit window), or a per-device default: 4x on large iPads, 3x on phones in landscape.
  - The measured cost of 3x–4x over 2x is 1–3 ms of GPU on these devices, and the emulator is
    CPU-bound.

## Reproducing

- Script: `ab_v2.py` (session notes) drives the debug API.
  - Pass a LAN token and `DEVICE=<udid>`.
  - Each capture reloads slot 9 paused, steps once, checks the frame number, and captures the real
    display with `devicectl device capture screenshot`.
  - Timing samples `/api/perf/live`.
- A Debug build's bench is loopback-only, and `iproxy -n` over Wi-Fi gets a connection reset. Use one of:
  - a Release build with Perf Test Bench enabled;
  - USB with iproxy;
  - a temporary local patch that reads the LAN token from the launch environment. The device runs used
    this; it's not committed.
- Over USB, the iPhone was reachable directly at its link-local address once the bench listened on all
  interfaces.
