# tvOS redesign completion, plan B: library polish

> Lean plan by owner ruling (2026-10-11, velocity mode): tasks name files, token rules and acceptance; implementers read the code and write it without builds. Spec: `docs/superpowers/specs/2026-10-11-tvos-redesign-completion-design.md` §5. Plan A landed on develop at `be18384083` (uncompiled).

**Goal:** the tvOS library reads like iFly's: an in-body title, shelf headers on every view, card type on the tokens, a rail with a visible edge, the animated room by default, and a room that is not static.

**Global constraints:** as plan A (`Source/iOS/App/` paths, tokens only, tvOS-only behind `#if os(tvOS)`, iPhone/iPad touch pixel-identical except the animated default, no AI trailers). The card focus effect (`.icubeCardFocus`/`.icubeCardArtFocus`) is frozen: do not change its numbers.

## Tasks (parallel, disjoint files)

### B1 — Library title, shelf headers, empty states (`Common/Swift/TVLibraryView.swift`)
1. tvOS only: above the content column (`libraryView_tvOS`, ~882) draw `ICubeLeafHeader(title: "iCube", subtitle: <view · count>)` where subtitle is `"\(L("My Library"))"` for home, and `"\(L("All Games")) · N"`, `"GameCube · N"`, `"Wii · N"` for the grid views (N = `displayGames.count`). Put the subtitle rule in a pure `static func libraryHeaderSubtitle(destination: TVLibraryRailDestination, count: Int) -> String` on `TVLibraryView` and add a test for it in `DolphiniOSTests/LibrarySectionsTests.swift`. Animate text changes with `ICubeDesign.Motion.selection`.
2. The All Games and per-platform grids get one `TVLibrarySectionHeader(title:)` above the `LazyVGrid` (same component the home shelves use), titled `L("All Games")`, "GameCube", "Wii".
3. `emptyLibraryView` (~1207) and `filteredEmptyLibraryView` (~1275), tvOS branch only: replace `.borderedProminent` buttons with `Button { } label: { … }.buttonStyle(ICubeRowButtonStyle())` rows and `.icubeText(.body)` / `.icubeText(.detail)` text in `ICubeDesign.color(.textPrimary/.textSecondary)`. Keep the iOS branch untouched.
4. Line ~266: `@AppStorage(ConfigInterfaceDefaultsKey.backgroundStyle) private var backgroundStyle: BackgroundStyle = .gradient` → default `.animated` (B3 changes the enum's fallback; this is the AppStorage side).
5. Drop the tvOS `.navigationTitle(... "iCube Library")` at ~563 (keep it on iOS).

### B2 — Card type and rail edge (`Common/Swift/GameGridItem.swift`, `Common/Swift/TVLibraryRail.swift`)
1. `GameGridItem.swift` ~350–380 (the title under the art) and the ID chip: tvOS branch uses `.icubeText(.body)` + `.fontWeight(.semibold)`, `lineLimit(1)`, `minimumScaleFactor(0.75)`, `ICubeDesign.color(.textPrimary)`, no gradient fill, no shadow; the ID in `.icubeText(.tag)` inside a `Capsule().fill(ICubeDesign.color(.rowSurface))`, no stroke. Leave the art, the case reflection overlay, the focus effect and the iOS branch alone. Lines 151–157 (selection ring/checkmark for multi-select) stay.
2. `TVLibraryRail.swift`: the rail already calls `.icubePanel()` (which draws the hairline); make the selected row's icon and label `ICubeDesign.color(.accent)` (today only the fill changes) and confirm expanded width uses `ICubeDesign.Motion.railExpandedWidth` (320) and collapsed `railCollapsedWidth` (88); replace any literal widths.

### B3 — Animated default and room motion (`Common/UI/Settings/SwiftUI/SettingsEnums.swift`, `Common/Swift/LibraryAnimatedBackground.swift`, `DolphiniOSTests/SettingsEnumsTests.swift`)
1. `LibraryBackgroundStyle`: add `static let `default`: LibraryBackgroundStyle = .animated` and make `from(stored:)` fall back to it. Test: `test_default_isAnimated` and `test_fromUnknown_fallsBackToDefault`.
2. `LibraryAnimatedBackground`: add a slow hue rotation (90 s, linear, repeat forever) on the accent orb between the accent and system purple; wrap all drift and hue animations so that `@Environment(\.accessibilityReduceMotion)` true renders the static orbs with no animation. Keep the file's existing deterministic `unit(_:salt:)` layout.

## Acceptance (deferred to the compile/screenshot pass)
tvOS compile; `check_design_tokens.py --check` then `--update`; `tvos_screens.sh` library-* captures light and dark; `LibrarySectionsTests`, `SettingsEnumsTests`, `ICubeCardFocusTests` green.
