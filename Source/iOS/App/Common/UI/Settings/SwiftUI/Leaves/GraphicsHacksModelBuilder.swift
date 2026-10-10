// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Pure: snapshot in, changes out (it cannot write). Descriptions are the captions the hand-built screen showed.
enum GraphicsHacksModelBuilder {
  static func make(state: GraphicsHacksState, apply: @escaping (GraphicsHacksChange) -> Void) -> MenuModel {
    let skipDuplicateEnabled = !state.immediateXfb && state.viSkipMode == 0
    let deferEfbEnabled = !(state.skipEfbToRam && state.skipXfbToRam)
    let bbox = state.backendSupportsBbox

    let general = MenuSection(id: "general-hacks", header: L("General Hacks"), items: [
      SettingsRow.cycle("texture-cache", L("Texture Cache Accuracy"), [(L("Safe"), 512), (L("Default"), 128), (L("Fast"), 0)], state.textureCacheSamples,
            L("Adjusts how strictly the GPU tracks texture updates from RAM. Safer is slower but avoids garbled text in some games."), set: { apply(.textureCacheSamples($0)) }),
      SettingsRow.toggle("bbox", L("Bounding Box Emulation"), state.bboxEnabled,
             bbox ? L("Emulates GameCube/Wii bounding-box tests on the GPU. Required by some games; leave off unless needed.")
                  : L("The current graphics backend does not support bounding box emulation on this device."),
             enabled: bbox, set: { apply(.bboxEnabled($0)) }),
      SettingsRow.cycle("bbox-sync", L("Bounding Box Sync"), [(L("Latched"), 0), (L("Force Sync"), 1)], state.bboxSyncMode,
            L("How iCube delivers bounding-box values. Latched serves a 1-frame-stale snapshot with no CPU stall (faster). Force Sync blocks for exact same-frame values — try it if a game's bbox-driven effects (some 2D/UI culling) look wrong."),
            enabled: state.bboxEnabled && bbox, set: { apply(.bboxSyncMode($0)) }),
      SettingsRow.toggle("efb-access", L("Enable EFB Access"), state.efbAccess,
             L("Lets the CPU read back the framebuffer. Required by some effects but costly; many games run fine and faster with it off."), set: { apply(.efbAccess($0)) }),
      SettingsRow.toggle("skip-efb-ram", L("Skip EFB Copy to RAM"), state.skipEfbToRam,
             L("Keeps embedded-framebuffer copies on the GPU instead of system RAM. Faster; breaks a few effects. Recommended on."), set: { apply(.skipEfbToRam($0)) }),
      SettingsRow.toggle("skip-xfb-ram", L("Skip XFB Copy to RAM"), state.skipXfbToRam,
             L("Keeps the external framebuffer on the GPU. Faster; can break games that read the final image."), set: { apply(.skipXfbToRam($0)) }),
      SettingsRow.toggle("immediate-xfb", L("Immediate XFB"), state.immediateXfb,
             L("Presents frames the moment they're drawn — lower latency, but can cause flicker or tearing in some games."), set: { apply(.immediateXfb($0)) }),
      SettingsRow.toggle("copy-efb-scaled", L("Copy EFB Scaled"), state.copyEfbScaled,
             L("Copies the framebuffer at the higher internal resolution rather than native. Keeps upscaled detail; recommended on."), set: { apply(.copyEfbScaled($0)) }),
      SettingsRow.toggle("early-xfb", L("Early XFB Output"), state.earlyXfbOutput,
             L("Outputs the frame earlier in the pipeline for lower latency. Recommended on; turn off if a game shows glitches."), set: { apply(.earlyXfbOutput($0)) }),
      SettingsRow.toggle("skip-duplicate-xfb", L("Skip Duplicate XFBs"), state.skipDuplicateXFBs,
             skipDuplicateEnabled ? L("Avoids re-presenting identical frames, saving GPU work. Recommended on.")
                                  : L("Unavailable while Immediate XFB or VI Skip is enabled — duplicate frames are already handled."),
             enabled: skipDuplicateEnabled, set: { apply(.skipDuplicateXFBs($0)) }),
      SettingsRow.toggle("efb-format-changes", L("Emulate EFB Format Changes"), state.efbFormatChanges,
             L("Emulates pixel-format changes some games rely on. Needed for correct colors/effects in those games; small cost."), set: { apply(.efbFormatChanges($0)) }),
      SettingsRow.toggle("vertex-rounding", L("Vertex Rounding"), state.vertexRounding,
             L("Rounds vertex positions to reduce seams between tiles at higher resolutions. Only helps above 1x; leave off at 1x."), set: { apply(.vertexRounding($0)) }),
      SettingsRow.toggle("force-progressive", L("Force Progressive Scan"), state.forceProgressive,
             L("Forces 480p output where games allow it, for a cleaner image."), set: { apply(.forceProgressive($0)) }),
      SettingsRow.toggle("defer-efb-copies", L("Defer EFB Copies"), state.deferEfbCopies,
             deferEfbEnabled ? L("Batches framebuffer copies to reduce overhead. Faster in most games; recommended on.")
                             : L("Unavailable while both EFB and XFB copies stay on the GPU — there is no RAM copy to defer."),
             enabled: deferEfbEnabled, set: { apply(.deferEfbCopies($0)) }),
      SettingsRow.cycle("vi-skip", L("VI Skip Mode"), [(L("Off"), 0), (L("On"), 1), (L("Auto"), 2)], state.viSkipMode,
            L("Skips video-interrupt frames to gain speed. Auto is the safe choice; On is more aggressive but can cause flicker."), set: { apply(.viSkipMode($0)) }),
      SettingsRow.toggle("fast-texture-sampling", L("Fast Texture Sampling"), state.fastTextureSampling,
             L("Uses faster, less precise texture sampling. Small speed win; rarely causes minor texture artifacts. Recommended on."), set: { apply(.fastTextureSampling($0)) }),
      SettingsRow.toggle("fast-math", L("Fast Math (Metal Shaders)"), state.fastMath,
             L("Lets Metal shaders use fast, relaxed-precision math. Can speed up the GPU; may cause subtle rendering differences."), set: { apply(.fastMath($0)) }),
      SettingsRow.toggle("compute-efb-xfb", L("Use Compute for EFB/XFB"), state.useComputeEfbXfb,
             L("Native-Metal compute acceleration for EFB/XFB. Experimental GPU perf knob; OFF by default. Applies on next launch."), set: { apply(.useComputeEfbXfb($0)) }),
      SettingsRow.toggle("compute-vertex-decode", L("Use Compute for Vertex Decode"), state.useComputeVertexDecode,
             L("Offload vertex decoding to a Metal compute shader (CPU→GPU). Experimental — currently only position-only-float formats use the GPU path (others fall back to CPU), so most games see little change yet. OFF by default. Applies on next launch."), set: { apply(.useComputeVertexDecode($0)) }),
      SettingsRow.toggle("no-mipmapping", L("No Mipmapping (iOS)"), state.noMipmapping,
             L("Disables mipmaps. Saves a little memory/bandwidth but makes distant textures shimmer. Leave off normally."), set: { apply(.noMipmapping($0)) }),
      SettingsRow.toggle("gpu-efb-peek", L("GPU EFB Peek Resolve"), state.gpuEfbPeekResolve,
             L("Experimental: resolves EFB peek reads on the GPU instead of a CPU readback. May reduce CPU-thread stalls for games that read the framebuffer; OFF by default. Verify visuals per game."), set: { apply(.gpuEfbPeekResolve($0)) }),
    ])
    let interlace = MenuSection(id: "interlace", items: [
      SettingsRow.toggle("vi-decimate-interlace", L("Interlaced Field Decimation"), state.viDecimateInterlace,
             L("Skips every other interlaced field for higher FPS. May reduce temporal resolution or cause flicker in some games."), set: { apply(.viDecimateInterlace($0)) }),
    ])
    return MenuModel(sections: [general, interlace])
  }
}
