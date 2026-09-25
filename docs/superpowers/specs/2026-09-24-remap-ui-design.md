# Button remapping UI rewrite design (C7)

Companion to `docs/superpowers/plans/2026-09-24-controller-followups.md` item 7
and `docs/audits/2026-09-24-controller-system-audit.md` item #13. Replaces
`ButtonMappingView.swift`'s storyboard (iOS) / `TVMappingRootViewController`
(tvOS) drill-down, and retires the `ControllersMappingView` typealias
(`Source/iOS/App/Common/UI/Settings/SwiftUI/ControllersMappingView.swift`)
in favor of one new SwiftUI screen. Entry point is unchanged:
`ControllerSetupSections`'s "Customize Buttons…" row
(`ControllerSetupView.swift:239, 258, 292, 326`), which already carries
`isGC` + `portOneBased`.

## 1. Screen anatomy — one screen per player

`RemapPlayerView(isGC: Bool, portOneBased: Int)`, a single scrolling `List`
(iOS) / focus-native `List` (tvOS), no per-group push navigation — the
requirement is speed, and today's flow is Player → Device → **Group** →
**Control** → alert, i.e. three taps before the first capture
(`ButtonMappingView.swift:265–294`). The new screen is two:

1. **Header section** (not a control group, always visible):
   - Device: current bound qualifier (`TVControllerMappingBridge.defaultDevice(forGCPort:/forWiimote:)`),
     friendly name, tap to reopen the existing device picker
     (`ControllerSetupSections.tvDeviceRows` / `devicePicker` — reused, not
     duplicated).
   - Profile: current name (tracked client-side; the bridge has no "current
     profile name" query, only load/enumerate — see §3) with Load / Save.
   - **Wii only**: Extension (None/Nunchuk/Classic) and Sideways, calling
     the *existing* `ControllerSetupSections.setWiiExtension` /
     `setWiiSideways` bodies (`ControllerSetupView.swift:476–488`) — do not
     reimplement; that code already does the right thing (writes through
     `DOLWiimoteBridge`, calls `ControllerManager.shared.reconcile()`, posts
     `DOLWiiOverlayLayoutChangedNotification`).
2. **Control sections**, one per group, all expanded inline (no push): for
   GC — Buttons, D-Pad, Control Stick, C-Stick, Triggers, Rumble, Options
   (group ids 0–6); for Wii — Buttons, D-Pad, IR, Swing, Tilt, Shake, Rumble,
   Options (0–8, Extension excluded — it's in the header, not a control
   group). This numeric mapping is `GroupEditViewController.groupIdForName`
   (`ButtonMappingView.swift:596–620`) verbatim — the C++ side
   (`padControlNamesForGroup:group:` etc., `TVControllerMappingBridge.h:67–74`)
   needs no changes, only the Swift caller changes shape.
   - Each row: control name (from `padControlNamesForGroup`/
     `wiimoteControlNamesForGroup`) + current expression (from
     `padControlExpressionsForGroup`/`wiimoteControlExpressionsForGroup`,
     e.g. `` `Button A` `` — bare, backtick-quoted, device-relative; confirmed
     against `Data/Sys/Profiles/GCPad/Physical Controller.ini:2-8`, which has
     no device prefix in the expression, only in the profile's separate
     `Device =` line). Tapping/activating a row arms live capture (§2) for
     that control.

## 2. Live capture loop

Replaces the "Press Input" `UIAlertController` with a text field
(`ButtonMappingView.swift:640–656`), which never actually captured a physical
input — it took typed expression text. Real capture:

1. **Arm.** Row shows "Press a button…" and highlights; every other row in
   the screen is disabled for activation (single capture at a time — this is
   also the touch/controller double-activation guard: the press that entered
   capture must not also register as the first captured input).
2. **Baseline snapshot.** At arm time, call
   `TVControllerMappingBridge.inputStates(forQualifiedDevice:)` once for the
   screen's bound device (names from `inputsForQualifiedDevice:`, cached at
   screen load) and store it as the baseline vector.
3. **Release-to-arm guard.** Poll at ~60 Hz (a `Timer`/`CADisplayLink`, same
   cadence as the existing `InputDisplayViewController` poll,
   `ButtonMappingView.swift:795`). Capture does not start accepting candidate
   inputs until **every** input has returned within a small epsilon of its
   baseline (digital: not pressed; analog: within ~0.05 of rest) — this is
   the same latch-and-rearm primitive the D18 spec uses for menu activation
   (§2 of that doc), applied here to stop the arming tap/press itself from
   being read back as the binding.
4. **Detect.** After the release-to-arm gate passes, the first input whose
   value crosses a threshold (digital: `isPressed`; analog axis: `|Δ| > 0.35`
   from baseline) **and stays past threshold for ≥3 consecutive polls**
   (~50 ms, rejecting contact bounce / noise) wins. Its name — already signed
   for axes (e.g. `L Stick Y+` / `L Stick Y-` are distinct enumerable inputs,
   per the profile file's `Main Stick/Up = \`L Stick Y+\`` line) — becomes the
   expression directly: `` `<input name>` ``.
5. **Write and refresh.** `setPadControlExpressionForPort:group:index:expression:`
   / `setWiimoteControlExpressionFor:group:index:expression:`
   (`TVControllerMappingBridge.h:69, 74`), then re-read
   `padControlExpressionsForGroup`/`wiimoteControlExpressionsForGroup` to
   refresh just that row — same refresh pattern as
   `GroupEditViewController.tableView(_:didSelectRowAt:)`
   (`ButtonMappingView.swift:648–654`).
6. **Cancel / timeout.** Tap the armed row again, or press B (iOS controller)
   / Menu (tvOS remote), cancels with no write. Auto-cancel after 5 s of no
   qualifying input.

## 3. Profile save / load

**Load already exists and needs no bridge changes**: `profilesForGCPort:` /
`profilesForWiimote:` enumerate `.ini` basenames from the user + sys profile
directories (`TVControllerMappingBridge.mm:334–382`); `loadProfile:forGCPort:restoreDevice:`
/ `forWiimote:` load them (`:384–432`). The header's Load button reuses
`ControllerSetupSections.profileSheet` (`ControllerSetupView.swift:451–472`)
as-is.

**Save does not exist.** `ButtonMappingView.swift:354–376`'s "Save" prompt is
a name-entry `UIAlertController` whose action body is a literal
`// TODO: Implement actual profile saving`, and nothing in
`TVControllerMappingBridge.mm` writes a profile file (confirmed: no
`saveProfile`/`SaveProfile` symbol in that file). This rewrite adds it:

```objc
+ (BOOL)saveProfile:(NSString*)name forGCPort:(NSInteger)portOneBased;
+ (BOOL)saveProfile:(NSString*)name forWiimote:(NSInteger)indexOneBased;
```

Implementation mirrors `loadProfile:...` in reverse: resolve
`pad->GetConfig()->GetUserProfileDirectoryPath()` (never the sys dir — user
profiles are never overwritten in place), `File::CreateFullPath` it if
missing, build an `IniFile`, call `pad->SaveConfig(ini.GetOrCreateSection("Profile"))`
(the mirror of the existing `pad->LoadConfig(ini.GetOrCreateSection("Profile"))`
at `TVControllerMappingBridge.mm:403`), `ini.Save(userPath)`, return whether
the write succeeded. The existing (currently dead) name-entry alert UI in
`ButtonMappingView.swift:354–376` is the right UX — this rewrite carries it
over and wires it to the new method instead of writing new UI for it.

The header shows the profile name the screen was **opened with** or last
loaded/saved (client-side state; the bridge has no "current profile name"
query) rather than trying to reverse-match the live config against every
`.ini` on disk.

## 4. Wii extension / sideways

Not new UI logic — see §1's header. `ControllerSetupSections` already owns
this correctly (`ControllerSetupView.swift:476–488`, reading
`DOLWiimoteBridge.selectedExtension(forWiimote:)` /
`isSideways(forWiimote:)` on load). `RemapPlayerView` calls the same two
functions (extracted to a small shared type both views hold, or simply
duplicated as two three-line functions — not worth a shared service given
their size) so extension/sideways changes made from either screen stay
consistent and both post `DOLWiiOverlayLayoutChangedNotification`.

## 5. Touch, controller and tvOS focus

- **Touch (iOS)**: tap a row to arm capture; tap again to cancel; Load/Save
  as header buttons; Extension as a segmented control, Sideways as a
  `Toggle` — matching `ControllerSetupSections`'s iOS layout
  (`ControllerSetupView.swift:298–331`).
- **iOS controller navigation**: reuse the D18 spec's move/activate
  primitives (edge-triggered d-pad/stick with initial-delay-then-repeat,
  latch-and-rearm activation) scoped to this screen. If the D18 `MenuScreen`
  engine has landed by the time this ships, `RemapPlayerView` is built on it
  directly (the control-row list is a `MenuModel` like any other screen,
  §2's arm/capture state living outside the model as `@State`, not as a
  `MenuItem` field, since it's screen-local UI state, not menu data). If C7
  ships first, it carries a minimal private copy of just those two
  primitives, structured so the swap to `MenuScreen` later is a rename, not a
  rewrite — do not invent a third, different navigation scheme for this one
  screen.
- **tvOS**: no `GCController` handlers, no `Picker`/`Menu` — native focus
  only, following the proven shape at `ControllerSetupView.swift:336–398`
  (`tvOptionRow` for Extension's three options, one `Button` per row for
  every control, exactly mirroring what
  `GroupEditViewController.tableView(_:cellForRowAt:)`
  (`ButtonMappingView.swift:623–634`) already does with `UITableViewCell`
  rows — this rewrite is a SwiftUI re-expression of a layout tvOS mapping
  already got right once, not a new design). Capture on tvOS requires an
  actual game controller: `DeviceSelectionViewController` already filters
  `iOS/` (touchscreen) devices out of the tvOS device list
  (`ButtonMappingView.swift:486–488`) since there is no on-screen touch
  target on tvOS to bind, and the same filter applies to the device this
  screen operates against.

## 6. Deletions

**Confirmed dead today, delete outright as part of this rewrite** (verified
by grep — each is referenced only from within its own file, plus its own
`#Preview`):
- `Source/iOS/App/Common/Swift/Widgets/ControllerMappingView.swift` (494 lines)
- `Source/iOS/App/Common/Swift/Widgets/ControllerPickerSheet.swift` (234 lines,
  referenced only from the file above)

**Delete once `RemapPlayerView` ships and replaces the entry point**:
- `ButtonMappingView.swift`'s `TVMappingRootViewController` and its five
  supporting UIKit view controllers (`DeviceSelectionViewController`,
  `GroupEditViewController`, `ProfileLoadViewController`,
  `ExtensionSelectionViewController`, `InputDisplayViewController` — roughly
  850 of the file's 896 lines).
- The iOS `ButtonMapping.storyboard` path (`ButtonMappingView.swift:12–37`).
- `ControllersMappingView`'s typealias/representable
  (`ControllersMappingView.swift`), replaced by `RemapPlayerView` called
  directly from `ControllerSetupSections`'s `mappingTarget` sheet
  (`ControllerSetupView.swift:152–157`).

Deleting the legacy stack also closes audit item #13: "Legacy profile picker
mutates and saves live config on row tap, no way back; tvOS 'Save Profile' is
a `TODO` no-op" (`ButtonMappingView.swift:354–376` again — the same TODO this
spec's §3 finally implements, in the new screen instead of the old one).

## 7. Phasing

**Sonnet-doable, no controller needed:**
- Delete the two confirmed-dead widgets (§6, first bullet).
- Build `RemapPlayerView`'s shell: header (device summary, profile name +
  Load via the existing `profileSheet`, Wii extension/sideways wired to the
  existing setters), control-group sections populated read-only from
  `padControlNamesForGroup`/`padControlExpressionsForGroup` (and the Wiimote
  equivalents), with rows showing name + current expression but capture not
  yet armed.
- Implement `saveProfile:forGCPort:`/`forWiimote:` (§3) and wire the existing
  name-entry alert to it.
- tvOS row layout port (`tvOptionRow`-shaped rows for every control and for
  Extension).
- Unit-testable pure functions: expression formatting (`` `<name>` ``), the
  group-id name→int table (a direct port of
  `GroupEditViewController.groupIdForName`), and the capture threshold/debounce
  decision function taking a fake `[Float]` input-state array plus a baseline
  — none of this needs live hardware to test.

**Needs a real controller / device:**
- Tuning the capture thresholds and the release-to-arm guard against real
  analog noise (trigger drift, thumbstick centering error).
- Confirming no double activation with an actual physical A/X press, and
  that the arm-then-release gate behaves correctly for both a touch tap and
  a controller button used as the "start capture" input.
- DualSense/Xbox element-name edge cases feeding into the captured
  expression string (ties directly to plan item B3's element-name trace).
- Profile save/load round-trip against the live `Pad::GetConfig()`/
  `Wiimote::GetConfig()` singletons — not reachable from a host-only unit
  test.
- Apple TV focus verification with a physical MFi/DualSense pad attached.
