# Step 2 surface map (condensed from the explorer report, 2026-10-10, at 6b03332585)

Paths are relative to Source/iOS/App/.

## MenuScreen.swift (843 lines), Common/Swift/Menu/

**Styles:** `MenuStyle` (:12-40) has three cases: `.grid`, `.list`, and `.tiles(columns:compact:)`.

**Dispatch:** `styleBody` (:211-230).

| Style | iOS (:213-218) | tvOS (:219-229) |
|---|---|---|
| `.grid` | `gridBody` | `tvListBody` |
| `.list` | `listBody` | `tvListBody` |
| `.tiles` | `tilesBody` | `tvTilesBody`, with `.defaultFocus($tvFocusedID, first)` (:222) |

**Hosts:**
- `.tiles`: pause only (PauseMenuView:312).
- `.grid`: iOS pause confirms only (PauseMenuView:400).
- `.list`, used everywhere else:
  - Hub (ControllerHubView:31)
  - SettingsLeafHost:92
  - SettingsRootView:69, the phone list
  - CheatsMenuView:81 and :171
  - PauseMenuView:396, the tvOS confirm
  - The Player screens
  - The long-press overlay (:293)

**Shared by both platforms:**
- `body` (:172-200):
  - iOS `.controllerScope` / `navTick` / `onChange(focusableIDs)` (:180-190)
  - tvOS `.onExitCommand` (:191) and the `.onChange(model.focusRequest)` reconcile (:194-198)
- Long-press state machine (:232-270) and `longPressOverlay()` (:286-306); the tvOS `.focusSection()` is at :300.
- `tile()` (:310-321), `footerView` (:326), `rowLabel` (:330-371), `cycleRowLabel` (:374), `performActivate` (:385-405).

**iOS-only:**
- State (:138-168): `router`, `focusedID`, `scopeID`, `gridColumnCount`, `navTick`.
- Renderers (:409-639): `listBody`, `listSection`, `listRow`, `tilesBody`, `gridBody`, `gridCard`, `navInput`, `tick()`.

**tvOS-only** (:643-836): `tvTilesBody`, `tvFocusedItem`, `tvTile`, `tvListBody`, `defaultTVFocusID`, `tvSection`, `tvRow`, `tvCompactPicker`, `tvSteppedRow`, `stepPicker`. `@FocusState tvFocusedID` is at :169.

### `tile()` (:310-321)

```swift
TileFace(icon:title:badge: currentValueTitle ?? badge, tint: item.tint ?? .accentColor, isDestructive:isEnabled:isCompact:)
.buttonStyle(FocusButtonStyle(isFocusedOverride: focused))
```

- This is the only use of `FocusButtonStyle` with an override.
- tvOS passes `tvFocusedID == item.id` (`tvTile` :674-677); iOS passes `focusedID == item.id` (:484).
- `.simultaneousGesture(LongPressGesture(0.5))` is at :319.

### `rowLabel` (:330-365)

- HStack spacing 12.
- Icon badge: SF symbol tinted with `tint ?? .accentColor`, 44×44, `RoundedRectangle(10).fill(tint.opacity(0.15))`.
- The title is plain `Text` with no font set.
- Subtitle and description both use `.font(.caption)` / `.secondary`, inside a VStack with spacing 2. The description sits under the subtitle.
- Value text uses `.secondary`; the badge uses `.caption` / `.secondary`.
- The chevron is `chevron.right` in `.footnote.semibold`, styled `.tertiary`.

### Section headers

| Path | Location | Current style |
|---|---|---|
| iOS list | :425-433 | System `Section(header: Text, footer:)` |
| iOS tiles | :481 | `.subheadline.semibold`, white at 0.7 |
| iOS grid | :515 | `.headline`, white |
| tvOS tiles | :651 | `.headline`, white at 0.7 |
| tvOS list (`tvSection`) | :709-718 | System `Section`; the footer at :327 is unstyled |

### tvOS rows (`tvRow` :729-793)

None of these rows sets `.buttonStyle`, so focus is drawn by the system capsule.

- **`.picker`, non-compact (:733-748):** the options are exploded into rows with `ForEach(enumerated)`. The selected option shows a checkmark (:741-743). Each row has `.focused($tvFocusedID, equals: "\(item.id)#\(index)")` (:747).
- **`.toggle` (:749-762):** shows a checkmark (:756-758); `.focused(equals: item.id)` (:762).
- **`.destination` (:763-766):** a `NavigationLink`.
- **`.custom` (:767):** returned raw.
- **`.stepper` (:769):** rendered by `tvSteppedRow`.
- **`.cycle` (:773-784):** a `Button` built from `cycleRowLabel`, with `.onMoveCommand` (:777-784).
- **`.navigation` / `.action` / `.destructive` (:785-788):** a `Button` that calls `performActivate`.

### `tvSteppedRow` (:805-829)

```swift
HStack { rowLabel; chevron.left; Text(value).monospacedDigit(); chevron.right }
  .contentShape(Rectangle())                                   // :813
  .focusable(item.isEnabled)                                   // :814
  .focused($tvFocusedID, equals: item.id)
  .padding(8)
  .overlay(RoundedRectangle(10).stroke(focused ? accentColor : clear, lineWidth: 4))  // :817-819
  .opacity(enabled ? 1 : 0.5)
  .onMoveCommand                                               // :821-828
```

- This is a focusable `HStack`, not a `Button`, so it cannot take a `ButtonStyle`. Only its visuals get restyled.
- `tvCompactPicker` (:795-801) also goes through `tvSteppedRow`.

### iOS renderers

- **`listRow` (:436-470):** native `Toggle` / `Picker(.menu)` / `NavigationLink` / `Button` / `ValueStepper`. Controller-focus tint is at :469: `listRowBackground(focusedID == id ? accent.opacity(0.22) : nil)`.
- **`tilesBody` (:474-500):** VStack spacing 16, `LazyVGrid` spacing 12, padding 16; `InfoShelf` sits in a bottom safe-area inset.
- **`tvTilesBody` (:644-669):** spacing 20/28/24, padding 24, `.focusSection()` at :665, `InfoShelf` at :667.
- **`gridBody` (:508-529):** `MenuGridLayout` lives in MenuFocusRouter.swift:330-342 (min card width 320, spacing 12, padding 16).
- **`gridCard` (:531-556):** `rowLabel`, padding 12, `.ultraThinMaterial` in an `RR(12)`, a white 0.08 stroke of 1 plus an accent stroke of 3 when focused, and `.buttonStyle(.plain)`.

### Long-press overlay (:286-306)

- Black at 0.55.
- Title `.headline`, white.
- A nested `MenuScreen(.list)` with `maxHeight count*64+24`.
- `RR(16)` `.ultraThinMaterial`, `maxWidth` 420.

### Ratchet lines in MenuScreen (17)

292, 298, 340, 347, 350, 359, 362, 481, 515, 540, 543, 544, 548, 549, 651, 818, 819

## MenuKit

### TileFace (109 lines, 8 findings; shared)

- **Compact variant** (iOS landscape): icon `system(14)`, `RR(7)`, title `.footnote.semibold`, badge `.caption2`.
- **Regular variant:**
  - Icon `system(22, semibold)`, 44×44, `RR(10)` filled at 0.15.
  - Badge `.caption.semibold`, white, `Capsule` filled white at 0.18.
  - Title in `theme.tileTitleFont`, white (red when destructive), `lineLimit(2)`.
- **Container:** padding 14 on tvOS / 12 on iOS; `minHeight` from `theme.tileMinHeight` (180 / 96); `RR(theme.cornerRadius)` filled with `tileFill`; white 0.08 stroke of 1; opacity 0.45 when disabled.
- **Destructive** uses `.red` at :33, 43, 65, 87.

### InfoShelf (37 lines, 2 findings)

- `info.circle` in white at 0.7.
- Text `.subheadline`, white at 0.85, `lineLimit(3)`.
- Value `.subheadline.semibold`, white.
- Padding h16, `minHeight` `shelfHeight` (80 / 56), `RR` filled with `tileFill`.

### FocusButtonStyle

- Ring in `tileAccent`, width 4, scale 1.06, spring (0.3, 0.7).
- `.focusEffectDisabled()` on tvOS only.
- Users: MenuScreen:317 (with override) and SettingsSidebarShell:149 (no override).

### Other MenuKit files

- **ValueStepper:** iOS-only.
- **BackCoalescer:** window 0.25 s. Callers: SettingsSidebarShell:94 and PauseMenuView:43, 143, 313.

## Settings

### SettingsSidebarShell (166 lines, 1 finding at :131)

**Layout** (:46-70): `HStack { sidebar(width) ; Divider() (:53) ; NavigationStack { pane } }`. Sidebar width is 320 on tvOS and 240 on iPad.

**`sidebar`:**
- iOS (:106-120): `NavigationStack`, `.navigationTitle` (:118), `.searchable`.
- tvOS (:121-123): bare `sidebarList`.

**`sidebarList`** (:126-157) is shared by tvOS and iPad-regular. It is a ScrollView with a VStack of spacing 6.
- Header: `.caption.semibold` / `.secondary`.
- Entry: a `Button` containing an `HStack` of icon (28 wide) + title; padding h12/v10.
- Selection: `RR(10)` filled with `tileAccent.opacity(0.25)`.
- Style: `FocusButtonStyle()`.
- Focus: `.focused($sidebarFocus, equals: entry.id)`.
- Outer padding h20/v24.
- The `Layout` enum (:27-40) holds the numbers.

**tvOS-only modifiers:**
- `.focusSection()` at :50 and :68
- `.onExitCommand(leaveSettings)` at :51, routed through `BackCoalescer`
- `.onExitCommand(backToSidebar)` at :59
- `openedAt` at :18-21

**Shared modifiers:**
- `.defaultFocus($sidebarFocus, …)` at :71
- `.onAppear` at :72-78
- `jumpToControllers`

### SettingsRootView (93 lines)

- tvOS background is `Color.black` at :55-57.
- tvOS goes straight to the shell; iPad-regular also uses the shell; iPhone uses `phoneList` (`MenuScreen(.list)` :69, `.navigationTitle` :75).
- Background pattern to copy: TVLibraryView:266 declares `@AppStorage(ConfigInterfaceDefaultsKey.backgroundStyle)`, and :783 renders `ICubeRoom(style: LibraryBackgroundStyle(rawValue:) ?? .gradient)`.

### Leaf host

- `SettingsLeafHost` (SettingsLeafHost.swift:34-62) sets `.navigationTitle(title)` at :46 on every leaf.
- `settingsPaneBack` is defined at SettingsLeafHost.swift:8-27 and set at SettingsSidebarShell:66.
  - Consumers: SettingsLeafHost:77, 84-86 and ControllersRootView:25, 29.
  - Cleared at MenuScreen:178, 452, 764 and DSUControllerView:279.

## Controller hub

- `ControllerHubView.swift` (64 lines) wraps `MenuScreen(.list, onBack: flushPending …)` (:29-39) and sets `.navigationTitle(L("Controllers"))` at :46. It has no styling of its own.
- The builder has no `.custom` rows and no tints.
- Mixed icons: in the "devices" section, `no-pads` (:204) has no icon while the `pad-*` rows (:200) do.
- Hosts:
  - Settings: ControllersRootView:29
  - tvOS pause pane: PauseMenuView:119-125
  - iOS sheets: PauseMenuView:225-232, EmulationScreen:1373

## Pause: PauseMenuView.swift (929 lines, 43 findings)

**Body:** a `ZStack` (:102-131) on `Color.black` (:105). Panes are `.main`, `.saves`, `.cheats`, `.controllers`.

**`mainMenu`** (:255-298):
- tvOS: `HStack(spacing: 48) { coverColumn(220) ; tiles }.padding(60)`.
- iOS: `VStack { compactHeader ; tiles }`.
- Forced dark at :294-297 (`.environment(\.colorScheme, .dark)`). **Keep it.**

**Tiles** (:309-318): `MenuScreen(model, .tiles(columns:compact:), onBack: BackCoalescer.shouldHonor … onClose())`. Columns come from `PauseTileLayout`: 6 on tv.

**Backdrop** (:320-327): blurred cover at 24 / opacity 0.5, plus a black gradient of 0.85 / 0.35 / 0.85.

**`coverColumn`** (tvOS, :329-340):
- Cover `RR(12)` with a shadow.
- Title `.title3.bold`, white.
- gameID `.caption`, white at 0.7.
- "Paused" in `.caption.semibold` on a white-0.18 `Capsule`.

**`compactHeader`** (iOS, :343-366): stays unchanged on iOS.

**`confirmOverlay`** (:375-417):
- Black at 0.55.
- Title `system(18, bold)`; message `system(14, medium)`.
- tvOS: `MenuScreen(.list)`, `maxHeight count*110+40`, `.focusSection()` (:395-398).
- iOS: `.grid`, `count*80+20` (:400-401).
- Container: `maxWidth` 640 on tv / 380 on iOS, `RR(16)` `.ultraThinMaterial`, white 0.08 stroke.
- Models:
  - `resetConfirmModel` (:753-764), Cancel listed first
  - `exitConfirmModel` (:768-783)
  - Tints are `.orange` / `.red` / `.blue`.

**Out of step-2 scope:**
- The saves pane (:419-668; the tvOS hand-built part is :479-666, with 28 findings).
- CheatsMenuView's tvOS layout (:104-187, 7 findings).
- The sheets.

**Pause model** (`PauseMenuModelBuilder.make` :841-888): sections Quick / Game / System; every item has an icon and a tint; Quit is `.red` and Reset is `.orange`.

## Must stay (do not touch)

- **Composite picker ids:**
  - MenuScreen:747
  - `defaultTVFocusID` :693-706
  - Long-press ids :276
- **Picker explosion:** :733-748.
- **`onMoveCommand`** at :777-784 and :821-828, together with `.focusable` :814 and `contentShape` :813.
- **`settingsPaneBack`:** every site listed above.
- **`BackCoalescer`:** every site listed above.
- **`PauseArbiter`:**
  - PauseMenuView:72 and :141-165 (including `isPauseMenuChildPresented` :54-61), plus :195, 710, 743
  - `.pauseClaim` sites: PauseMenuView:207, 222, 230, 239, 475, 663
  - EmulationScreen:528, 1704
- **`.claimsController()`:** definition at ControllerFocusCoordinator:99-101; uses at PauseMenuView:213, 223, 231, 240, 476, 664.
- **iOS `MenuFocusRouter` path:** MenuScreen :101-103, :138-168, :180-189, :409-639.
- **Also keep:**
  - `.defaultFocus` :222 and :687
  - `.focusSection()` :300 and :665
  - `.onExitCommand` :191
  - The `focusRequest` reconcile :194-198
  - `.id(item.id)` :320, 468, 555

## Tests and render surface

**Existing tests are model-only.** There is no view-structure testing. The PNG tests are env-gated and `#if os(iOS) && DEBUG`.

**Renderer recipe:** PauseMenuSnapshotTests.swift:25-56 hosts the view in a `UIWindow` + `UIHostingController` and calls `drawHierarchy` at scale 2. ICubeDesignSnapshotTests.swift:67-84 does the same with `overrideUserInterfaceStyle`.

**Fixtures:**
- `MenuScreen(model:style:onBack:modal:)` accepts a hand-built `MenuModel(sections: [MenuSection(id:header:items:)])`.
- `SettingsSidebarShell(sections:searchIndex:nil, jumpToControllers:.constant(false))` takes fixtures built from `SettingsRootSection` / `SettingsLeafEntry` (SettingsRootModelBuilder.swift:6-43).
- `PauseMenuModelBuilder.make` is pure and can feed `MenuScreen(.tiles)` directly.

**Limits:**
- iOS cannot render the tvOS-only blocks.
- The `focusedID` in MenuScreen on iOS is private, so no forced focus is possible without a seam.

## Ratchet baseline

| File | Findings |
|---|---|
| MenuScreen | 17 |
| TileFace | 8 |
| InfoShelf | 2 |
| PauseMenuView | 43 |
| CheatsMenuView | 7 |
| SettingsSidebarShell | 1 |
| ControllerHubView | 0 |
| SettingsRootView | 0 |

## Gotchas

- The `count*110+40` tvOS confirm height must follow the new 72 pt minimum row height.
- `.custom` rows pass through unstyled.
- A destructive tile is `.red` today; the spec says to use the `destructive` role.
- Rows that change to `ICubeRowButtonStyle` inside a `List` need `.listRowBackground(Color.clear)` and possibly `.listRowInsets`.
