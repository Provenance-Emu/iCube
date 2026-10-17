# MetalFX spatial upscaling at Native (1x): prototype results

Date: 2026-10-17. Commits `a6098f82b6` (core) and `a501a1aa00` (app).

**Verdict:** merge behind an Experimental toggle, default Off, and don't present it as a power saver.
For lower-power devices, 2x internal resolution is the cheaper sharp image. Keep `gpuFrameMs` and
`gpuUpscaleMs` whatever happens to MetalFX.

## What was built

- `GFX_MTL_METALFX_SPATIAL_UPSCALE` (off by default; settings key `gfxMetalFXSpatialUpscale`, hot-swappable).
  - When it is on, the internal resolution is 1x, stereo is off and HDR is off, `Presenter::Present` asks
    the backend to upscale the XFB to the picture rect before the backbuffer pass opens. Metal runs
    `MTLFXSpatialScaler` (perceptual mode) on its own command buffer.
  - The post-processing blit, the OSD and iCube's shader chain then draw the upscaled picture 1:1.
  - Frame dumps and screenshots use the upscaled picture too.
- UI: a "MetalFX Upscaling" row under Graphics ▸ Enhancements ▸ Internal Resolution, and a
  "Native + MetalFX" step on the pause Upscaling tile.
  - Both appear only where `MTLFXSpatialScalerDescriptor.supportsDevice` passes. The app looks the class
    up at runtime instead of linking MetalFX.
- Built only for iOS devices:
  - The iOS Simulator SDK has no `MetalFX.framework`.
  - Apple TV GPUs don't support MetalFX, and the tvOS slice must not hard-link it.
- `/api/perf/live` gains `gpuFrameMs` and `gpuUpscaleMs`.
  - `gpuFrameMs` is the GPU time of every Metal command buffer, summed per presented frame and averaged
    over 120 presents. Command buffers overlap on the GPU, so this sum overstates busy time. Compare it
    only between settings.
  - `gpuUpscaleMs` is the MetalFX command buffer alone. Treat it as an upper bound on the scaler's cost:
    the buffer is committed right after the Draw buffer that writes the XFB, so its GPU interval can
    include time spent waiting on that work.

## Measurements

- Device: iPad Pro 12.9" 4th gen (A12Z), 2732×2048 screen, iCube DEV (Debug app, Release core), Metal
  backend, thermal state nominal.
- Method: each setting replays the same stretch from one save state, in two interleaved rounds. Ten
  samples per setting, taken after a 9 s settle.
- Screenshots: one save state, then step one frame, then capture the real display with
  `devicectl device capture screenshot`. All four settings show the same emulated frame.

| Scene | Setting | gpuFrameMs (sum) | MetalFX cmdbuf | fps |
|---|---|---|---|---|
| Luigi's Mansion, map screen (30 fps), 640×528 → 2351×1934 | 1x | 4.15 | — | 29.8 |
| | 1x + MetalFX | 16.47 | **6.77** | 29.8 |
| | 2x | 6.76 | — | 29.8 |
| | 3x | 8.62 | — | 29.8 |
| NSMBW, save-data dialog (60 fps), 16:9 → 2732×1537 | 1x | 2.14 | — | 59.9 |
| | 1x + MetalFX | 16.78 | **7.55** | 59.9 |
| | 2x | 5.80 | — | 59.9 |
| | 3x | 8.89 | — | 59.9 |

- For scale, the same scaler setup on an M2 Max (Mac harness, 640×480 → 2731×2048) takes 0.63 ms,
  against 0.12 ms for a bilinear scale. Scaled to the A12Z's GPU that is about 5–7 ms, consistent with
  the device figure.
- Even at the low end (about 5 ms), the scaler costs roughly what 3x adds over 1x, and 3x renders real
  resolution. The verdict doesn't depend on the upper bound.
- The iPhone 16 Pro Max was passcode-locked and wasn't measured.
  - An iPhone picture rect is about 1.7 MP, against 4.5 MP for the iPad's 4:3 rect.
  - Expect roughly 2–3 ms on an A13–A15 phone. This is an estimate, not a measurement.

## Image quality (1:1 crops, iPad)

- **3D (Luigi's Mansion):** MetalFX is clearly crisper than 1x bilinear on the banner lettering and on
  geometry edges.
  - It sharpens the stair-steps on silhouettes rather than resolving them, so the glove's top edge reads
    as harder jaggies.
  - 2x and 3x give genuinely smoother edges.
  - Texture detail is the same in all four, because the textures are native resolution.
- **2D/UI (NSMBW dialog):** the differences are small. MetalFX is slightly crisper than 1x, with slightly
  darker glyph outlines.
  - No ringing is visible on the striped background or the gradients. Those stripes are texture
    detail, not dithering.
- **Dithered 480p is untested.** Force 24-bit Color is on by default and suppresses EFB dithering, so
  the case is moot at the default. The settings table has no key for it, so the bench couldn't turn it
  off.
  - 2x and 3x barely differ from 1x, because the UI is fixed-resolution textures.

## Recommendation

- **Don't make it a default, and don't push it as a power saver.** On the A12Z the scaler costs
  5–7.6 ms of GPU per frame (Mac-scaled estimate to device upper bound). That is more than rendering the game at 3x adds over 1x (+4.5 to +6.8 ms
  summed).
  - GameCube/Wii scenes are cheap for a modern GPU at 2x–3x. MetalFX's cost scales with output pixels
    instead, and a full-screen picture is 4–5.6 MP on an iPad.
  - For lower-power devices the cheaper sharp image is 2x internal resolution.
  - The workload is CPU-bound, so the GPU has headroom for 2x anyway.
- If it ships at all, ship it as an opt-in "Experimental" toggle, default off. The case for it is games
  where raising the internal resolution is GPU-expensive (heavy EFB copies or bloom) on phone-sized
  outputs.
  - Measure on an iPhone before deciding.
- Keep `gpuFrameMs`/`gpuUpscaleMs` whatever happens to MetalFX. They are the first GPU timing the bench
  has.

## Reproducing

- Script: `ab.py` (in the session notes) drives the debug API.
  - Pass a LAN token and `DEVICE=<udid>`.
  - It writes one display capture per setting, the frame dumps, and a JSON file of samples.
- A Debug build's bench is loopback-only, and `iproxy -n` over Wi-Fi gets a connection reset. Use one of:
  - a Release build with Perf Test Bench enabled,
  - USB with iproxy,
  - a temporary local patch that reads the LAN token from the launch environment.
