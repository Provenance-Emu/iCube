# Play toolbar and quick-save history

## Approval and intent

The owner approved the interactive mockup on October 20: “way better,” with the explicit condition that it must not be too tall in iPhone or iPad portrait. The mockup lives under `.superpowers/brainstorm/96575-1792540617/content/toolbar-save-history.html` (local, ignored). The owner subsequently approved the full implementation plan and said “Yes, continue with subagents.” This document records that direction. Actual screenshots, not only behavioral assertions, are required before shipping.

The current toolbar is an undifferentiated strip of ambiguous icons. More sometimes contains only Pause Menu. Save/load arrows and a bare slot number obscure what will happen. The owner wants a styled custom toolbar with titles, clearer save/load actions, occupied-state thumbnails, and a chronological quick-save alternative to numbered slots.

## Approved interaction

- Direct **Pause** opens the full pause menu in one tap and acquires its existing pause token. No intermediate More menu. Resume remains available in the pause menu.
- Wide toolbar: **Pause, Save, Load, Saves**, then **Fast Forward, Audio, Controller, Display, Shaders, Hide**. Use symbols plus visible titles. Shaders uses a layered-image symbol and its word label.
- Compact portrait: one primary row **Pause, Save, Load, Saves**, with a labeled **Options** entry for secondary controls. Hide may be a small explicit chevron action with an accessibility label. No second persistent toolbar row, sideways scrolling requirement, clipped titles, or reduction below 44pt touch targets.
- Controller contains **On-screen controls**, layout editing, controller selection/setup, and explicitly labeled Wii pointer options. Remove the ambiguous finger icon from the main bar.
- Preserve screenshot, performance, audio effects, shader parameters, instant replay, overscan and enabled Skylanders destinations under the relevant labeled menu or Options. Do not silently lose conditional actions.
- Audio exposes functional Mute and volume. The runtime gain defect is a separate release blocker and must be fixed and verified in the real backend path.
- Opening a popover/sheet holds toolbar visibility. Dismissing/replacing it preserves the existing handoff and pause ownership. Settings must never unexpectedly resume the game.

## Save browser

Two clearly labeled modes: **Quick-save history** and **Classic slots**. History is newest first, with thumbnail, timestamp, latest-manual badge, a separate automatic-resume card, and a Keep action. Classic slots show **occupied / empty**, thumbnail where available, slot number, and timestamp. Missing thumbnails use a labeled placeholder.

Selecting a card only selects it. Separate persistent **Save new state / Save to slot N** and **Load selected** actions say what will happen. Load is disabled for empty or incompatible states. Replacing an occupied classic slot requires confirmation. The browser scrolls inside the available height, keeping primary actions visible, and reflows for portrait and large text.

Owner-defined Quick Load behavior: load **the latest manually made state**, otherwise **the automatic boot/resume state**. Never silently skip a newer incompatible manual state and load an older one; show its incompatibility and offer the browser. No available state yields an honest empty-state message.

## Persistence and safety decisions

These are implementation choices supporting the approved mockup:

- Filename integration ruling: the existing shared PVSyncRules classifier accepts numbered-state extensions but rejects `.sav` payloads. Use `.s01` with a unique history basename so payload, JSON and PNG remain in the existing sync pipeline without dependency changes. Recognize prior development `.quick-{UUID}.sav` files for local compatibility; all new writes use `.s01`.
- New quick saves use unique immutable `{gameID}.quick-{UUID}.s01` files under the existing StateSaves directory, with existing metadata/PNG sidecars. They never overwrite numbered slots, Continuity slot 99, or `{gameID}.auto`.
- Preserve all existing states and their current filenames. History becomes the new Quick Save behavior; Classic slots remain an explicit available mode, and its saved selection persists. Existing numbered manual states remain eligible for latest-manual Quick Load, using their recorded save time or file modification time.
- Retain **10 unkept history saves per game**. Kept entries never rotate. Prune only recognizable history files with valid identifying metadata, only after a new state and metadata commit successfully. A failed save, failed metadata write, app restart, scan, or interrupted operation must never prune a previous good state. Cleanup failure is reported without describing the save as lost.
- Store backward-compatible optional history/keep metadata. Old sidecars decode normally. Automatic and classic saves are outside rotation. Reuse existing sync discovery; verify new names and sidecars are included. Do not claim real-device or Provenance convergence from filename acceptance alone.
- Serialize through SaveStateService's existing save queue. Capture authoritative game/session identity before scheduling; the bridge validates it under the core state guard. No stale request may write a replacement session. Capture/publish thumbnails using the existing session-aware pipeline.
- Modded boots retain explicit classic-slot behavior until history can distinguish the mod identity reliably; automatic vanilla-state fallback remains forbidden. Explain the fallback in the UI rather than loading an unrelated state.
- No Dolphin save-format change and no new C++ core behavior. A checked arbitrary-path snapshot bridge may reuse the already-exported SaveAsWithResult API.

## Visual and platform constraints

Use existing iCube fonts, colors, spacing, focus and motion tokens. A toolbar may be at most **80pt high excluding safe-area inset** at standard Dynamic Type; compact portrait must fit one control row. At accessibility text sizes, preserve readable labels and reachable actions rather than enforcing the numeric height by clipping.

The browser must fit iPhone portrait/landscape, iPad portrait/landscape and split width. Use available geometry/safe area, not iPad model names. Save actions remain reachable with touch, VoiceOver, keyboard and a connected controller. tvOS retains its full-screen pause presentation; shared history policy and save browser must support remote focus and Back.

## Release acceptance

1. Policy/file tests: latest manual vs newer auto, no state, incompatible latest, legacy slots, 10-entry rotation, kept exclusion, failed saves, metadata failure, foreign files, session changes, and modded fallback.
2. Real backend mute test: production volume setters change DSP output/gain, including mute, restore, clamping and no active stream.
3. Rendered iPhone portrait and iPad portrait checks require visible labels, nonoverlap, usable touch targets, compact toolbar height, and visible browser actions; inspect screenshots. Also check landscape and large text.
4. Physical iPad: real game Pause → Exit → Cancel twice; actual mute/unmute; Save/Load only in a disposable/test session so existing progress is preserved.
5. Full hosted suite, design/localization checks, both App Store archives, optimized startup-metadata guard, core stale-content guard, signature/version validation, matching crash symbols, and both ASC processing results.

No measured FPS improvement, universal hardware acceptance, full cross-app metadata convergence or App Store submission readiness is implied by this UI change.
