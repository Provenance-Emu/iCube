# Controller Hub Phase 2 — handoff (2026-09-28)

Plan: docs/superpowers/plans/2026-09-28-controller-hub-phase2-hub.md
Spec: docs/superpowers/specs/2026-09-28-controller-hub-design.md

## Landed
- 98026829b7 fix(input): per-game pointer mode goes through PointerModeController
- ab8c61345d fix(dsu): register the dsu_role default the runtime acts on
- e2e4cf58bb feat(menu): a controller's A pushes a destination row
- 3d188f3f4e feat(controllers): pure Controllers hub model builder
- 036b79f853 refactor(settings): pushable DSU, More Controller Settings and edi...
- 10f15d71af feat(controllers): ControllerHubViewModel and the hub view
- 24d89a413a feat(controllers): the hub from the pause menu and the top bar
- fee5e6edaa feat(settings): More Controller Settings takes the global rows
- 1d384a51b7 feat(settings): Settings → Controllers is the Controllers hub
- 6f7690491b refactor(settings): drop imports ControllersRootView no longer uses
- 72b9ff4038 chore(l10n): catalogue the controller hub strings

## Decisions worth knowing
- `dsu_role` is registered as "sender", what TVLibraryView's "Start DSU Controller" already acted on.
  The DSU client lock is iOS-only. On iOS, a user who enabled the client under the old "receiver"
  display default sees it ON but locked until they pick Receiver.
- Settings-only leftovers live behind the hub's "More Controller Settings" row.
- Show/Hide On-Screen Controls appears only in a game. On-Screen Style lasts for the session.

## Device checklist

iPhone 16 Pro Max, with an Xbox or DualSense pad and a Wii title with the touch overlay:
1. The pause menu's Controllers, the top bar's Controller Settings… and Settings → Controllers all show
   the same hub:
   - Players, On-Screen Controls, Connected Devices, More Controller Settings, Help.
   - Unbound ports are under "Show All Ports".
2. With the pad, move to a player row and press A: RemapPlayerView is pushed. B returns to the hub.
   B again closes the hub. Back from any depth returns one level.
3. Nothing needs a scroll to open: Edit Layout…, a player row near the bottom, More, and
   Motion Source (DSU) → Add Server all push at once from a fresh, unscrolled hub.
4. In game, hub → Show On-Screen Controls off. Disconnect and reconnect the pad. The overlay stays
   hidden, because the hub choice is not re-derived.
5. Hub → On-Screen Style: Wii, then GameCube. The overlay follows each time. D-pad left/right on the
   focused Style and Opacity rows changes them one step per press. This retires Phase 1 checklist
   item 6.
6. The top bar's controller menu has no On-Screen Style. It has Pointer, Recenter Pointer, Show/Hide
   and Controller Settings….
7. A Connected Devices row shows battery % and "P1". Tapping it flashes and rumbles that pad.
8. Per-game pointer mode: set a game profile's Touch IR mode to Gyro, then boot the title. The live pad
   is in Gyro without opening any menu.
9. Settings → Controllers → Motion Source (DSU) → Add Server is a pushed page. Back cancels it; Add
   saves. Opening `dolphinios://dsu/add?...` from Safari lands on the DSU server list, showing the
   new server.

Apple TV, with a Siri Remote and a pad, on a Wii title:
10. The pause menu's Controllers pane shows the hub.
    - Focus reaches every row, down to the last Help line.
    - Menu at the hub root returns to the pause menu.
    - Menu on a pushed player screen pops only it.
11. Settings → Controllers is the same hub. Menu pops back to Settings.
12. Motion Source (DSU): "Enable DSU Client" is focusable and toggles. It is not greyed out.
13. Continuous Wii Remote Scanning toggles and shows its checkmark.

## Next
Phase 3: the player screen (PlayerScreenModelBuilder), which replaces RemapPlayerView behind each
player row. It covers device, profile (Save As… through MenuModal), Wii rows, capture rows, Pointer &
Motion and Advanced.
Phase 4 deletes ControllerSetupView.swift (no callers since Task 8) and the More rows the player
screen replaces.
