# Controller Hub Phase 3 — handoff

The decisions were signed off on 2026-09-30. The phase was executed and landed on the branch
`feature/controller-hub-phase3` on 2026-10-01.

The ledger and the smoke-test screenshots mentioned below (the subagent-driven development, "SDD",
workspace `.superpowers/sdd/2026-09-30-controller-hub-phase3-player-screen/`) live in `.superpowers/`,
which is git-ignored. They exist only in the worktree `.claude/worktrees/controller-hub-phase3/` and
are lost when that worktree is removed. Copy anything you need out of it first.

Plan: `docs/superpowers/plans/2026-09-30-controller-hub-phase3-player-screen.md`
Spec: `docs/superpowers/specs/2026-09-28-controller-hub-design.md`
Previous handoff: `docs/handoff-2026-09-30-controller-hub-phase3-start.md`

## What is verified and what is not

- Verified: every task passed its unit tests and both Release compile gates (`make gate-release`,
  iOS and tvOS). The full suite is 494 tests (370 at the baseline) and all pass.
- Verified once, in the iPhone 17 Pro Max simulator on 2026-10-01, with a Debug build of
  `6cc57b8bb4`: the smoke test listed under the iPhone checklist below.
- Not verified: anything on a physical device, and anything on tvOS at runtime. Both are only
  compile-checked. The two checklists below are the work that remains.

## Landed

The branch's commits, oldest first (`git log --oneline 9fed77680c..HEAD`; that command now also
lists the handoff commits, which this list leaves out). The task each one belongs to is in brackets.

- `2164609ba2` docs(plan): controller hub phase 3 player screen [plan]
- `e906669649` fix(menu): A and a d-pad adjust in one tick step a picker once [Task 1]
- `80c0d86527` feat(menu): a controller's A activates a custom row [Task 2]
- `bffe78f9e6` feat(menu): one-row tvOS stepper for long pickers [Task 3]
- `1c5073254f` feat(menu): a pad's B pops More, DSU and Edit Layout [Task 4]
- `e99a3ae5ab` feat(input): parse check and numeric settings bridge, app-side [Task 5]
- `66982e88fa` feat(motion): gyro pointer sensitivity, setters, declared notice [Task 6]
- `32a9d114b4` feat(controllers): control categories and numeric setting steps [Task 7]
- `4eee84e5c1` feat(controllers): player screen state, name rules, capture row [Task 8]
- `2b11e45a21` feat(controllers): pure player screen model builder [Task 9]
- `1871186bc9` feat(controllers): device list, profile list, expression editor [Task 10]
- `c285a78258` feat(controllers): player screen IO seam and live implementation [Task 11]
- `059ba85986` feat(controllers): player screen view model [Task 12]
- `0bf904cad0` fix(controllers): Save As never prefills a blank or built-in name [Task 12]
- `0aaa6b9f9f` fix(input): leave a pad's Wii pointer on when no touch slot exists [Task 13]
- `6cc57b8bb4` feat(controllers): the hub's player rows push the player screen [Task 14]
- `e5d4393702` chore(l10n): catalogue the player screen strings [Task 15]

The player screen's files are in `Source/iOS/App/Common/Swift/Controllers/Player/`. The branch
changes two of the hub's files, `Controllers/Hub/ControllerHubViewModel.swift` and
`Controllers/Hub/ControllerHubState.swift`:
- The hub's player rows now push `PlayerScreenView` instead of `RemapPlayerView`.
- `.padBackNavigation()` is added to three destinations: Motion Source (DSU), More Controller
  Settings and Edit Layout.
- `LiveControllerHubReader.connectedPads()` fills the new `ConnectedPadState.hasGyro`, which is
  declared in `ControllerHubState.swift` (default `false`, so existing memberwise inits compile).

Task 13 changed `Source/iOS/App/Common/Swift/EmulationScreen.swift`.

## Merge order

1. First merge the dead-pad fix, which is not on this branch: branch `fix/touch-to-pad-mapping`,
   commit `5bbeee6c33` "fix(controllers): a pad taking a touchscreen port gets its own mapping".
   - `ControllerAssignmentService.assign` used to keep any non-empty mapping when it bound a
     device. A port the Touchscreen held has the Touchscreen profile, which binds `Button 0`
     and numbered axes such as `Axis 611` (the touchscreen device's inputs; written `Axis 6xx` below),
     and none of those inputs exist on a physical pad, so the pad was bound and did
     nothing. `assign` now keeps a port's mapping only when at least one control binds on the
     device just bound.
   - It adds `TVControllerMappingBridge.padMappingBindsDevice(forGCPort:)` and
     `wiimoteMappingBindsDevice(forWiimote:)`, and renames `ControllerConfigWriting.hasMapping` to
     `mappingBindsDevice`.
   - `padHasAnyBinding` and `wiimoteHasAnyBinding` still exist, so this branch compiles on top of it.
   - That commit owns `ControllerAssignmentService.swift`, `TVControllerMappingBridge.{h,mm}` and
     `BridgeControllerConfigWriter.swift`. Phase 3 edits none of them.
   - Its tests (`ControllerAssignmentBridgeTests`, `ControllerAssignmentServiceTests`) pass, and
     the full suite and both Release gates passed on that branch.
   - It was also checked in the iPhone 17 Pro Max simulator with the same Gamepad device (Debug
     build of the fix branch, 2026-10-01): Touchscreen → Gamepad then showed A bound to A and the
     d-pad to the d-pad (screenshot `smoke/fix-2-gamepad-after-fix.jpg` in the SDD workspace). That
     is one manual-pick flow on GameCube Player 1 in a simulator. Auto-assign on connect, a mid-game
     reconnect and Wii are covered only by unit tests, and nothing was run with a physical pad.
2. Then this branch. Cherry-pick oldest first. None of its commits carries an attribution trailer;
   if one is ever found, strip it, and do not reword a commit to add a model trailer.
3. Then one follow-up commit, which does not exist yet. `PlayerScreenViewModel.setDevice` decides
   the remembered profile name from `io.hasAnyBinding(slot)`, asked before the bind (a pad taking
   over a port that already has a mapping keeps the old mapping and its name). After the fix, a Touchscreen → pad switch loads the pad's default profile, so
   the Load Profile row would still read "Touchscreen". The follow-up makes `LivePlayerScreenIO`
   ask the new bridge check after the bind, and updates the fake IO and the name tests.
   - `FakeIO.hasAnyBinding` (in `PlayerScreenViewModelTests`) returns a constant and does not record
     when it was asked, so nothing pins "asked before the bind". The follow-up must make the fake
     answer differently after `setDevice`, and update
     `test_setDevice_firstBindRemembersTheDefaultProfile`,
     `test_setDevice_rebindKeepsTheRememberedName` and
     `test_setDevice_touchscreenOnAWiiRemote_remembersTheTouchscreenProfile`.

The fix also reloads `IMUIR/Enabled = True` (the Enabled setting of the Wii Remote's motion-pointer
group, which switches the core's motion-driven pointer on) on a Touchscreen → pad switch for a Wii Remote, because
the pad's default profile is loaded. The explicit re-enable in `setDevice` stays.

## Decisions worth knowing (signed off 2026-09-30)

- Ownership and plumbing:
  - The player screen owns its own view model (`PlayerScreenViewModel`). It reads `PlayerState`
    through the hub's `ControllerHubReading` and everything else through `PlayerScreenIO`.
  - Expression checks and numeric settings go through `DOLControllerSettingsBridge`, app-side.
    There was no core change and no prebuilt refresh.
- Device:
  - Device is a pushed list: one pick, one assignment, then pop.
  - The list refreshes itself while it is open, because the player screen stops observing when
    covered. `setDevice` re-reads before acting.
  - Binding a gyro pad to a Wii Remote turns its motion pointer (IMUIR Enabled) back on.
  - The emulation screen now switches the core IMU pointer only for a Wii Remote that is on the
    Touchscreen (commit `0aaa6b9f9f`). It used to fall back to Wii Remote 1 whenever no slot was
    on the Touchscreen, which switched a gyro pad's pointer off at every Wii boot.
  - Decision 13 (a Touchscreen → pad switch keeps the touchscreen mapping) is now observed, not
    only traced. In the iPhone 17 Pro Max simulator on this branch, Touchscreen → Gamepad left A
    bound to `Button 0` and the profile named "Touchscreen" (screenshot `smoke/s8s.jpg` in the SDD
    workspace `.superpowers/sdd/2026-09-30-controller-hub-phase3-player-screen/`). The fix is
    `5bbeee6c33`. This branch does not contain it. The fix itself was checked in the same simulator
    with the same Gamepad device: Touchscreen → Gamepad then showed A bound to A and the d-pad to
    the d-pad (`smoke/fix-2-gamepad-after-fix.jpg`). That covers one manual-pick flow on GameCube
    Player 1; auto-assign on connect, a mid-game reconnect and Wii are covered only by unit tests,
    and nothing was run with a physical pad.
- Capture:
  - Rows are disabled, with a hint, on the Touchscreen, on No Device and on a disconnected MFi pad.
  - DSU-bound ports capture and never read "(Disconnected)".
  - After a capture binds, the screen ignores activation and Back for at least 0.5 s
    (`PlayerScreenViewModel.rearmDelay`) and for as long as the bound input is still held, whichever
    ends later (`isCaptureSettling`). A tvOS `Button` fires on release, so a long hold of A would
    otherwise release after the window closed and re-arm the row. A timeout captured nothing, so it
    settles for the plain delay.
- Pointer & Motion:
  - Touchscreen port: Touch – Follow / Touch – Drag / Gyro. There is no "Off".
  - Gyro pad port: one "Aim with Controller Motion" toggle.
  - Invert X / Invert Y show only in Gyro.
  - Sensitivity is the drag gain in Drag (programmatic overlay on), and the new gyro pointer
    sensitivity in Gyro. The gyro setting is `motion_gyro_pointer_sensitivity`
    (`MotionSettings.gyroPointerSensitivity`), default 1.0, with choices ×0.5 to ×3. The drag
    gain's choices are ×0.25 to ×4.
- Profiles:
  - The current profile name is remembered for the app session only. It shows "Custom" when unknown.
  - Reset to Default Profile asks first.
  - Save As is prefilled with the pad name or the player title, never a built-in name.
  - Saving under a built-in name ("Physical Controller", "Touchscreen", "DSU"; the comparison
    ignores case) asks "Replace the Built-In Profile?" first. Saving over any other existing name
    asks "Replace Profile?".
  - All prompts share ONE alert.
- Commits carry no attribution trailer. The merge step strips any that slipped in; it does not
  reword commits to a model trailer.

## Device checklist

None of this has been run on a device. The Task 14 simulator smoke test is the only runtime
evidence.

iPhone 16 Pro Max, with an Xbox pad, a DualSense, a DSU server, a Wii title with the touch overlay,
and a GameCube title.

What the simulator smoke test already showed on 2026-10-01 (iPhone 17 Pro Max simulator, Debug
build of `6cc57b8bb4`), so the device pass can start from it:
- The hub pushes the player screen with a populated first frame.
- Device pushes a list and a pick pops back.
- The Touchscreen port shows the hint and disabled rows.
- Reset asks first.
- Save As is prefilled with the pad name.
- Saving an existing name brings up Replace (the follow-up alert re-presents).
- A tapped capture row arms, disables the others and times out after 5 s.
- Show Advanced lists the numeric pickers and Raw Bindings.

NOT exercised anywhere yet: any real pad input (A/B navigation, binding a capture, pad Back), the
Load Profile list, the raw-expression editor, and all of tvOS.

1. From the pause menu, the top bar's Controller Settings… and Settings → Controllers, a player row
   pushes the player screen.
   - The first frame already shows the port's device and rows (never an empty list).
   - A GameCube port shows Device, Profile, Face Buttons / D-Pad / Sticks / Triggers / System and a
     collapsed Advanced.
   - Wii Remote 1 on the touchscreen also shows Wii Remote and Pointer & Motion.
   - A GameCube title shows no Wii sections.
2. With the pad:
   - The d-pad reaches every row, and the highlight scrolls with it.
   - A on a Buttons row arms it. Buttons rows are `.custom` menu rows, which own their own
     gestures: a pad's A runs the row's `onCustomActivate` closure (here, arming the capture)
     instead of the generic push or action.
   - B returns to the hub.
3. Capture with the pad:
   - Pressing B binds B. The screen does not pop, neither on the press nor on the release.
   - Binding A: the row does not re-arm when A is released.
   - While armed, the d-pad does not move the highlight.
   - Leaving it idle 5 s puts the previous binding back.
4. Touch: tap arms, and a second tap cancels.
   - Long-press → Clear and swipe → Clear unbind a row.
   - On a row near the bottom of a freshly opened screen, scroll to it by hand: its menu appears at
     once.
   - If either gesture misbehaves, apply the fallback in the plan
     (`docs/superpowers/plans/2026-09-30-controller-hub-phase3-player-screen.md`), section
     "Decisions made while planning" → "Ruled — Clear stays on the capture row as `.contextMenu`
     and, on iOS, `.swipeActions`…", bullet "Fallback if checklist items 4 or 23 fail": delete both
     modifiers (the context menu and the swipe action) from `CaptureRowView` and keep only the
     editor's Clear.
   - On a Touchscreen or No Device port, on a disconnected pad, or while another row is armed, the
     row offers neither gesture.
5. Turn the pad off while a row is armed:
   - The capture ends. Device reads "<name> (Disconnected)". The capture rows are disabled, with the
     "Connect this controller to capture buttons." hint. The binding is kept.
   - Turning the pad on restores everything.
6. Device pushes a list:
   - One pick assigns once and pops. Picking the current device only pops.
   - With a custom pad mapping, opening the list and pressing A or d-pad left/right changes nothing
     until a row is picked.
   - With the list open, turn the DualSense on: it appears in the list without leaving it. Picking it
     assigns it.
7. The Touchscreen makes the rows read "On-screen …" and shows the hint; the capture rows are disabled.
   No Device shows its hint and turns the port off in the hub.
8. A port bound to a DSU device shows the device's name, never "(Disconnected)", and captures a DSU
   button.
9. Profile, all through the one alert:
   - Load Profile… pushes at once. A pick pops back, and the row's subtitle shows the name.
   - Save Profile As… opens prefilled with the pad's name; A saves and B cancels.
   - An existing name asks "Replace Profile?". After Save closes, the follow-up appears with its own
     title and message, and neither blanks while it animates.
   - Overwrite test: save under a throwaway name such as "Checklist Test", then save under it again
     and answer "Replace Profile?". Use a throwaway name for this test, because the app has no way
     to delete a user profile.
   - Built-in test (only on a device you can reset, for the same reason: the saved file stays and
     shadows the bundled profile for good, and the app offers no delete). Start from a port bound to
     a pad, so that its mapping differs from the bundled Touchscreen profile. Save Profile As… with
     the name "Touchscreen" (any letter case) and confirm "Replace the Built-In Profile?". A user
     profile named like a built-in one is loaded instead of the bundled profile whenever a device
     of that kind is first bound and on Reset to Default Profile
     (`BridgeControllerConfigWriter.defaultProfileName(forQualifier:)` returns "Touchscreen" only
     for the Touchscreen device; a pad gets "Physical Controller" and a DSU device gets "DSU").
     So the visible check is on the Touchscreen: switch a port to the Touchscreen (Device →
     Touchscreen), or press Reset to Default Profile on a port already on the Touchscreen and
     confirm. Expected: the saved profile loads, so the port's rows show the pad bindings you
     saved instead of the bundled on-screen touch bindings. On a GameCube port, prefer Reset to
     Default Profile on a port already on the Touchscreen as the clean check: switching Device →
     Touchscreen loads the saved "Touchscreen" profile, whose saved `Device =` line can flip the
     port back to the pad it was saved from (`assignTouchscreenToGCPort` does not re-set the
     device after `LoadConfig`, `Source/iOS/App/Common/Emulation/TVControllerMappingBridge.mm`
     ~:228-246), so the port may not stay on the Touchscreen. To undo it, delete `Touchscreen.ini`
     from the app's user profile directory for that controller type (GameCube pad or Wii Remote,
     whichever port you saved from; I did not verify the exact container path) by removing it from
     the app's container, for example with `devicectl` file tools. The Save, Reset or Load screens
     cannot do it.
   - After a capture the subtitle reads "(edited)".
10. Reset to Default Profile asks first. A confirms. B (or Cancel) leaves the mapping unchanged.
11. Wii: Extension → Classic adds Classic rows under Face Buttons, D-Pad, Sticks, Triggers and System.
    Sideways toggles.
12. Wii Remote 1, switched from the Touchscreen to the DualSense, then a Wii title is booted.
    - Expected to PASS with `5bbeee6c33` merged: the pad's buttons work, its gyro aims, and "Aim
      with Controller Motion" reads On.
    - Without that commit it fails: the pad's buttons, sticks and gyro do nothing until Reset to
      Default Profile, because the mapping still binds `Button 0` / `Axis 6xx`.
    - The Load Profile row's subtitle reads the pad's default profile ("Physical Controller") only
      once the follow-up commit from Merge order step 3 is in. With the fix but without the
      follow-up it still reads "Touchscreen".
13. A gyro pad on Wii Remote 1 survives a boot (Task 13):
    - Bind the DualSense to Wii Remote 1, with the Touchscreen on no Wii Remote, and turn
      "Aim with Controller Motion" On.
    - Boot a Wii title: the toggle still reads On (reopen the player screen to check) and the pad
      aims.
    - Show and hide the on-screen controls: it still aims.
    - Also boot a Wii title with the Touchscreen on Wii Remote 1, then reassign Wii Remote 1 to the
      gyro pad mid-game, and confirm the pad's pointer works. The emulation screen no longer
      re-enables or re-disables the pointer once no Touchscreen slot exists; the player screen's
      re-enable owns it.
14. Pointer & Motion on Wii Remote 1 (touchscreen), in a game:
    - The Pointer row's options are "Touch – Follow", "Touch – Drag" and "Gyro"; each changes the
      live pointer.
    - Gyro adds Sensitivity (×0.5–×3), which changes the pointer's speed at once (no restart), plus
      Invert X / Invert Y.
    - Recenter Pointer recenters.
    - Drag, with the programmatic overlay on, adds its own Sensitivity. The overlay is the
      "Programmatic touch overlay (beta)" toggle in Settings → Controllers → More Controller
      Settings (user default `touch_overlay_programmatic`).
    - Shake to Wiggle off stops a device shake reaching the game.
15. Gyro pads:
    - A DualSense on Wii Remote 2 shows only "Aim with Controller Motion". Off stops its gyro moving
      the pointer; on brings it back.
    - An Xbox pad (no gyro) shows no Pointer & Motion.
16. Advanced:
    - Show Advanced lists the stick and trigger settings. D-pad left/right steps Dead Zone one step
      per press.
    - In Raw Bindings, typing "(" shows "Not saved: …" and disables Save.
    - A valid edit saves and pops.
    - Clear, then Save, unbinds the control; this is the pad's path. (Clear only empties the field.)
17. Pad Back, the gap Phase 2 left (on iOS, a pad's A could push More, DSU and Edit Layout from
    the hub, but those screens had no pad B to pop them):
    - A on More Controller Settings, Motion Source (DSU) and Edit Layout pushes each one, and B pops it.
    - On the screens pushed from inside More and DSU (Advanced Motion Settings, Analog Stick
      Settings, Add DSU Server, Edit IR Area, Touch IR Pointer), a pad's B must do nothing. In
      particular it must not pop two levels. These stay touch-only.
18. Nothing needs a scroll to present. From a fresh, unscrolled player screen, these appear at once:
    - Device.
    - Load Profile….
    - The last Raw Bindings row, after Show Advanced.
    - Each prompt.

Apple TV, with a Siri Remote and a pad, on a Wii title:
19. The player screen pushes from the pause pane and from Settings.
    - Focus starts on the Device row, so default focus is set on the first frame.
    - Focus reaches every row, including "Extension: None / Nunchuk / Classic".
    - The Device list has no Touchscreen, and there is no Pointer & Motion.
    - Menu from any depth pops one level.
20. Each Advanced numeric setting is ONE row. Left/right on the Siri Remote and on a pad's d-pad
    steps its value; select does nothing.
21. Up/down leave a compact row normally; focus is never trapped. If item 20 or 21 fails, apply the
    fallback in the plan (`docs/superpowers/plans/2026-09-30-controller-hub-phase3-player-screen.md`),
    section "Decisions made while planning" → "Ruled — the tvOS compact picker is built like
    `TVIntStepper` / `TVFloatStepper`, not as a `Button`", bullet "Fallback": drop
    `isCompactOnTV: true` from the numeric and Sensitivity items, so the rows explode into one row
    per option.
22. Capture:
    - Selecting a Buttons row then pressing a pad button binds it.
    - Menu (or B) while armed binds B and does not pop, neither on the press nor on the release.
    - Binding A does not re-arm the row. Hold the button for a full second before releasing: the
      row must not re-arm on the release either.
    - Focus stays on the armed row.
23. A long press of select on a capture row shows Clear, and Clear unbinds the row. (If this fails,
    apply the same fallback as for item 4: delete the context menu and swipe modifiers from
    `CaptureRowView`.)
24. Save Profile As… shows a prefilled text field in the one alert (tvOS keyboard).
    - The Replace and Replace-built-in follow-ups appear after it closes, and can be answered with
      the remote.
25. The raw-binding editor's field opens the keyboard. A parse error shows inline, and Save is
    disabled. Clear works.
26. Device and Load Profile lists: they are not empty on the first frame, focus lands on the first
    row, and select picks and pops. A pad turned on while the Device list is open appears in it.

## Known gaps

- No pad Back on screens pushed from inside More or DSU (Add DSU Server, Analog Stick Settings,
  Advanced Motion Settings, Edit IR Area, Touch IR Pointer); use touch there. Checklist item 17
  confirms that B does nothing on them rather than popping two levels.
- The hub's own player row still reads "(Disconnected)" for a DSU-bound port
  (`ControllerHubModelBuilder.deviceName`, outside this phase's files). The player screen does not;
  align the hub in Phase 4.
- Until `5bbeee6c33` is merged, a Touchscreen → pad switch leaves the pad dead (decision 13,
  checklist item 12).
- A pad disconnect hands GameCube port 1 back to the Touchscreen, which loads the Touchscreen
  profile over a custom pad mapping. With `5bbeee6c33` the pad comes back working, but on its
  default profile. Keeping the custom mapping needs a per-port stash, which is not designed.
- Saving a profile named "Touchscreen" and then loading it on a GameCube port (Device → Touchscreen,
  or any path through `assignTouchscreenToGCPort`) can flip the port back to the pad the profile was
  saved from: the saved `Device =` line loads and `assignTouchscreenToGCPort` does not re-set the
  device afterwards (`TVControllerMappingBridge.mm` ~:228-246, which this phase does not edit).
  Checklist item 9's built-in test is where it shows up.
- One alert serves every prompt. If a follow-up prompt ever fails to appear after the previous one
  closes (checklist items 9 and 24), the cause is SwiftUI re-presenting the same `.alert` too soon:
  - The plan keeps the one-main-actor-hop gap. The simulator smoke test saw the Replace follow-up
    re-present correctly on iOS.
  - The next step would be a longer gap, or presenting the follow-up from the alert's dismissal.
- Deferred review minors are recorded in the SDD ledger,
  `.superpowers/sdd/2026-09-30-controller-hub-phase3-player-screen/progress.md`, on the lines that
  start "minor (deferred)". The final review triages them. Two deserve a reader's attention:
  - The capture timer and the notification observers are torn down only through `stop()` and
    `endCapture()`. A view model released while a capture is armed leaves a timer firing that does
    nothing.
  - `ProfileNaming.suggestion` can return an empty or a built-in name at its source. The view model
    guards it.

## Next (Phase 4)

- Delete:
  - `ControllerSetupView.swift`, which has had no callers since Phase 2.
  - `RemapPlayerView.swift`, which is NEW on the list: its only caller is `ControllerSetupView`.
    Keep `RemapModel.swift`; the player screen uses it.
- Take `EnhancedMotionControlsView` (Advanced Motion Settings) OFF the delete list (decision 6).
  These options have no other home yet:
  - Horizontal Movement (roll / yaw).
  - Enable 6DOF Motion Controls.
  - Wiimote Motion Controls and Nunchuck Motion Controls.
  - Apply Recommended Settings.
- `ControllerMoreSettingsView` rows the player screen makes redundant:
  - Touch IR Pointer (`TouchIRModePicker`, with `TouchIRMode` in `ControllersRootView.swift`),
    replaced by Pointer.
  - Pointer Sensitivity, replaced by Sensitivity in Touch – Drag.
  - Advanced Motion Settings stays, per decision 6.
  - Analog Stick Settings (`dsu_*`) stays. It is the app's on-screen stick processing, not Dolphin's
    dead zones.
- Carry forward the naming question (decision 8): "On-Screen Style" (hub) vs "Overlay Style" (More).
- Move `MotionDebugView` behind DEBUG.
- Merging: strip any attribution trailer. Do not reword commits to a model trailer.
