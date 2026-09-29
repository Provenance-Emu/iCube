# Controller Hub Phase 1 — handoff (2026-09-28)

Plan: docs/superpowers/plans/2026-09-28-controller-hub-phase1-foundation.md
Spec: docs/superpowers/specs/2026-09-28-controller-hub-design.md

## Landed
- 967e98d316 refactor(motion): one MotionSettings store with launch-registered ...
- 31df1cfdfa refactor(input): one PointerModeController for the Wii pointer mode
- b808b77123 feat(remap): show bound inputs by their printed labels
- 8aecf922c9 feat(menu): d-pad left/right changes the focused picker
- c553ff0ba6 feat(top-bar): one controller menu, motion debug behind DEBUG

## Device checklist (iPhone 16 Pro Max, a Wii title with the touch overlay)
1. Top bar controller menu shows Pointer, Recenter Pointer, Show/Hide, On-Screen Style, Controller Settings…
2. Pointer → Gyro: cursor starts centered on how the phone is held; Recenter re-centers it.
3. Pointer → Touch – Drag from the top bar, then from Settings → Controllers: the live pad follows both (no restart).
4. Settings → Advanced Motion: shake detection shows ON; turn it off, boot a Wii game, it stays off.
5. Customize Buttons…: rows read "A", "Left Stick ↑", "RB" (Xbox) / "✕", "R1" (DualSense), not `Button A`.
6. With a pad, in any MenuScreen list with a picker: d-pad right/left changes it one step per press.
7. Top bar no longer has "Motion Controls"; Release build has no Motion Debug anywhere.

## Next
Phase 2 plan: the hub (ControllerHubViewModel + ControllerHubModelBuilder, wired into the pause menu,
Settings and "Controller Settings…"), which also fixes the Profiles / Customize Buttons scroll lockup.
Open product question for Phase 2: `dsu_role` default ("receiver" in ControllersRootView vs "sender" in TVLibraryView).
