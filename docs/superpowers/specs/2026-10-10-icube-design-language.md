# iCube design language

**Status:** approved by the owner 2026-10-10, with the decisions and corrections at the end of this document.

**Scope:** tvOS, and iPad when a game controller is connected. Appearance is light **and** dark, following the system setting.
**Basis:** owner answers to the gap analysis (`ux-gap-analysis.md` §6):
- bundle a custom display face of iCube's own
- keep the 2° resting tilt
- iFly-style collapsible left rail
- keep light mode
- sectioned library
- keep the iCube card focus effect

Code paths are relative to `Source/iOS/App/Common/Swift/` at `d60805832e`.

## 1. Display face

The face is for chrome only: screen titles, section headers, rail and sidebar labels. Body text, rows, values and tags stay in SF / SF Mono.

**Fit.** Nintendo's GameCube/Wii-era system UI used rounded Japanese gothic type (the Wii menu is set in Fontworks Rodin). iFly's Chakra Petch is squared and techy. iCube should go the other way: **rounded**.

| Candidate | Licence | Why it fits | Weights needed | File size (approx.; confirm when downloading) |
|---|---|---|---|---|
| **M PLUS Rounded 1c** | SIL OFL 1.1 | Closest in spirit to the Wii/GameCube-era rounded gothic. **Covers Japanese** (kana and kanji), and iCube ships `ja.lproj`, so one face serves both languages | Medium (500), Bold (700) | About 3–3.5 MB per weight with the full JIS set, so about 7 MB in total. A Latin + kana + used-kanji subset (pyftsubset) is well under 1 MB per weight |
| Nunito | SIL OFL 1.1 | Rounded terminals, friendly but not childish, and holds up in uppercase with tracking at 24 pt. No Japanese: chrome strings in `ja` fall back to the system face | Medium (500), Bold (700) | About 130 KB per weight static (Latin/Cyrillic/Vietnamese) |
| Rubik | SIL OFL 1.1 | Geometric with softened corners, chunky like the GameCube logo cube. More "hardware" than "friendly". No Japanese | Medium (500), Bold (700) | About 140 KB per weight static |

**Recommendation: M PLUS Rounded 1c, Medium + Bold.** It is the only candidate that matches the era's type and also renders the Japanese UI in the same face. A Latin-only face would put Japanese chrome in a different font, which breaks the consistency rule this whole document exists for.
- Ship the full TTFs first.
- Add the subset step only if bundle size matters.

**Loading:**
- Register the files via `UIAppFonts` in `Project.swift`, copying iFly's pattern (`iFly/Project.swift:258-262,478-482`).
- Resolve the face in code with a registration check and a system-rounded fallback (`iFly Theme/DreamcastFont.swift:11-36`).
- Use `Font.custom(_:size:relativeTo:)` so the iPad sizes follow Dynamic Type.

## 2. Token sheet

### 2.1 Type: six roles, no other sizes

| Role | Face / weight | tvOS pt | iPad + controller pt (`relativeTo:`) | Used for |
|---|---|---|---|---|
| `title` | Display Bold | 48 | 34 (`.largeTitle`) | One in-body screen title per screen ("iCube", "Settings", the pause game title) |
| `section` | Display Bold, UPPERCASE, tracking 1.5 | 30 | 20 (`.title3`) | Library sections, settings groups, pause groups |
| `nav` | Display Medium, UPPERCASE, tracking 1.2 | 24 | 17 (`.headline`) | Rail rows, settings sidebar rows, the segment labels of a choice row |
| `body` | SF Regular; Semibold for titles | 29 | 17 (`.body`) | Row titles, card titles, tile titles, values, menu items |
| `detail` | SF Regular | 23 | 13 (`.footnote`) | Descriptions, help text, counts, subtitles |
| `tag` | SF Mono Medium, UPPERCASE, tracking 0.5 | 20 | 12 (`.caption`) | Game IDs, platform tags, numeric badges |

Text never gets a gradient fill or a shadow. The single exception is `title`, which may use the `title` colour pair in §2.4.

### 2.2 Spacing scale: 4 · 8 · 12 · 16 · 24 · 40 · 80

| Step | Used for |
|---|---|
| 4 | Gap between a label and its sub-label |
| 8 | Gap between an icon and its label; spacing between rail rows |
| 12 | Row vertical padding |
| 16 | Row horizontal padding; spacing between rows; tile padding |
| 24 | Spacing between sections; rail leading inset; spacing between tiles |
| 40 | Card grid gutters, horizontal and vertical. Today's 52 h / 40 v becomes 40/40. The card's 1.08 scale plus its 45 pt glow needs at least 40 |
| 80 | Content leading/trailing margin on tvOS, which matches the system safe area |

### 2.3 Corner radii: three

| Radius | Used for |
|---|---|
| 16 (continuous) | Card art, tile, panel (rail, popover-style sheet, info shelf) |
| 10 (continuous) | Row surface, icon badge, rail row highlight |
| capsule | Tags, badges, segment pills |

### 2.4 Line weights: two

| Weight | Used for |
|---|---|
| 1 pt, `hairline` colour | Panel and tile edge, section divider, the rail/sidebar-to-pane divider (replaces `Divider()`) |
| 4 pt, focus gradient | Focus ring on rows, tiles, rail and sidebar rows |

**Selection is shown by fill, never by a stroke.**

The card focus effect's own 8 pt ring and 2 pt inner highlight are frozen inside `.icubeCardFocus` (§2.7). They are not tokens and are used nowhere else.

### 2.5 Colour roles (light / dark)

| Role | Light | Dark | Notes |
|---|---|---|---|
| `accent` | `#3F56A4` | `#8EC5F9` | Today's DolphinTint asset. Marks selection and values |
| `focusGradient` | system cyan → `accent` → system purple | same (system colours adapt) | Focus only (from `GameGridItem.swift:512-517`) |
| `room` (3-stop, top-leading → bottom-trailing) | `#E6EDFA` → `#D6E3FA` → `#F5F7FF` | `#141F38` → `#0A0F26` → `#000000` | Today's gradient (`TVLibraryView.swift:762-783`) plus the existing orbs |
| `panel` | `.ultraThinMaterial` | `.ultraThinMaterial` | The only blur layer |
| `rowSurface` | `#0A0F26` at 5 % | `#FFFFFF` at 7 % | Row and tile fill on a panel or the room |
| `selectedFill` | `accent` at 20 % | `accent` at 20 % | Selected rail row, selected sidebar row, chosen segment |
| `hairline` | `#0A0F26` at 12 % | `#FFFFFF` at 10 % | 1 pt lines |
| `textPrimary` | `#0A0F26` | `#FFFFFF` | |
| `textSecondary` | `#0A0F26` at 65 % | `#FFFFFF` at 70 % | Detail, Off values |
| `textTertiary` | `#0A0F26` at 45 % | `#FFFFFF` at 45 % | Chevrons, disabled |
| `destructive` | system red | system red | Destructive rows and tiles |
| `title` | `textPrimary` → `accent` | `#FFFFFF` → `accent` | Top-down gradient, `title` role only |

### 2.6 Depth policy

| Effect | Yes / no, and where |
|---|---|
| Blur (material) | **One layer only:** `panel` sits between the room and the content (rail, sheets, info shelf, the pause scrim). Materials are never stacked; content on a panel uses `rowSurface` |
| Shadow | **Focus only:** the card's frozen glow and lift, and the row/tile glow (cyan at 50 %, radius 20, y 0). The card's frozen resting shadow (black 20 %, r8) is the one at-rest shadow. No panel, button or text shadows (remove `GameGridItem.swift:157,371-372,609`) |
| Emboss / bevel / inner highlight | **Never**, except the card's focused inner highlight and top sheen, which are part of the frozen effect |
| Gradient | `focusGradient` (focus rings), `title`, and `room`. Nothing else. The cover "case reflection" overlay (`GameGridItem.swift:486-493`) stays as card art, not as a pattern to reuse |

### 2.7 Motion and the iCube card focus effect (frozen, from today's code)

`.icubeCardFocus(isFocused:)` reproduces `GameGridItem.swift` exactly, with no visual change.

**Card container** (`:660-672`):
- scale 1 → **1.08**
- `rotation3DEffect` **2° at rest → 5° focused**, axis (0.1, 1, 0), perspective 1.0 → 0.8
- shadow black 0.2/r8/y4 → 0.4/r20/y12
- `spring(response: 0.4, dampingFraction: 0.8)`

**Art overlay** (`:507-543`):
- ring is a 4-stop linear gradient, top-leading → bottom-trailing: cyan 0.95, DolphinTint 0.9, purple 0.95, cyan 0.95
- ring width 0 → **8 pt**, radius 16 continuous
- glows: cyan 0.8 r25, blue 0.6 r35, purple 0.7 r45, eased over 0.6 s
- inner highlight: white 0.4, 2 pt, inset 4, eased over 0.4 s
- art shadow black 0.2/r8/y6 → 0.4/r20/y12

**Sheen** (`:545-551`): white 0.2 → clear, top to centre, shown only while focused.

**Z-order:** `zIndex` 1 while focused (`:786`).

**Inputs:** on tvOS it is driven by the existing `.focusable { }` callback (`:673-678`); on iPad, by `MenuFocusRouter`'s focused index. It is a modifier, not a ButtonStyle, because the card's tap, long-press-to-select, play/pause and context menu must stay as they are.

**Resting tilt (owner: keep 2°).** Today the art carries a second tilt inside the container: real covers 1° (`:499-503`) and the placeholder 3° (`:431-435`). The *visible* rest angle is therefore about 3° for real covers and about 5° for the placeholder. Decision needed (see the end of this document).

**Other motion:**

| Element | Focus | Timing |
|---|---|---|
| Row and rail | scale **1.04** | same spring |
| Tile | scale **1.06** | same spring |
| Selection change, rail expand/collapse (88 → 320 pt) | — | `easeInOut(0.2)` |

Nothing animates while a game runs: `EmulationQuiet` swaps the room to its static gradient.

## 3. Component rules

| Component | Rule, in tokens | Replaces |
|---|---|---|
| **Card** | Art 260×390 (`LibraryLayout.cardSize`), radius 16, `.icubeCardFocus`. Below it: title `body` Semibold, 1 line, minimum scale 0.75, `textPrimary`; then the ID as `tag` in a capsule filled with `rowSurface`. No gradient, no shadow, no stroke. The placeholder art shows the title once and never repeats the ID | `GameGridItem.swift:590-640` (title gradient and shadow, ID chip with a 0.5 stroke); the duplicate placeholder label |
| **Row** (settings, hub, lists, sheets) | `rowSurface` fill, radius 10. Padding 16 h / 12 v; minimum height 72 tvOS / 44 iPad. Title `body`. Description `detail` `textSecondary` *below* the title. Trailing: value (see Value) or a `textTertiary` chevron. Icon badge 44 (iPad 28), radius 10, tint at 15 %. **Within a section either every row has an icon or none does.** Focus: 4 pt `focusGradient` ring, row glow, scale 1.04, `.focusEffectDisabled()`, so there is no white capsule anywhere | `MenuScreen.swift` `rowLabel` `:330-365`, `tvRow` `:729-793`, `tvSteppedRow` `:805-829`; `TVLibraryView.swift` sheet lists `:1420-1437`; `TVCheatListView` rows |
| **Tile** (pause, hub) | `rowSurface` fill on the pause scrim (`panel`), radius 16, 1 pt `hairline`, padding 16, minimum height 180 tvOS / 96 iPad. Icon badge top-left; badge as `tag` in a capsule top-right; title `body` Semibold. Destructive tiles use `destructive` for icon and title. Focus: same ring, scale 1.06 | `MenuKit/TileFace.swift` (hard-coded fonts, `.red`, `.white`); `MenuScreen.swift` `gridCard` `:532-550` |
| **Section header** | `section` role in `textPrimary`, after a leading **accent bar**: a 6×(cap height) capsule filled with `accent`, no glow, gap 8. Spacing 24 above, 12 below. Library sections: Recently Played, Favorites, All Games, then one per platform | `TVLibraryView.swift:924-975` ("⭐ Favorites / Your championship collection", sparkles); grey `List` section headers in `MenuScreen` (`:481,515,651`); `SettingsSidebarShell.swift:130-133` |
| **Rail item** (library rail) | Icon (SF Symbol, weight light, 24 pt in a 32 pt column) plus a `nav` label shown only when expanded. Selected: `accent` icon and label on `selectedFill`, radius 10. Focused: row focus. The rail is a `panel` with radius 16 and a 1 pt `hairline`, inset 24 from the leading edge, its own `focusSection`. **The settings sidebar uses the same item, always expanded, at 320 pt** | `TVLibraryView.swift` toolbar buttons `:1411-1418`, `.navigationTitle` `:560`, tvOS `LibraryPlatformFilterBar` `:1700-1707`; `SettingsSidebarShell.swift:126-157` |
| **Popover / menu** | View and Sort are body-content `Menu`s with `.menuStyle(.button)` and a rail-item trigger (iFly `TVLibrarySidebar.swift:132-148`). The menu items are system-drawn: `Label(text, systemImage:)` only, no custom styling. **System menus and context menus are the one allowed place for the system focus capsule** | `tvToolbarSheetBody` sheets (`TVLibraryView.swift:1420-1437`), unless the on-device check fails, in which case these become `panel` sheets of Rows |
| **Toggle / value** | A toggle is a Row whose trailing value reads "On" (`body`, `accent`) or "Off" (`body`, `textSecondary`). Select flips it. **No checkmarks and no system switch.** Choice rows: one value as `‹ value ›` in `body` `accent`, stepped with left/right (today's compact picker). A short choice set may instead be segment pills: capsules with `selectedFill` plus `accent` text for the chosen one, `nav` labels. Numeric and ID values use `tag` | Checkmarks (`MenuScreen.swift:752-763`); the segmented `Picker` in cheats; grey trailing values |
| **Screen chrome** | Room background, an in-body `title`, and a `panel` for the rail or sidebar. No `.navigationTitle`. Buttons in empty states are Rows or Tiles | `Color.black` in `UI/Settings/SwiftUI/SettingsRootView.swift:56`; `.borderedProminent`/`.bordered` (`TVLibraryView.swift:1242-1278`) |

## 4. Enforcement

1. **One module.**
   - `MenuKit/ICubeDesign.swift` holds every token: type roles, spacing, radii, line weights, light/dark colours as dynamic `UIColor` providers, the motion constants, the Row and Tile focus `ButtonStyle`s, `.icubeCardFocus(isFocused:)`, `.icubePanel()` and `.icubeRoom()`.
   - Font files go in a new `Common/Resources/Fonts/`, registered through `UIAppFonts` in `Project.swift`.
   - The existing `MenuTheme` protocol and `MenuThemeKey` (`MenuKit/MenuTheme.swift:10-47`) are folded into it.
2. **Environment.** Views read tokens through `@Entry var icube: ICubeDesign = .standard`, never a global, so previews and tests can inject values. iPad-with-controller sets `@Entry var controllerDriven: Bool`, which selects the iPad column of the type table.
3. **Lint ratchet.** The script `scripts/lint_design_tokens.py` runs in CI from `.github/workflows/lint.yml`, beside `scripts/icube_config_lint.py`.
   - **It flags,** in `Common/**/*.swift` outside `MenuKit/ICubeDesign*.swift`:
     - `.font(.system(size:`
     - `.font(.<textStyle>`
     - `Font.custom(`
     - a numeric `cornerRadius:` or `lineWidth:`
     - `Color(red:`
     - `Color.(blue|cyan|purple|orange|yellow|green|pink)`
     - `.borderedProminent`
     - `.navigationTitle(` in tvOS code
   - **Ratchet, not a hard fail:** a committed baseline holds today's count per file. CI fails if any file's count goes up. Burned-down entries are removed from the baseline.
   - **Exempt:** touch-overlay/skin drawing, `Debug/`, Widgets/Live Activity (their own systems), and lines marked `// design-lint: allow <reason>`.
4. **Token tests** (`ICubeDesignTests`):
   - six type roles, three radii, two line weights
   - every text tier against every `room` stop and `rowSurface` passes WCAG AA (4.5:1 for `detail` and `tag`, 3:1 for `section` and `title`) in **both** appearances
   - the display face is registered in the bundle
5. **Snapshots.** One PNG per renderer path, in light and dark, using the existing DEBUG snapshot recipe (run `tuist generate` first or new tests silently skip):
   - `MenuScreen` `.list`, `.tiles` and `.grid`
   - the settings sidebar
   - the library rail, collapsed and expanded
   - the card, focused and at rest

## 5. Build order

1. **Design module.** Size: **M**. Risk: low.
   - `ICubeDesign.swift`; fonts and `UIAppFonts`; `.icubeCardFocus` extracted with a before/after pixel check of the card; the Row/Tile focus styles; `.icubeRoom()` (from `TVLibraryView.swift:733-783` + `LibraryAnimatedBackground.swift`); the lint baseline; the token tests.
   - Must stay: card interaction code untouched, `EmulationQuiet`.
2. **One restyle pass.** Size: **L**. Risk: high.
   - Covers `MenuScreen`'s tvOS row, tile and grid paths, the settings sidebar and root background, the controller hub, and pause (header plus the `.list`/`.grid` sub-screens).
   - Try keeping `List` first, with the Row style and `.listRowBackground(.clear)`, so focus-follow scrolling survives.
   - Must stay: composite picker focus ids (`MenuScreen.swift:697-706`), picker explosion, compact-picker `onMoveCommand`, `settingsPaneBack`, `BackCoalescer`, `PauseArbiter`, `.claimsController()`, the iOS `MenuFocusRouter` path.
3. **tvOS library on the left rail, with sections.** Size: **L**. Risk: medium-high.
   - Move the new shell into `TVLibraryShell.swift`. Rail items: Search (inline), My Library / platforms, Select, Import, View and Sort (`Menu`), Settings.
   - Sections: Recently Played (`LastPlayedStore`), Favorites, All Games, one per platform. The batch bar sits inside the content column.
   - Check body `Menu` presentation on a device first.
   - Must stay: the `EmulationScreen` launch path, context-menu actions, long-press select, play/pause, the GC handlers (`TVLibraryView.swift:686-690,1134-1169`).
4. **iPad with a controller.** Size: **M**. Risk: medium.
   - On controller connect at regular width, swap in the item 3 shell at the iPad type column, driven by `MenuFocusRouter` feeding `.icubeCardFocus`.
   - Light/dark follow the system.
   - Touch layout is unchanged with no controller; switching live on connect/disconnect must not lose state.

## Decisions (owner, 2026-10-10)

1. **Resting tilt: exactly 2°.** Remove the inner art tilts (real cover 1°, `GameGridItem.swift:499-503`; placeholder 3°, `:431-435`). The container's 2° → 5° is the only tilt.
2. **Font: ship the full files, no subsetting.** M PLUS Rounded 1c Medium (3,432,624 B) and Bold (3,542,592 B) from `google/fonts`, `ofl/mplusrounded1c`. Inside the files the family is **`Rounded Mplus 1c`** and the PostScript names are **`RoundedMplus1c-Medium`** and **`RoundedMplus1c-Bold`** (read with fontTools). Copyright line: "Copyright 2016 The Rounded M+ Project Authors."; the OFL 1.1 text ships beside the files as `OFL.txt`.
3. **Menu fallback: yes.** If body `Menu` does not present on device, View and Sort become `panel` sheets of Rows.

## Corrections found while planning (2026-10-10)

1. **Light `textTertiary` is 50 %, not 45 %.** At 45 % it measures 2.83–3.01:1 against the light `room` stops and `rowSurface`, below the 3:1 floor for chevrons (non-text UI) and disabled text. 50 % measures ≥ 3.26:1. Dark stays 45 % (≥ 4.01:1).
2. **Light `accent` text on `selectedFill` measures 3.67–4.76:1.** That passes 3:1 for `nav` labels (large text at both sizes) but not 4.5:1 for `body`. Rule: on `selectedFill`, `accent` is used only for `nav` labels and icons; a `body` value on a selected row uses `textPrimary`. Not part of the token tests (no test background is `selectedFill`).
3. **The lint ratchet runs from `tests.yml`, not `lint.yml`.** Both `lint.yml` jobs are `continue-on-error` except on pull requests, and work lands on `develop` directly, so a ratchet there would never fail. `scripts/icube_config_lint.py` is not run from `lint.yml` either. The blocking checkers live in `Source/iOS/App/Project/Scripts/` and run as steps in `tests.yml` (`check_button_types.py`, `check_localized_keys.py --check`); the ratchet is `Source/iOS/App/Project/Scripts/check_design_tokens.py --check`, a step beside them.
4. **`AccentColor` is not `accent`.** The app's `AccentColor` asset is `#8EC5F9` in both appearances; the `accent` role is the adaptive `DolphinTint` asset (`#3F56A4` / `#8EC5F9`). The menu kit draws with `AccentColor` today and keeps it until step 2 restyles it.
5. **`controllerDriven` lands with step 4**, the first code that reads it. Until then `font(_:)` picks the tvOS column on tvOS and the iPad column on iOS.
