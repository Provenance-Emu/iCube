# Remap UI (C7) implementation plan — 2026-09-25

Executes `docs/superpowers/specs/2026-09-24-remap-ui-design.md`. This file records
where the code diverges from that spec (found while reading the C++ side) and the
commit sequence. Gate for every commit: iOS + tvOS `iCube (NJB)` Debug
(Non-Jailbroken) generic builds.

## Brainstorm: spec corrections

1. **Group ids in the spec are wrong.** They were copied from the legacy
   `GroupEditViewController.groupIdForName`, which mislabels groups. The real
   enums are `PadGroup { Buttons 0, MainStick 1, CStick 2, DPad 3, Triggers 4,
   Rumble 5, Mic 6, Options 7 }` (`GCPadEmu.h:23`) and `WiimoteGroup { Buttons 0,
   DPad 1, Shake 2, Point 3, Tilt 4, Swing 5, Rumble 6, Attachments 7, Options 8,
   … }` (`WiimoteEmu.h:48`). `RemapGroup` carries the real raw values and a unit
   test pins them. Wii shows Buttons, D-Pad, IR (Point), Swing, Tilt, Shake,
   Rumble, Options; Attachments stays in the header; Hotkeys/IMU*/IRPassthrough
   are not exposed.
2. **Input values are uniform.** Every MFi input (`MFiController.mm:16-80`) is a
   0…1 half: buttons 0/1, pressure buttons 0…1, sticks split into signed halves
   (`L Stick Y+` / `L Stick Y-`). One threshold (0.35 above rest, 3 consecutive
   polls) covers digital and analog. Motion inputs (`Accel *`, `Gyro *`) are
   excluded from candidates — gravity sits at ~1.0 permanently and a hand tremor
   would win the race.
3. **Release-to-arm, made precise.** At arm time snapshot the vector; the gate
   waits until every input that was *above threshold at arm time* falls below a
   rest epsilon (0.15). Then the vector is re-snapshotted as the rest baseline
   (absorbs trigger drift / stick centering error) and detection runs against
   that. Touch arming has nothing held, so the gate passes on the first poll.
4. **B / Menu cannot cancel capture.** `Button B` is the most common thing to
   bind; if B cancelled, no controller-only user could ever bind it. iOS: B is
   not a cancel key while armed (cancel = tap the row again, the row's Cancel
   button, or the 5 s timeout). tvOS: `onExitCommand` is swallowed while armed
   so the same B press reaches the poll; when not armed it dismisses the sheet.
5. **Per-control Clear** lives in a `contextMenu` on every row (long-press on
   touch and on the Siri Remote surface) plus an iOS swipe action; the header
   has "Reset to Default Profile" (reloads
   `BridgeControllerConfigWriter.defaultProfileName(forQualifier:)` with
   `restoreDevice: true`).
6. **Device row** opens a small picker sheet inside the new file that routes
   through `ControllerManager.shared` (assign / assignTouchscreen /
   clearDefaultDevice). `ControllerSetupSections.tvDeviceRows` is private and
   bound to that view's state, so it is not reusable without a larger refactor.
   tvOS filters `iOS/` devices out, as the spec requires.
7. **Wii extension / sideways** move into `WiimoteSlotOptions` (two static
   functions) used by both `ControllerSetupSections` and `RemapPlayerView`.
   `DOLWiimoteBridge` already posts `DOLWiiOverlayLayoutChangedNotification`
   itself, so the Swift-side re-post is dropped.
8. **Profile save** is a SwiftUI `.alert` with a `TextField` (works on iOS 17 and
   tvOS 17), calling the new `saveProfile:forGCPort:` / `forWiimote:`.
9. **iOS controller navigation** is a private, pure `RemapControllerNav` state
   machine (edge-triggered move with 0.4 s initial delay then 0.08 s repeat,
   stick hysteresis 0.6/0.3, latch-and-rearm A) driven from
   `valueChangedHandler`, gated on `ControllerFocusCoordinator.isActiveScope`.
   Swapping to D18's `MenuScreen` later is a rename.
10. **Deletions now:** `Widgets/ControllerMappingView.swift`,
    `Widgets/ControllerPickerSheet.swift`, `ControllersMappingView.swift`.
    `ButtonMappingView.swift` (tvOS `TVMappingRootViewController` stack + iOS
    storyboard wrapper) becomes unreferenced but stays for a later pass, as
    instructed.

## Commits

1. `docs(remap)`: this plan.
2. `chore(remap)`: delete the two dead GC-only widgets.
3. `feat(bridge)`: `saveProfile:forGCPort:` / `saveProfile:forWiimote:`.
4. `feat(remap)`: pure model — `RemapGroup`, `RemapExpression`,
   `RemapCaptureMachine`, `RemapControllerNav` — plus `RemapModelTests.swift`
   (Tuist glob + 4-spot pbxproj entry).
5. `feat(remap)`: `RemapPlayerView` + `WiimoteSlotOptions`; wire "Customize
   Buttons…"; remove `ControllersMappingView.swift`.
6. `docs(controllers)`: followups table + handoff update.

## Device checklist (user, iPhone 16 Pro Max + controller)

Arm a row by touch → press a button → row updates, no second row armed. Arm a
row with A on the controller → the A press is not captured; the next press is.
Bind `Button B`. Stick halves land on the right control. Cancel by re-tap and
by timeout. Clear via long-press. Save a profile, load it back, Reset to Default.
Wii: extension/sideways changes reflected in the pause-menu Controllers screen.
