# iCube design module (step 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add one design module (`ICubeDesign`) that owns every type, spacing, radius, line, colour, motion and focus token in the design spec. Fold the menu kit's `MenuTheme` into it, extract the iCube card focus effect into it, and add a CI ratchet that stops new hard-coded styling. The only visible change is that cards rest at exactly 2°.

**Architecture:**
- The tokens live in `Common/Swift/MenuKit/ICubeDesign*.swift`. The adaptive colours are `UIColor` providers, so tests can resolve them per appearance.
- Views read the instance values through `@Environment(\.icube)`.
- The bundled display face is M PLUS Rounded 1c, with a system-rounded fallback.
- A Python ratchet counts styling literals per file against a committed baseline. It runs in `tests.yml` beside the other blocking checkers.

**Tech Stack:** SwiftUI and UIKit (iOS 17 / tvOS 17); XCTest in the iOS-only `iCubeTests` target; Tuist; Python 3 (stdlib only).

**Spec:** `docs/superpowers/specs/2026-10-10-icube-design-language.md`. Read §2–§5 and the "Decisions" and "Corrections" sections at the end. Where this plan and the spec disagree, the Corrections section wins.

## Global Constraints

- **No visual change in step 1, except the resting tilt.** Every existing value stays as it is today, including the menu kit's `AccentColor`, tile heights, fonts and the `FocusButtonStyle` spring (0.3, 0.7). Restyling is step 2. The only allowed visible change is Task 5: cards rest at exactly 2°. A reviewer rejects any other visible difference.
- **Card interaction code stays untouched:** `.focusable { }`, `.onTapGesture`, `.onLongPressGesture`, `.onPlayPauseCommand`, `.contextMenu`, `.zIndex`, `selectionOverlay`.
- **`EmulationQuiet` stays.** The animated room never animates while a game runs.
- **Paths.** All paths are relative to `Source/iOS/App/` unless they start with `docs/` or `.github/`.
- **Platforms.** Code compiles for iOS 17 and tvOS 17. Guard tvOS-only APIs with `#if os(tvOS)`. `.focusEffectDisabled()` exists on both platforms.
- **Style.** 2-space indent and the `// Copyright 2026 DolphiniOS Project` / `// SPDX-License-Identifier: GPL-2.0-or-later` header (match `MenuKit/FocusButtonStyle.swift`). Only `ICubeDesign*.swift` may contain the raw numbers and system colours the ratchet flags.
- **New files need `tuist generate --no-open`** (run in `Source/iOS/App`) before building, or new tests silently do not run.
- **Test command** (simulator iPhone 17 Pro):

  ```bash
  cd Source/iOS/App && make test TEST_ARGS="-only-testing:iCubeTests/<Class>"
  ```

  It passes when the log shows `** TEST SUCCEEDED **` and `Executed N tests, with 0 failures` with N > 0.
- **tvOS compile check** (run it after the iOS test, never at the same time):

  ```bash
  cd Source/iOS/App && xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -configuration "Debug (Non-Jailbroken)" -destination generic/platform=tvOS -derivedDataPath build-Xcode-tvos CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E ": error:|BUILD (SUCCEEDED|FAILED)"
  ```

- **Build hygiene:**
  - Never run two xcodebuilds at once.
  - Never `pkill xcodebuild`.
  - Local builds rewrite the tracked `build/xcframework/` slices. Run `git checkout -- build/xcframework` before every commit, and never stage those files.
- **Commit rules:**
  - Use conventional commits.
  - Add **no** `Co-Authored-By` or other LLM trailer.
  - Stage files by name; never `git add -A`.
  - **DO NOT git reset / rebase / push / touch develop.**
- **Localized strings.** Any new `L("...")` key needs identity entries in `Common/UI/Localization/{en,ja}.lproj/Core.strings`. This plan adds none.

## File Structure

| File | Responsibility |
|---|---|
| `Common/Resources/Fonts/RoundedMplus1c-Medium.ttf`, `RoundedMplus1c-Bold.ttf`, `OFL.txt` | Display face (OFL 1.1) and its licence |
| `DolphiniOS/Info.plist` | `UIAppFonts` key (the one app target builds iOS and tvOS from this plist) |
| `Project.swift` | Font files added to the iCube target's `resources` |
| `Common/Swift/MenuKit/ICubeDesign.swift` | The `ICubeDesign` struct, `\.icube` environment value, type roles and face, spacing, radii, lines, motion |
| `Common/Swift/MenuKit/ICubeDesign+Color.swift` | Colour roles (adaptive `UIColor`), room stops, focus gradient |
| `Common/Swift/MenuKit/ICubeDesign+Focus.swift` | Row and Tile `ButtonStyle`s, `.icubePanel()`, `.icubeCardFocus` / `.icubeCardArtFocus` |
| `Common/Swift/MenuKit/ICubeDesign+Room.swift` | `ICubeRoom` (clean / gradient / animated), moved out of `TVLibraryView` |
| `Common/Swift/MenuKit/MenuTheme.swift` | **Deleted** in Task 3 (folded into `ICubeDesign`) |
| `Project/Scripts/check_design_tokens.py`, `design_tokens_baseline.json`, `test_check_design_tokens.py` | Lint ratchet, its baseline, its unit tests |
| `DolphiniOSTests/ICubeDesignTests.swift` | Counts, contrast, font registration |
| `DolphiniOSTests/ICubeCardFocusTests.swift` | Pixel check: frozen card effect equals the pre-extraction code |
| `DolphiniOSTests/ICubeDesignSnapshotTests.swift` | Env-gated PNGs of the card, Row, Tile, panel and room, light and dark |

---

### Task 1: Display face, type roles and the `ICubeDesign` skeleton

**Files:**
- Create: `Common/Resources/Fonts/RoundedMplus1c-Medium.ttf`, `Common/Resources/Fonts/RoundedMplus1c-Bold.ttf`, `Common/Resources/Fonts/OFL.txt`
- Create: `Common/Swift/MenuKit/ICubeDesign.swift`
- Modify: `DolphiniOS/Info.plist` (add `UIAppFonts`)
- Modify: `Project.swift` (iCube target `resources:` list, around line 302)
- Test: `DolphiniOSTests/ICubeDesignTests.swift`

**Interfaces:**
- Produces:
  - `struct ICubeDesign` with `static let standard`
  - `enum ICubeDesign.TypeRole: CaseIterable { case title, section, nav, body, detail, tag }`
  - `ICubeDesign.DisplayFace.family` / `.isAvailable` / `.postScriptName(bold:)`
  - `func ICubeDesign.font(_ role: TypeRole) -> Font`
  - `View.icubeText(_ role: ICubeDesign.TypeRole) -> some View`, which applies font, uppercase and tracking

- [ ] **Step 1: Fetch the font files and verify them**

  ```bash
  mkdir -p Source/iOS/App/Common/Resources/Fonts && cd Source/iOS/App/Common/Resources/Fonts
  curl -fsSL -o RoundedMplus1c-Medium.ttf https://raw.githubusercontent.com/google/fonts/main/ofl/mplusrounded1c/MPLUSRounded1c-Medium.ttf
  curl -fsSL -o RoundedMplus1c-Bold.ttf https://raw.githubusercontent.com/google/fonts/main/ofl/mplusrounded1c/MPLUSRounded1c-Bold.ttf
  shasum -a 256 RoundedMplus1c-Medium.ttf RoundedMplus1c-Bold.ttf
  ```

  The expected hashes are:
  - `adfde1b6bae58719c4e0144612a94232e72fc5ca655c4722165fe88d06521a70  RoundedMplus1c-Medium.ttf` (3,432,624 B)
  - `c358630584e8e2d8fbd6121d0f4693255ffef6d1e6d4f3441fd6e5a963a11f9e  RoundedMplus1c-Bold.ttf` (3,542,592 B)

  Stop if either hash differs.

  The family has no `OFL.txt` upstream. Take the sibling M+ family's copy and fix the copyright line:

  ```bash
  curl -fsSL https://raw.githubusercontent.com/google/fonts/main/ofl/mplus1p/OFL.txt \
    | sed '1s/.*/Copyright 2016 The Rounded M+ Project Authors./' > OFL.txt
  head -3 OFL.txt
  ```

  Expected first line: `Copyright 2016 The Rounded M+ Project Authors.` The licence text follows.

- [ ] **Step 2: Register the fonts**

  In `DolphiniOS/Info.plist`, add this inside the top-level `<dict>`, next to the other `UI*` keys:

  ```xml
  	<key>UIAppFonts</key>
  	<array>
  		<string>RoundedMplus1c-Medium.ttf</string>
  		<string>RoundedMplus1c-Bold.ttf</string>
  	</array>
  ```

  In `Project.swift`, in the iCube target's `resources: [` list (after `"Common/DolphinAssets.xcassets",`), add:

  ```swift
          // Display face for chrome (design spec §1). Flat in the bundle so UIAppFonts names resolve.
          "Common/Resources/Fonts/*.ttf",
          "Common/Resources/Fonts/OFL.txt",
  ```

- [ ] **Step 3: Write the failing test**

  Create `DolphiniOSTests/ICubeDesignTests.swift`:

  ```swift
  // Copyright 2026 DolphiniOS Project
  // SPDX-License-Identifier: GPL-2.0-or-later

  import SwiftUI
  import UIKit
  import XCTest

  @testable import iCube

  final class ICubeDesignTests: XCTestCase {
    func test_sixTypeRoles() {
      XCTAssertEqual(ICubeDesign.TypeRole.allCases, [.title, .section, .nav, .body, .detail, .tag])
    }

    func test_displayFaceIsRegistered() {
      XCTAssertTrue(UIFont.familyNames.contains(ICubeDesign.DisplayFace.family),
                    "UIAppFonts did not register \(ICubeDesign.DisplayFace.family)")
      XCTAssertNotNil(UIFont(name: ICubeDesign.DisplayFace.postScriptName(bold: false), size: 12))
      XCTAssertNotNil(UIFont(name: ICubeDesign.DisplayFace.postScriptName(bold: true), size: 12))
      XCTAssertTrue(ICubeDesign.DisplayFace.isAvailable)
    }

    func test_typeTable_matchesSpec() {
      // (tvOS pt, iPad pt) per spec §2.1.
      let expected: [ICubeDesign.TypeRole: (CGFloat, CGFloat)] = [
        .title: (48, 34), .section: (30, 20), .nav: (24, 17), .body: (29, 17), .detail: (23, 13), .tag: (20, 12),
      ]
      for role in ICubeDesign.TypeRole.allCases {
        let spec = ICubeDesign.TypeSpec.of(role)
        XCTAssertEqual(spec.tvSize, expected[role]!.0, "\(role) tvOS size")
        XCTAssertEqual(spec.padSize, expected[role]!.1, "\(role) iPad size")
      }
      XCTAssertTrue(ICubeDesign.TypeSpec.of(.section).uppercase)
      XCTAssertTrue(ICubeDesign.TypeSpec.of(.nav).uppercase)
      XCTAssertTrue(ICubeDesign.TypeSpec.of(.tag).uppercase)
      XCTAssertFalse(ICubeDesign.TypeSpec.of(.body).uppercase)
      XCTAssertEqual(ICubeDesign.TypeSpec.of(.section).tracking, 1.5)
      XCTAssertEqual(ICubeDesign.TypeSpec.of(.nav).tracking, 1.2)
      XCTAssertEqual(ICubeDesign.TypeSpec.of(.tag).tracking, 0.5)
    }
  }
  ```

- [ ] **Step 4: Run the test and confirm it fails**

  Run:

  ```bash
  cd Source/iOS/App && tuist generate --no-open && make test TEST_ARGS="-only-testing:iCubeTests/ICubeDesignTests"
  ```

  Expected: a build failure, `cannot find 'ICubeDesign' in scope`.

- [ ] **Step 5: Implement `ICubeDesign.swift`**

  ```swift
  // Common/Swift/MenuKit/ICubeDesign.swift
  // Copyright 2026 DolphiniOS Project
  // SPDX-License-Identifier: GPL-2.0-or-later

  import SwiftUI
  import UIKit

  /// Every design token iCube draws its tvOS and controller-driven chrome with
  /// (docs/superpowers/specs/2026-10-10-icube-design-language.md). Raw sizes, radii, line widths and
  /// colours live only in `ICubeDesign*.swift`; `Project/Scripts/check_design_tokens.py` ratchets the
  /// rest of `Common/` toward zero. Views read the instance through `@Environment(\.icube)` so
  /// previews and tests can inject values.
  struct ICubeDesign {
    static let standard = ICubeDesign()

    // MARK: Type

    /// The six type roles (spec §2.1). There are no other text sizes.
    enum TypeRole: CaseIterable {
      case title, section, nav, body, detail, tag
    }

    enum Face { case displayBold, displayMedium, system, mono }

    struct TypeSpec {
      let face: Face
      let tvSize: CGFloat
      let padSize: CGFloat
      let relativeTo: Font.TextStyle
      let uppercase: Bool
      let tracking: CGFloat

      static func of(_ role: TypeRole) -> TypeSpec {
        switch role {
        case .title: TypeSpec(face: .displayBold, tvSize: 48, padSize: 34, relativeTo: .largeTitle, uppercase: false, tracking: 0)
        case .section: TypeSpec(face: .displayBold, tvSize: 30, padSize: 20, relativeTo: .title3, uppercase: true, tracking: 1.5)
        case .nav: TypeSpec(face: .displayMedium, tvSize: 24, padSize: 17, relativeTo: .headline, uppercase: true, tracking: 1.2)
        case .body: TypeSpec(face: .system, tvSize: 29, padSize: 17, relativeTo: .body, uppercase: false, tracking: 0)
        case .detail: TypeSpec(face: .system, tvSize: 23, padSize: 13, relativeTo: .footnote, uppercase: false, tracking: 0)
        case .tag: TypeSpec(face: .mono, tvSize: 20, padSize: 12, relativeTo: .caption, uppercase: true, tracking: 0.5)
        }
      }
    }

    /// M PLUS Rounded 1c (SIL OFL 1.1), bundled via `UIAppFonts`. Names read from the TTFs.
    enum DisplayFace {
      static let family = "Rounded Mplus 1c"

      /// False if registration failed; the roles then fall back to the rounded system face.
      static let isAvailable: Bool = UIFont.familyNames.contains(family)

      static func postScriptName(bold: Bool) -> String {
        bold ? "RoundedMplus1c-Bold" : "RoundedMplus1c-Medium"
      }
    }

    /// The font for `role`: the tvOS column on tvOS; on iOS the iPad column, as the matching text
    /// style so it follows Dynamic Type (17/13/12 pt at the default size).
    func font(_ role: TypeRole) -> Font {
      let spec = TypeSpec.of(role)
      #if os(tvOS)
      let size = spec.tvSize
      #else
      let size = spec.padSize
      #endif
      switch spec.face {
      case .displayBold, .displayMedium:
        let bold = spec.face == .displayBold
        guard DisplayFace.isAvailable else {
          return .system(size: size, weight: bold ? .bold : .medium, design: .rounded)
        }
        #if os(tvOS)
        return .custom(DisplayFace.postScriptName(bold: bold), fixedSize: size)
        #else
        return .custom(DisplayFace.postScriptName(bold: bold), size: size, relativeTo: spec.relativeTo)
        #endif
      case .system:
        #if os(tvOS)
        return .system(size: size)
        #else
        return .system(spec.relativeTo)
        #endif
      case .mono:
        #if os(tvOS)
        return .system(size: size, weight: .medium, design: .monospaced)
        #else
        return .system(spec.relativeTo, design: .monospaced, weight: .medium)
        #endif
      }
    }
  }

  extension EnvironmentValues {
    @Entry var icube: ICubeDesign = .standard
  }

  private struct ICubeTextModifier: ViewModifier {
    let role: ICubeDesign.TypeRole
    @Environment(\.icube) private var icube

    func body(content: Content) -> some View {
      let spec = ICubeDesign.TypeSpec.of(role)
      content
        .font(icube.font(role))
        .textCase(spec.uppercase ? .uppercase : nil)
        .tracking(spec.tracking)
    }
  }

  extension View {
    /// Sets `role`'s font, case and tracking (spec §2.1).
    func icubeText(_ role: ICubeDesign.TypeRole) -> some View {
      modifier(ICubeTextModifier(role: role))
    }
  }
  ```

  `body` is SF Regular; a caller that needs the Semibold title weight adds `.fontWeight(.semibold)`.

- [ ] **Step 6: Run the test and confirm it passes**

  Run:

  ```bash
  cd Source/iOS/App && tuist generate --no-open && make test TEST_ARGS="-only-testing:iCubeTests/ICubeDesignTests"
  ```

  Expected: `Executed 3 tests, with 0 failures`.

  If `test_displayFaceIsRegistered` fails, check `unzip -l` on the built `.app` (or `ls` it) for `RoundedMplus1c-Medium.ttf` at the bundle root, and check the `UIAppFonts` spelling.

- [ ] **Step 7: tvOS compile check** (the command in Global Constraints). Expected: `BUILD SUCCEEDED`.

- [ ] **Step 8: Commit**

  ```bash
  git checkout -- build/xcframework
  git add Source/iOS/App/Common/Resources/Fonts Source/iOS/App/DolphiniOS/Info.plist Source/iOS/App/Project.swift \
    Source/iOS/App/Common/Swift/MenuKit/ICubeDesign.swift Source/iOS/App/DolphiniOSTests/ICubeDesignTests.swift
  git commit -m "feat(design): bundle M PLUS Rounded 1c and add ICubeDesign type roles"
  ```

---

### Task 2: Spacing, radii, lines, colour roles, motion, with contrast tests

**Files:**
- Modify: `Common/Swift/MenuKit/ICubeDesign.swift` (add spacing, radius, line, motion)
- Create: `Common/Swift/MenuKit/ICubeDesign+Color.swift`
- Modify: `DolphiniOSTests/ICubeDesignTests.swift`

**Interfaces:**
- Consumes: `ICubeDesign` (Task 1)
- Produces:
  - `enum ICubeDesign.Spacing: CGFloat, CaseIterable { case xxs = 4, xs = 8, s = 12, m = 16, l = 24, xl = 40, xxl = 80 }`
  - `enum ICubeDesign.Radius: CGFloat, CaseIterable { case large = 16, small = 10 }`. The third radius is `Capsule()`.
  - `enum ICubeDesign.Line: CGFloat, CaseIterable { case hairline = 1, focus = 4 }`
  - `enum ICubeDesign.Motion` with:
    - `static let focusSpring: Animation`, spring(0.4, 0.8)
    - `static let selection: Animation`, easeInOut(0.2)
    - `static let rowFocusScale: CGFloat = 1.04`
    - `static let tileFocusScale: CGFloat = 1.06`
    - `static let railCollapsedWidth: CGFloat = 88`
    - `static let railExpandedWidth: CGFloat = 320`
  - `enum ICubeColorRole: CaseIterable { case accent, rowSurface, selectedFill, hairline, textPrimary, textSecondary, textTertiary, destructive }`
  - `static func ICubeDesign.uiColor(_ role: ICubeColorRole) -> UIColor`, an adaptive colour
  - `static func ICubeDesign.color(_ role: ICubeColorRole) -> Color`
  - `static let ICubeDesign.roomStops: [UIColor]`, 3 adaptive stops
  - `static var ICubeDesign.focusGradient: LinearGradient`
  - `static var ICubeDesign.titleGradient: LinearGradient`

- [ ] **Step 1: Write the failing tests**

  Append these to `ICubeDesignTests`:

  ```swift
    func test_scaleRadiiLines() {
      XCTAssertEqual(ICubeDesign.Spacing.allCases.map(\.rawValue), [4, 8, 12, 16, 24, 40, 80])
      XCTAssertEqual(ICubeDesign.Radius.allCases.map(\.rawValue), [16, 10]) // plus Capsule()
      XCTAssertEqual(ICubeDesign.Line.allCases.map(\.rawValue), [1, 4])
    }

    func test_colorRoles_matchSpecHex() {
      let light = UITraitCollection(userInterfaceStyle: .light)
      let dark = UITraitCollection(userInterfaceStyle: .dark)
      XCTAssertEqual(Self.rgba(ICubeDesign.uiColor(.accent), light), [0x3F, 0x56, 0xA4, 255])
      XCTAssertEqual(Self.rgba(ICubeDesign.uiColor(.accent), dark), [0x8E, 0xC5, 0xF9, 255])
      XCTAssertEqual(Self.rgba(ICubeDesign.uiColor(.textPrimary), light), [0x0A, 0x0F, 0x26, 255])
      XCTAssertEqual(Self.rgba(ICubeDesign.uiColor(.textPrimary), dark), [0xFF, 0xFF, 0xFF, 255])
      XCTAssertEqual(ICubeDesign.roomStops.map { Self.rgba($0, light) },
                     [[0xE6, 0xED, 0xFA, 255], [0xD6, 0xE3, 0xFA, 255], [0xF5, 0xF7, 0xFF, 255]])
      XCTAssertEqual(ICubeDesign.roomStops.map { Self.rgba($0, dark) },
                     [[0x14, 0x1F, 0x38, 255], [0x0A, 0x0F, 0x26, 255], [0x00, 0x00, 0x00, 255]])
    }

    /// Spec §4.4 with Correction 1. Each text tier, composited over each background, against its
    /// floor: 4.5:1 for body/detail/tag text, 3:1 for section/title (large) and tertiary (chevrons,
    /// disabled). Backgrounds are the three room stops and rowSurface over each stop, in both
    /// appearances.
    func test_contrast_meetsWCAG_AA_inBothAppearances() {
      let tiers: [(ICubeColorRole, Double)] = [
        (.textPrimary, 4.5), (.textSecondary, 4.5), (.accent, 4.5), (.textTertiary, 3.0),
      ]
      for style in [UIUserInterfaceStyle.light, .dark] {
        let traits = UITraitCollection(userInterfaceStyle: style)
        let surface = ICubeDesign.uiColor(.rowSurface).resolvedColor(with: traits)
        for stop in ICubeDesign.roomStops.map({ $0.resolvedColor(with: traits) }) {
          for background in [stop, Self.over(surface, stop)] {
            for (role, floor) in tiers {
              let text = Self.over(ICubeDesign.uiColor(role).resolvedColor(with: traits), background)
              let ratio = Self.contrast(text, background)
              XCTAssertGreaterThanOrEqual(ratio, floor, "\(role) in \(style == .dark ? "dark" : "light") = \(ratio)")
            }
          }
        }
      }
    }

    // MARK: Helpers

    private static func rgba(_ color: UIColor, _ traits: UITraitCollection) -> [Int] {
      var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
      color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
      return [r, g, b, a].map { Int(($0 * 255).rounded()) }
    }

    /// `top` alpha-composited over opaque `bottom`.
    private static func over(_ top: UIColor, _ bottom: UIColor) -> UIColor {
      var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
      var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
      top.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
      bottom.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
      return UIColor(red: tr * ta + br * (1 - ta), green: tg * ta + bg * (1 - ta), blue: tb * ta + bb * (1 - ta), alpha: 1)
    }

    private static func luminance(_ color: UIColor) -> Double {
      var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
      color.getRed(&r, green: &g, blue: &b, alpha: &a)
      func lin(_ c: CGFloat) -> Double { let c = Double(c); return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
      return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    private static func contrast(_ a: UIColor, _ b: UIColor) -> Double {
      let (la, lb) = (luminance(a), luminance(b))
      return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
  ```

- [ ] **Step 2: Run the tests and confirm they fail.** Use the Task 1 test command. Expected: a build failure, `type 'ICubeDesign' has no member 'Spacing'`.

- [ ] **Step 3: Add the tokens to `ICubeDesign.swift`**

  Add these inside `struct ICubeDesign`, after the type section:

  ```swift
    // MARK: Spacing, radii, lines (spec §2.2–2.4)

    enum Spacing: CGFloat, CaseIterable {
      case xxs = 4, xs = 8, s = 12, m = 16, l = 24, xl = 40, xxl = 80
    }

    /// Card art, tile and panel use `large`; row surface, icon badge and rail highlight use `small`.
    /// The third radius is `Capsule()`.
    enum Radius: CGFloat, CaseIterable {
      case large = 16, small = 10
    }

    /// `hairline` in the hairline colour; `focus` in the focus gradient. Selection is fill, never stroke.
    enum Line: CGFloat, CaseIterable {
      case hairline = 1, focus = 4
    }

    // MARK: Motion (spec §2.7)

    enum Motion {
      static let focusSpring = Animation.spring(response: 0.4, dampingFraction: 0.8)
      static let selection = Animation.easeInOut(duration: 0.2)
      static let rowFocusScale: CGFloat = 1.04
      static let tileFocusScale: CGFloat = 1.06
      static let railCollapsedWidth: CGFloat = 88
      static let railExpandedWidth: CGFloat = 320
    }
  ```

- [ ] **Step 4: Create `ICubeDesign+Color.swift`**

  ```swift
  // Common/Swift/MenuKit/ICubeDesign+Color.swift
  // Copyright 2026 DolphiniOS Project
  // SPDX-License-Identifier: GPL-2.0-or-later

  import SwiftUI
  import UIKit

  /// The colour roles of spec §2.5. Each is an adaptive `UIColor`, so it follows light and dark mode
  /// and tests can resolve either appearance.
  enum ICubeColorRole: CaseIterable {
    case accent, rowSurface, selectedFill, hairline, textPrimary, textSecondary, textTertiary, destructive
  }

  extension ICubeDesign {
    private static let ink = UIColor(red: 0x0A / 255, green: 0x0F / 255, blue: 0x26 / 255, alpha: 1)

    private static func adaptive(light: UIColor, dark: UIColor) -> UIColor {
      UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    private static func hex(_ value: UInt32) -> UIColor {
      UIColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
              blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static func uiColor(_ role: ICubeColorRole) -> UIColor {
      switch role {
      // The DolphinTint asset: #3F56A4 light, #8EC5F9 dark.
      case .accent: UIColor(resource: .dolphinTint)
      case .rowSurface: adaptive(light: ink.withAlphaComponent(0.05), dark: .white.withAlphaComponent(0.07))
      case .selectedFill: adaptive(light: hex(0x3F56A4).withAlphaComponent(0.2), dark: hex(0x8EC5F9).withAlphaComponent(0.2))
      case .hairline: adaptive(light: ink.withAlphaComponent(0.12), dark: .white.withAlphaComponent(0.10))
      case .textPrimary: adaptive(light: ink, dark: .white)
      case .textSecondary: adaptive(light: ink.withAlphaComponent(0.65), dark: .white.withAlphaComponent(0.70))
      // 50 % light, not the sheet's 45 %: 45 % misses 3:1 (spec Correction 1).
      case .textTertiary: adaptive(light: ink.withAlphaComponent(0.50), dark: .white.withAlphaComponent(0.45))
      case .destructive: .systemRed
      }
    }

    static func color(_ role: ICubeColorRole) -> Color { Color(uiColor: uiColor(role)) }

    /// The room gradient, top-leading → bottom-trailing.
    static let roomStops: [UIColor] = [
      adaptive(light: hex(0xE6EDFA), dark: hex(0x141F38)),
      adaptive(light: hex(0xD6E3FA), dark: hex(0x0A0F26)),
      adaptive(light: hex(0xF5F7FF), dark: hex(0x000000)),
    ]

    /// Focus rings on rows, tiles and rail items (not the card, whose ring is frozen in `ICubeCardArtFocus`).
    static var focusGradient: LinearGradient {
      LinearGradient(colors: [Color(uiColor: .systemCyan), color(.accent), Color(uiColor: .systemPurple)],
                     startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The `title` role's top-down fill (spec §2.5).
    static var titleGradient: LinearGradient {
      LinearGradient(colors: [color(.textPrimary), color(.accent)], startPoint: .top, endPoint: .bottom)
    }
  }
  ```

  If `UIColor(resource: .dolphinTint)` doesn't compile, find the existing call site's form with `grep -rn "dolphinTint" Common | head` (the code uses `Color(.dolphinTint)`) and use `UIColor(named: "DolphinTint")!` instead.

- [ ] **Step 5: Run the tests and confirm they pass.** Expected: `Executed 6 tests, with 0 failures`. A contrast failure prints the role, the appearance and the ratio; never lower a floor to make it pass.

- [ ] **Step 6: tvOS compile check.** Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

  ```bash
  git checkout -- build/xcframework
  git add Source/iOS/App/Common/Swift/MenuKit/ICubeDesign.swift Source/iOS/App/Common/Swift/MenuKit/ICubeDesign+Color.swift \
    Source/iOS/App/DolphiniOSTests/ICubeDesignTests.swift
  git commit -m "feat(design): spacing, radii, lines, colour roles and motion tokens"
  ```

---

### Task 3: Fold `MenuTheme` into `ICubeDesign` (no visual change)

**Files:**
- Delete: `Common/Swift/MenuKit/MenuTheme.swift`
- Modify: `Common/Swift/MenuKit/ICubeDesign.swift`
- Modify: `Common/Swift/MenuKit/FocusButtonStyle.swift:15-27`
- Modify: `Common/Swift/MenuKit/TileFace.swift:18,86-103`
- Modify: `Common/Swift/MenuKit/InfoShelf.swift:12,31-34`
- Modify: `Common/UI/Settings/SwiftUI/SettingsSidebarShell.swift:17,147`

**Interfaces:**
- Consumes: `ICubeDesign`, `EnvironmentValues.icube` (Task 1)
- Produces: on `ICubeDesign`, these instance properties, all carrying today's `ICubeTheme` values:
  - `tileAccent: Color`
  - `tileFill: Material`
  - `cornerRadius: CGFloat`
  - `focusRingWidth: CGFloat`
  - `focusScale: CGFloat`
  - `tileMinHeight: CGFloat`
  - `shelfHeight: CGFloat`
  - `tileTitleFont: Font`

  `\.menuTheme` and `MenuTheme` / `ICubeTheme` no longer exist.

- [ ] **Step 1: Write the failing test**

  Append to `ICubeDesignTests`:

  ```swift
    /// The menu kit's values carried over unchanged from MenuTheme; step 2 restyles them.
    func test_menuKitValues_unchangedFromMenuTheme() {
      let icube = ICubeDesign.standard
      XCTAssertEqual(icube.cornerRadius, 16)
      XCTAssertEqual(icube.focusRingWidth, 4)
      XCTAssertEqual(icube.focusScale, 1.06)
      XCTAssertEqual(icube.tileMinHeight, 96) // iOS column; tvOS is 180
      XCTAssertEqual(icube.shelfHeight, 56)   // iOS column; tvOS is 80
    }
  ```

- [ ] **Step 2: Run it and confirm it fails.** Expected: `value of type 'ICubeDesign' has no member 'cornerRadius'`.

- [ ] **Step 3: Move the values**

  Add this inside `struct ICubeDesign`, before `// MARK: Type`:

  ```swift
    // MARK: Menu kit (carried over from MenuTheme; step 2 moves these onto the roles below)

    /// The app's AccentColor asset (#8EC5F9 in both appearances), not the adaptive `accent` role.
    var tileAccent: Color = .accentColor
    var tileFill: Material = .ultraThinMaterial
    var cornerRadius: CGFloat = Radius.large.rawValue
    var focusRingWidth: CGFloat = Line.focus.rawValue
    var focusScale: CGFloat = Motion.tileFocusScale
    #if os(tvOS)
    var tileMinHeight: CGFloat = 180
    var shelfHeight: CGFloat = 80
    var tileTitleFont: Font = .headline
    #else
    var tileMinHeight: CGFloat = 96
    var shelfHeight: CGFloat = 56
    var tileTitleFont: Font = .subheadline.weight(.semibold)
    #endif
  ```

  Delete `Common/Swift/MenuKit/MenuTheme.swift` (`git rm`).

  In each of the four files, make these replacements:
  - Replace `@Environment(\.menuTheme) private var theme` with `@Environment(\.icube) private var theme`. Keep the local name `theme`, so no other line changes.
  - Replace `theme.accent` with `theme.tileAccent`. This occurs in `FocusButtonStyle.swift` and `SettingsSidebarShell.swift:147`.
  - Fix the doc comment in `FocusButtonStyle` if it mentions `MenuTheme`.

  Then confirm nothing else references the old names:

  ```bash
  grep -rn "menuTheme\|MenuTheme\|ICubeTheme" Source/iOS/App --include='*.swift'
  ```

  Expected: no output.

- [ ] **Step 4: Run the tests.** Run the Task 1 test command for `ICubeDesignTests`, then also `-only-testing:iCubeTests/MenuModelTests -only-testing:iCubeTests/MenuFocusRouterTests`. Expected: 0 failures.

- [ ] **Step 5: tvOS compile check.** Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

  ```bash
  git checkout -- build/xcframework
  git rm -q --cached Source/iOS/App/Common/Swift/MenuKit/MenuTheme.swift 2>/dev/null || true
  git add Source/iOS/App/Common/Swift/MenuKit/ICubeDesign.swift Source/iOS/App/Common/Swift/MenuKit/FocusButtonStyle.swift \
    Source/iOS/App/Common/Swift/MenuKit/TileFace.swift Source/iOS/App/Common/Swift/MenuKit/InfoShelf.swift \
    Source/iOS/App/Common/UI/Settings/SwiftUI/SettingsSidebarShell.swift Source/iOS/App/DolphiniOSTests/ICubeDesignTests.swift
  git status --short   # staged: exactly these 6 files plus the MenuTheme.swift deletion
  git commit -m "refactor(design): fold MenuTheme into ICubeDesign"
  ```

---

### Task 4: Extract the card focus effect, pixel-identical

**Files:**
- Create: `Common/Swift/MenuKit/ICubeDesign+Focus.swift` (card part only in this task)
- Modify: `Common/Swift/GameGridItem.swift`, tvOS branch only (art overlays around `:507-551`, container around `:660-672`)
- Test: `DolphiniOSTests/ICubeCardFocusTests.swift`

**Interfaces:**
- Consumes: `LibraryLayout.cardSize`, `Color(.dolphinTint)`, `ICubeDesign.Motion.focusSpring`
- Produces:
  - `View.icubeCardArtFocus(isFocused: Bool) -> some View`. It draws the ring, the three glows, the inner highlight, the art shadow and the sheen.
  - `View.icubeCardFocus(isFocused: Bool) -> some View`. It applies the container scale, tilt, shadow and spring.

- [ ] **Step 1: Write the failing test**

  `legacyArt` and `legacyContainer` are **verbatim copies** of today's `GameGridItem.swift` lines. Copy them from the file, not from this plan; the plan's copy is for orientation:
  - the `.overlay(...)` focus ring through the `.shadow(...)` art shadow at `:507-543`
  - the `if isFocused { sheen }` block at `:545-551`
  - the container `.scaleEffect` through `.animation` at `:661-672`

  Create `DolphiniOSTests/ICubeCardFocusTests.swift`:

  ```swift
  // Copyright 2026 DolphiniOS Project
  // SPDX-License-Identifier: GPL-2.0-or-later

  #if os(iOS) && DEBUG
  import SwiftUI
  import UIKit
  import XCTest

  @testable import iCube

  /// Spec §2.7: `.icubeCardArtFocus` + `.icubeCardFocus` must draw exactly what GameGridItem drew
  /// before the extraction. `legacy(...)` is a verbatim copy of the pre-extraction code (commit before
  /// this test landed); keep it frozen. It is the definition of the effect.
  @MainActor
  final class ICubeCardFocusTests: XCTestCase {
    private static let canvas = CGSize(width: 520, height: 760)

    func test_extractedEffect_isPixelIdenticalToLegacy() throws {
      let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      for style in [UIUserInterfaceStyle.light, .dark] {
        for focused in [false, true] {
          let before = try pixels(render(Self.legacy(isFocused: focused), style: style, scene: scene))
          let after = try pixels(render(Self.extracted(isFocused: focused), style: style, scene: scene))
          XCTAssertEqual(before.count, after.count)
          let diffs = zip(before, after).filter { $0 != $1 }.count
          XCTAssertEqual(diffs, 0, "focused=\(focused) style=\(style.rawValue): \(diffs) bytes differ")
        }
      }
    }

    // MARK: The card stand-in: flat art plus a one-line title, the same structure as GameGridItem's tvOS body.

    private static func art() -> some View {
      Color.orange
        .frame(width: LibraryLayout.cardSize.width, height: LibraryLayout.cardSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private static func extracted(isFocused: Bool) -> some View {
      VStack(alignment: .leading, spacing: 12) {
        ZStack(alignment: .topTrailing) {
          art().icubeCardArtFocus(isFocused: isFocused)
        }
        Text("Title")
      }
      .frame(width: LibraryLayout.cardSize.width)
      .icubeCardFocus(isFocused: isFocused)
      .frame(width: canvas.width, height: canvas.height)
    }

    /// VERBATIM from GameGridItem.swift before the extraction. Do not edit.
    private static func legacy(isFocused: Bool) -> some View {
      VStack(alignment: .leading, spacing: 12) {
        ZStack(alignment: .topTrailing) {
          art()
            .overlay(
              RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                  LinearGradient(
                    colors: isFocused ? [
                      Color.cyan.opacity(0.95),
                      Color(.dolphinTint).opacity(0.9),
                      Color.purple.opacity(0.95),
                      Color.cyan.opacity(0.95)
                    ] : [Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                  ),
                  lineWidth: isFocused ? 8 : 0
                )
                .shadow(color: .cyan.opacity(isFocused ? 0.8 : 0), radius: isFocused ? 25 : 0)
                .shadow(color: .blue.opacity(isFocused ? 0.6 : 0), radius: isFocused ? 35 : 0)
                .shadow(color: .purple.opacity(isFocused ? 0.7 : 0), radius: isFocused ? 45 : 0)
                .animation(.easeInOut(duration: 0.6), value: isFocused)
            )
            .overlay(
              RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                  Color.white.opacity(isFocused ? 0.4 : 0),
                  lineWidth: isFocused ? 2 : 0
                )
                .padding(4)
                .animation(.easeInOut(duration: 0.4), value: isFocused)
            )
            .shadow(
              color: Color.black.opacity(isFocused ? 0.4 : 0.2),
              radius: isFocused ? 20 : 8,
              x: 0,
              y: isFocused ? 12 : 6
            )

          if isFocused {
            VStack { LinearGradient(colors: [Color.white.opacity(0.2), .clear], startPoint: .top, endPoint: .center)
              Spacer()
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(width: LibraryLayout.cardSize.width, height: LibraryLayout.cardSize.height)
            .allowsHitTesting(false)
          }
        }
        Text("Title")
      }
      .frame(width: LibraryLayout.cardSize.width)
      .scaleEffect(isFocused ? 1.08 : 1.0)
      .rotation3DEffect(
        .degrees(isFocused ? 5 : 2),
        axis: (x: 0.1, y: 1.0, z: 0),
        perspective: isFocused ? 0.8 : 1.0
      )
      .shadow(
        color: .black.opacity(isFocused ? 0.4 : 0.2),
        radius: isFocused ? 20 : 8,
        x: 0,
        y: isFocused ? 12 : 4
      )
      .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isFocused)
      .frame(width: canvas.width, height: canvas.height)
    }

    // MARK: Rendering (same window-hosted approach as TouchOverlaySnapshotTests)

    private func render<V: View>(_ view: V, style: UIUserInterfaceStyle, scene: UIWindowScene) -> UIImage {
      let window = UIWindow(windowScene: scene)
      window.frame = CGRect(origin: .zero, size: Self.canvas)
      window.overrideUserInterfaceStyle = style
      let host = UIHostingController(rootView: view)
      host.safeAreaRegions = []
      window.rootViewController = host
      window.isHidden = false
      window.layoutIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.15))
      let format = UIGraphicsImageRendererFormat()
      format.scale = 2
      let image = UIGraphicsImageRenderer(size: Self.canvas, format: format).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      window.isHidden = true
      return image
    }

    private func pixels(_ image: UIImage) throws -> [UInt8] {
      let data = try XCTUnwrap(image.cgImage?.dataProvider?.data as Data?)
      return [UInt8](data)
    }
  }
  #endif
  ```

  Before writing `legacy`, diff it against the file:

  ```bash
  sed -n 505,552p Source/iOS/App/Common/Swift/GameGridItem.swift
  sed -n 660,673p Source/iOS/App/Common/Swift/GameGridItem.swift
  ```

  Every modifier, value and order in `legacy` must match those lines. The only substitutions allowed are:
  - the art (`art()` in place of the cover `Group`)
  - the title (`Text("Title")`)

- [ ] **Step 2: Run it and confirm it fails.**

  ```bash
  cd Source/iOS/App && tuist generate --no-open && make test TEST_ARGS="-only-testing:iCubeTests/ICubeCardFocusTests"
  ```

  Expected: `value of type 'some View' has no member 'icubeCardArtFocus'`.

- [ ] **Step 3: Create `ICubeDesign+Focus.swift` with the card modifiers**

  ```swift
  // Common/Swift/MenuKit/ICubeDesign+Focus.swift
  // Copyright 2026 DolphiniOS Project
  // SPDX-License-Identifier: GPL-2.0-or-later

  import SwiftUI

  /// The art half of the iCube card focus effect (spec §2.7), frozen from GameGridItem. Its 8 pt ring
  /// and 2 pt highlight are not tokens and are used nowhere else. `ICubeCardFocusTests` pins it.
  private struct ICubeCardArtFocus: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
      content
        .overlay(
          RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous)
            .stroke(
              LinearGradient(
                colors: isFocused ? [
                  Color.cyan.opacity(0.95),
                  Color(.dolphinTint).opacity(0.9),
                  Color.purple.opacity(0.95),
                  Color.cyan.opacity(0.95)
                ] : [Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              ),
              lineWidth: isFocused ? 8 : 0
            )
            .shadow(color: .cyan.opacity(isFocused ? 0.8 : 0), radius: isFocused ? 25 : 0)
            .shadow(color: .blue.opacity(isFocused ? 0.6 : 0), radius: isFocused ? 35 : 0)
            .shadow(color: .purple.opacity(isFocused ? 0.7 : 0), radius: isFocused ? 45 : 0)
            .animation(.easeInOut(duration: 0.6), value: isFocused)
        )
        .overlay(
          RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous)
            .stroke(Color.white.opacity(isFocused ? 0.4 : 0), lineWidth: isFocused ? 2 : 0)
            .padding(4)
            .animation(.easeInOut(duration: 0.4), value: isFocused)
        )
        .shadow(color: Color.black.opacity(isFocused ? 0.4 : 0.2), radius: isFocused ? 20 : 8, x: 0, y: isFocused ? 12 : 6)
        .overlay {
          // Top sheen while focused.
          if isFocused {
            VStack {
              LinearGradient(colors: [Color.white.opacity(0.2), .clear], startPoint: .top, endPoint: .center)
              Spacer()
            }
            .clipShape(RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous))
            .frame(width: LibraryLayout.cardSize.width, height: LibraryLayout.cardSize.height)
            .allowsHitTesting(false)
          }
        }
    }
  }

  /// The container half: lift, tilt (2° at rest, 5° focused) and shadow (spec §2.7).
  private struct ICubeCardFocus: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
      content
        .scaleEffect(isFocused ? 1.08 : 1.0)
        .rotation3DEffect(.degrees(isFocused ? 5 : 2), axis: (x: 0.1, y: 1.0, z: 0), perspective: isFocused ? 0.8 : 1.0)
        .shadow(color: .black.opacity(isFocused ? 0.4 : 0.2), radius: isFocused ? 20 : 8, x: 0, y: isFocused ? 12 : 4)
        .animation(ICubeDesign.Motion.focusSpring, value: isFocused)
    }
  }

  extension View {
    /// Apply to the card art (cover or placeholder), inside the card's ZStack.
    func icubeCardArtFocus(isFocused: Bool) -> some View { modifier(ICubeCardArtFocus(isFocused: isFocused)) }

    /// Apply to the whole card (art + title), before its focus/gesture modifiers. A modifier, not a
    /// ButtonStyle: the card keeps its own tap, long-press, play/pause and context menu.
    func icubeCardFocus(isFocused: Bool) -> some View { modifier(ICubeCardFocus(isFocused: isFocused)) }
  }
  ```

- [ ] **Step 4: Run the test and confirm it passes.**

  Expected: `Executed 1 test, with 0 failures`.

  If a handful of bytes differ, re-run once. Rasterization of identical trees should be deterministic. If the count is stable and nonzero, look for the cause: the sheen moved from a ZStack sibling into an overlay. Report it rather than loosening the assertion; a deliberate tolerance needs the reviewer's sign-off.

- [ ] **Step 5: Use the modifiers in `GameGridItem.swift`, tvOS branch only**

  Make these three edits:
  1. Replace the art `Group { ... }`'s two trailing `.overlay(...)` blocks and the `.shadow(...)` (`:507-543`) with `.icubeCardArtFocus(isFocused: isFocused)`.
  2. Delete the `if isFocused { VStack { LinearGradient ... } ... }` sheen block (`:545-551`). The modifier now draws it.
  3. Replace the container's `.scaleEffect` / `.rotation3DEffect` / `.shadow` / `.animation(.spring...)` (`:661-672`) with `.icubeCardFocus(isFocused: isFocused)`. It goes directly after `.frame(width: LibraryLayout.cardSize.width)` and before `.focusable(true) { ... }`.

  Leave everything else in the card unchanged, including the inner 1° and 3° tilts (Task 5 removes those) and the whole `#else` (iOS) branch.

  Then check the diff:

  ```bash
  git diff --stat Source/iOS/App/Common/Swift/GameGridItem.swift
  git diff Source/iOS/App/Common/Swift/GameGridItem.swift | grep '^[-+]' | grep -v '^[-+][-+]'
  ```

  Every removed line must appear in `ICubeCardFocusTests.legacy`. The added lines are only the two modifier calls.

- [ ] **Step 6: tvOS compile check.** Expected: `BUILD SUCCEEDED`. Then re-run `ICubeCardFocusTests` and `ICubeDesignTests`. Expected: 0 failures.

- [ ] **Step 7: Commit**

  ```bash
  git checkout -- build/xcframework
  git add Source/iOS/App/Common/Swift/MenuKit/ICubeDesign+Focus.swift Source/iOS/App/Common/Swift/GameGridItem.swift \
    Source/iOS/App/DolphiniOSTests/ICubeCardFocusTests.swift
  git commit -m "refactor(design): extract the card focus effect into icubeCardFocus"
  ```

---

### Task 5: Cards rest at exactly 2° (the one visible change)

**Files:**
- Modify: `Common/Swift/GameGridItem.swift`, tvOS branch: the placeholder art (`.rotation3DEffect(.degrees(3), ...)` near `:431-435`, inside `templatedCoverView`) and the real cover (`.rotation3DEffect(.degrees(1), ...)` near `:499-503`)

**Interfaces:** none new.

- [ ] **Step 1: Find both inner tilts**

  ```bash
  grep -n "rotation3DEffect" -A4 Source/iOS/App/Common/Swift/GameGridItem.swift
  ```

  Expected: the 3° placeholder tilt (axis 0.1, perspective 0.8), the 1° cover tilt (axis 0.05, perspective 1.2), and any `#else` (iOS) branch tilts. `icubeCardFocus` now owns the container tilt.

- [ ] **Step 2: Delete the two inner tilts.**
  - Delete the 3° placeholder tilt and the comment above it (`// Enhanced 3D perspective`).
  - Delete the 1° cover tilt and its comment (`// Add subtle 3D perspective to real covers too`).
  - Check whether `templatedCoverView` is used only by the tvOS branch:

    ```bash
    grep -n "templatedCoverView" Source/iOS/App/Common/Swift/GameGridItem.swift
    ```

    If the iOS branch also uses it, the iOS placeholder loses its 3° tilt too. That is acceptable: the spec's rest angle is 2° everywhere. Say so in the commit body.
  - Leave every iOS-branch tilt that is not in `templatedCoverView` as it is.

- [ ] **Step 3: Confirm no inner tilt is left on the tvOS card**

  ```bash
  grep -n "rotation3DEffect" Source/iOS/App/Common/Swift/GameGridItem.swift
  ```

  Expected: no 1° or 3° tvOS lines. Only iOS-branch effects may remain, if they existed.

- [ ] **Step 4: tvOS compile check.** Expected: `BUILD SUCCEEDED`. Re-run `ICubeCardFocusTests`. Expected: still 0 failures; the frozen effect is unchanged.

- [ ] **Step 5: Commit**

  ```bash
  git checkout -- build/xcframework
  git add Source/iOS/App/Common/Swift/GameGridItem.swift
  git commit -m "feat(design): cards rest at exactly 2 degrees" -m "Removes the inner art tilts (cover 1 deg, placeholder 3 deg) that stacked on the container's 2 deg rest tilt (owner decision, design spec Decisions 1)."
  ```

---

### Task 6: Row and Tile focus styles and the panel, with snapshots

**Files:**
- Modify: `Common/Swift/MenuKit/ICubeDesign+Focus.swift`
- Test: `DolphiniOSTests/ICubeDesignSnapshotTests.swift`

**Interfaces:**
- Consumes:
  - `ICubeDesign.color(_:)`, `focusGradient`, `Radius`, `Line`, `Spacing`, `Motion` (Task 2)
  - `View.icubeText(_:)` (Task 1)
  - `View.icubeCardFocus` / `icubeCardArtFocus` (Task 4)
- Produces:
  - `struct ICubeRowButtonStyle: ButtonStyle { var isFocusedOverride: Bool? = nil }`
  - `struct ICubeTileButtonStyle: ButtonStyle { var isFocusedOverride: Bool? = nil }`
  - `View.icubePanel() -> some View`

  Step 2 adopts these. In step 1 only the snapshot test uses them.

- [ ] **Step 1: Write the snapshot test** (env-gated, the same pattern as `TouchOverlaySnapshotTests`)

  ```swift
  // Copyright 2026 DolphiniOS Project
  // SPDX-License-Identifier: GPL-2.0-or-later

  #if os(iOS) && DEBUG
  import SwiftUI
  import UIKit
  import XCTest

  @testable import iCube

  /// PNGs of the design module's pieces in light and dark, for eyeballing. Skipped unless
  /// TEST_RUNNER_ICUBE_DESIGN_SNAPSHOT_DIR is EXPORTED (not passed in TEST_ARGS), e.g.
  ///   export TEST_RUNNER_ICUBE_DESIGN_SNAPSHOT_DIR=/tmp/icube-design
  ///   make test TEST_ARGS="-only-testing:iCubeTests/ICubeDesignSnapshotTests"
  @MainActor
  final class ICubeDesignSnapshotTests: XCTestCase {
    private static let outputDirKey = "ICUBE_DESIGN_SNAPSHOT_DIR"

    func testRenderPieces() throws {
      guard let dir = ProcessInfo.processInfo.environment[Self.outputDirKey], !dir.isEmpty else {
        throw XCTSkip("set \(Self.outputDirKey) to render design snapshots")
      }
      let out = URL(fileURLWithPath: dir, isDirectory: true)
      try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
      let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      let size = CGSize(width: 900, height: 1100)
      for style in [UIUserInterfaceStyle.light, .dark] {
        let name = style == .dark ? "dark" : "light"
        for focused in [false, true] {
          let image = render(Self.sheet(focused: focused), size: size, style: style, scene: scene)
          try XCTUnwrap(image.pngData()).write(to: out.appendingPathComponent("design-\(name)-\(focused ? "focused" : "rest").png"))
        }
      }
    }

    private static func sheet(focused: Bool) -> some View {
      ZStack {
        LinearGradient(colors: ICubeDesign.roomStops.map { Color(uiColor: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
        VStack(alignment: .leading, spacing: ICubeDesign.Spacing.l.rawValue) {
          Text("Settings").icubeText(.title).foregroundStyle(ICubeDesign.titleGradient)
          Text("Graphics").icubeText(.section).foregroundStyle(ICubeDesign.color(.textPrimary))
          VStack(spacing: ICubeDesign.Spacing.m.rawValue) {
            Button {} label: {
              VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xxs.rawValue) {
                Text("Internal Resolution").icubeText(.body).foregroundStyle(ICubeDesign.color(.textPrimary))
                Text("Higher looks sharper and costs more GPU.").icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary))
              }
            }
            .buttonStyle(ICubeRowButtonStyle(isFocusedOverride: focused))
            HStack(spacing: ICubeDesign.Spacing.m.rawValue) {
              Button {} label: { Text("Resume").icubeText(.body) }.buttonStyle(ICubeTileButtonStyle(isFocusedOverride: focused))
              Button {} label: { Text("GALE01").icubeText(.tag) }.buttonStyle(ICubeTileButtonStyle(isFocusedOverride: false))
            }
          }
          .padding(ICubeDesign.Spacing.l.rawValue)
          .icubePanel()
          Color.orange
            .frame(width: LibraryLayout.cardSize.width, height: LibraryLayout.cardSize.height)
            .clipShape(RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous))
            .icubeCardArtFocus(isFocused: focused)
            .icubeCardFocus(isFocused: focused)
        }
        .padding(ICubeDesign.Spacing.xl.rawValue)
      }
    }

    private func render<V: View>(_ view: V, size: CGSize, style: UIUserInterfaceStyle, scene: UIWindowScene) -> UIImage {
      let window = UIWindow(windowScene: scene)
      window.frame = CGRect(origin: .zero, size: size)
      window.overrideUserInterfaceStyle = style
      let host = UIHostingController(rootView: view)
      host.safeAreaRegions = []
      window.rootViewController = host
      window.isHidden = false
      window.layoutIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.15))
      let format = UIGraphicsImageRendererFormat()
      format.scale = 2
      let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      window.isHidden = true
      return image
    }
  }
  #endif
  ```

- [ ] **Step 2: Run it and confirm it fails.** Expected: `cannot find 'ICubeRowButtonStyle' in scope`.

- [ ] **Step 3: Add the styles and the panel to `ICubeDesign+Focus.swift`**

  ```swift
  /// Shared focus treatment for rows, tiles and rail items (spec §2.4, §2.6, §3): a 4 pt focus-gradient
  /// ring, a cyan glow, a scale, and no system focus capsule. `@Environment(\.isFocused)` is only
  /// correct when read inside `makeBody`; iOS has no focus engine for a pad, so the router's polled
  /// focus comes in as `isFocusedOverride`.
  private struct ICubeFocusChrome: ViewModifier {
    let focused: Bool
    let pressed: Bool
    let radius: CGFloat
    let scale: CGFloat

    func body(content: Content) -> some View {
      content
        .overlay(
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(ICubeDesign.focusGradient, lineWidth: focused ? ICubeDesign.Line.focus.rawValue : 0)
        )
        .shadow(color: Color(uiColor: .systemCyan).opacity(focused ? 0.5 : 0), radius: focused ? 20 : 0, x: 0, y: 0)
        .scaleEffect(focused ? scale : 1)
        .zIndex(focused ? 1 : 0)
        .opacity(pressed ? 0.85 : 1)
        .animation(ICubeDesign.Motion.focusSpring, value: focused)
        .focusEffectDisabled()
    }
  }

  /// Settings, hub, list and sheet rows (spec §3 Row).
  struct ICubeRowButtonStyle: ButtonStyle {
    var isFocusedOverride: Bool? = nil
    @Environment(\.isFocused) private var isFocused

    #if os(tvOS)
    private static let minHeight: CGFloat = 72
    #else
    private static let minHeight: CGFloat = 44
    #endif

    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .padding(.horizontal, ICubeDesign.Spacing.m.rawValue)
        .padding(.vertical, ICubeDesign.Spacing.s.rawValue)
        .frame(maxWidth: .infinity, minHeight: Self.minHeight, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue, style: .continuous)
            .fill(ICubeDesign.color(.rowSurface))
        )
        .modifier(ICubeFocusChrome(focused: isFocusedOverride ?? isFocused, pressed: configuration.isPressed,
                                   radius: ICubeDesign.Radius.small.rawValue, scale: ICubeDesign.Motion.rowFocusScale))
    }
  }

  /// Pause and hub tiles (spec §3 Tile).
  struct ICubeTileButtonStyle: ButtonStyle {
    var isFocusedOverride: Bool? = nil
    @Environment(\.isFocused) private var isFocused

    #if os(tvOS)
    private static let minHeight: CGFloat = 180
    #else
    private static let minHeight: CGFloat = 96
    #endif

    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .padding(ICubeDesign.Spacing.m.rawValue)
        .frame(maxWidth: .infinity, minHeight: Self.minHeight, alignment: .topLeading)
        .background(
          RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous)
            .fill(ICubeDesign.color(.rowSurface))
        )
        .overlay(
          RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous)
            .stroke(ICubeDesign.color(.hairline), lineWidth: ICubeDesign.Line.hairline.rawValue)
        )
        .modifier(ICubeFocusChrome(focused: isFocusedOverride ?? isFocused, pressed: configuration.isPressed,
                                   radius: ICubeDesign.Radius.large.rawValue, scale: ICubeDesign.Motion.tileFocusScale))
    }
  }

  extension View {
    /// The one blur layer (spec §2.6): rail, sheets, info shelf, pause scrim. Never nest panels.
    func icubePanel() -> some View {
      background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous)
            .stroke(ICubeDesign.color(.hairline), lineWidth: ICubeDesign.Line.hairline.rawValue)
        )
    }
  }
  ```

- [ ] **Step 4: Run the test with the snapshot directory exported.**

  ```bash
  export TEST_RUNNER_ICUBE_DESIGN_SNAPSHOT_DIR="$TMPDIR/icube-design-snapshots"
  cd Source/iOS/App && tuist generate --no-open && make test TEST_ARGS="-only-testing:iCubeTests/ICubeDesignSnapshotTests"
  ls "$TEST_RUNNER_ICUBE_DESIGN_SNAPSHOT_DIR"
  ```

  Expected: 4 PNGs. Open each one (the Read tool shows images) and check four things:
  - the title is in the rounded display face, and the section header is uppercase
  - the focused row and tile show a cyan → blue → purple ring, while the at-rest ones have none
  - the dark images use the dark room and white text
  - the card shows the frozen effect

  Do not commit the PNGs. Then run without the variable. Expected: the test is skipped, with 0 failures.

- [ ] **Step 5: tvOS compile check.** Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

  ```bash
  git checkout -- build/xcframework
  git add Source/iOS/App/Common/Swift/MenuKit/ICubeDesign+Focus.swift Source/iOS/App/DolphiniOSTests/ICubeDesignSnapshotTests.swift
  git commit -m "feat(design): row and tile focus styles, panel, design snapshots"
  ```

---

### Task 7: Move the room background into the module

**Files:**
- Create: `Common/Swift/MenuKit/ICubeDesign+Room.swift`
- Modify: `Common/Swift/TVLibraryView.swift:730-784` (`backgroundGradient`, `cleanBackground`, `gradientBackground`) and its single use at `:842`

**Interfaces:**
- Consumes: `ICubeDesign.roomStops` (Task 2), `LibraryBackgroundStyle` (`Common/UI/Settings/SwiftUI/SettingsEnums.swift:94`), `EmulationQuiet` and `LibraryAnimatedBackground` (`Common/Swift/LibraryAnimatedBackground.swift`)
- Produces: `struct ICubeRoom: View { let style: LibraryBackgroundStyle }`

- [ ] **Step 1: Create `ICubeDesign+Room.swift`**

  ```swift
  // Common/Swift/MenuKit/ICubeDesign+Room.swift
  // Copyright 2026 DolphiniOS Project
  // SPDX-License-Identifier: GPL-2.0-or-later

  import SwiftUI
  import UIKit

  /// The room every iCube screen sits in (spec §2.5 `room`), in the user's Background Style.
  struct ICubeRoom: View {
    let style: LibraryBackgroundStyle

    var body: some View {
      switch style {
      case .clean:
        Self.clean
      case .gradient:
        Self.gradient
      case .animated:
        // The static gradient while a game runs: the orbs and drifting tiles are perpetual animations
        // on a layer behind a screen nobody is looking at.
        EmulationQuiet(idle: LibraryAnimatedBackground(), whileEmulating: Self.gradient)
      }
    }

    /// Follows the appearance: a fixed black here put light-mode (black) titles on black.
    private static var clean: some View {
      #if os(tvOS)
      // tvOS has no .systemBackground; this is what it resolves to on iOS.
      Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .black : .white })
        .ignoresSafeArea()
      #else
      Color(uiColor: .systemBackground)
        .ignoresSafeArea()
      #endif
    }

    private static var gradient: some View {
      LinearGradient(colors: ICubeDesign.roomStops.map { Color(uiColor: $0) },
                     startPoint: .topLeading, endPoint: .bottomTrailing)
        .ignoresSafeArea()
    }
  }
  ```

  The gradient's stops move from `Color(red: 0.08, …)` to the spec's hex values. They differ by at most one 8-bit level per channel (for example 0.08 × 255 = 20.4 against `#14` = 20). That is invisible and inside the "no visual change" rule; put it in the commit body.

- [ ] **Step 2: Point `TVLibraryView` at it**

  1. Delete `backgroundGradient`, `cleanBackground` and `gradientBackground` (`:730-784`), with their doc comments.
  2. At the use site (`:842`, inside `mainContent`'s `ZStack`), replace `backgroundGradient` with:

     ```swift
           ICubeRoom(style: LibraryBackgroundStyle(rawValue: backgroundStyle.rawValue) ?? .gradient)
     ```

     `TVLibraryView.BackgroundStyle` (`:450`) and `LibraryBackgroundStyle` share raw values (`clean`, `gradient`, `animated`).
  3. If `colorScheme` was read only by `gradientBackground`, remove `@Environment(\.colorScheme)` from `TVLibraryView`:

     ```bash
     grep -n "colorScheme" Source/iOS/App/Common/Swift/TVLibraryView.swift
     ```

     Keep it if any other line uses it.

- [ ] **Step 3: Check that nothing else used the deleted members**

  ```bash
  grep -rn "backgroundGradient\|gradientBackground\|cleanBackground" Source/iOS/App/Common --include='*.swift'
  ```

  Expected: no output.

- [ ] **Step 4: Build and test.**
  - Run the tvOS compile check. Expected: `BUILD SUCCEEDED`.
  - Run `ICubeDesignTests` and `LibraryIdleDuringPlayTests`. Expected: 0 failures. The second guards `EmulationQuiet`.

- [ ] **Step 5: Commit**

  ```bash
  git checkout -- build/xcframework
  git add Source/iOS/App/Common/Swift/MenuKit/ICubeDesign+Room.swift Source/iOS/App/Common/Swift/TVLibraryView.swift
  git commit -m "refactor(design): move the library background into ICubeRoom" -m "Gradient stops now come from the room tokens (spec hex); each channel moves by at most one 8-bit level."
  ```

---

### Task 8: Design-token lint ratchet

**Files:**
- Create: `Project/Scripts/check_design_tokens.py`
- Create: `Project/Scripts/test_check_design_tokens.py`
- Create: `Project/Scripts/design_tokens_baseline.json`, generated in Step 5, after Tasks 3–7 so the counts reflect the fold and the extraction
- Modify: `.github/workflows/tests.yml`, a step after "Check ButtonType drift"

**Interfaces:**
- Produces:
  - `python3 Project/Scripts/check_design_tokens.py --check`. It exits 1 if any file's count exceeds its baseline.
  - `python3 Project/Scripts/check_design_tokens.py --update`, which rewrites the baseline.
  - `count_violations(text: str, path: str) -> int`, used by the tests.

- [ ] **Step 1: Write the failing tests** in `Project/Scripts/test_check_design_tokens.py`

  ```python
  #!/usr/bin/env python3
  """Unit tests for check_design_tokens.py. Run: python3 -m unittest Project/Scripts/test_check_design_tokens.py"""
  import os
  import sys
  import unittest

  sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
  import check_design_tokens as cdt  # noqa: E402


  class CountTests(unittest.TestCase):
      def count(self, text, path="Common/Swift/Foo.swift"):
          return cdt.count_violations(text, path)

      def test_flags_each_pattern(self):
          for line in [
              '.font(.system(size: 20))',
              '.font(.headline)',
              '.font(.caption2)',
              'Font.custom("X", size: 3)',
              'RoundedRectangle(cornerRadius: 12)',
              '.stroke(c, lineWidth: 2)',
              'Color(red: 0.1, green: 0.2, blue: 0.3)',
              'Color.cyan.opacity(0.5)',
              '.buttonStyle(.borderedProminent)',
          ]:
              self.assertEqual(self.count(line), 1, line)

      def test_ignores_tokens_and_variables(self):
          for line in [
              'RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue)',
              '.stroke(c, lineWidth: width)',
              '.font(icube.font(.body))',
              'Color.clear',
              'Color.white.opacity(0.2)',
          ]:
              self.assertEqual(self.count(line), 0, line)

      def test_ignores_comments_and_allow_marker(self):
          self.assertEqual(self.count('// .font(.headline)'), 0)
          self.assertEqual(self.count('/* Color.cyan */ let x = 1'), 0)
          self.assertEqual(self.count('.font(.headline) // design-lint: allow system menu label'), 0)

      def test_navigationTitle_only_in_tvOS_code(self):
          text = '\n'.join([
              '.navigationTitle("A")',          # shared code: not flagged
              '#if os(tvOS)',
              '.navigationTitle("B")',          # flagged
              '#else',
              '.navigationTitle("C")',          # iOS branch: not flagged
              '#endif',
          ])
          self.assertEqual(self.count(text), 1)
          self.assertEqual(self.count('.navigationTitle("A")', "Common/Swift/TVFoo.swift"), 1)
          self.assertEqual(self.count('#if !os(tvOS)\n.navigationTitle("A")\n#endif', "Common/Swift/TVFoo.swift"), 0)

      def test_exempt_paths(self):
          self.assertTrue(cdt.is_exempt("Common/Swift/MenuKit/ICubeDesign+Focus.swift"))
          self.assertTrue(cdt.is_exempt("Common/Swift/Debug/DebugAPIRoutes.swift"))
          self.assertTrue(cdt.is_exempt("Common/Swift/MotionDebugView.swift"))
          self.assertFalse(cdt.is_exempt("Common/Swift/GameGridItem.swift"))


  class RatchetTests(unittest.TestCase):
      def test_compare(self):
          worse, better = cdt.compare({"a.swift": 3, "new.swift": 1}, {"a.swift": 2, "gone.swift": 4})
          self.assertEqual(worse, {"a.swift": (2, 3), "new.swift": (0, 1)})
          self.assertEqual(better, {"gone.swift": (4, 0)})


  if __name__ == "__main__":
      unittest.main()
  ```

- [ ] **Step 2: Run them and confirm they fail**

  ```bash
  cd Source/iOS/App && python3 -m unittest Project/Scripts/test_check_design_tokens.py
  ```

  Expected: `ModuleNotFoundError: No module named 'check_design_tokens'`.

- [ ] **Step 3: Write `check_design_tokens.py`**

  ```python
  #!/usr/bin/env python3
  """
  iCube design-token ratchet (design spec §4.3, docs/superpowers/specs/2026-10-10-icube-design-language.md).

  Counts hard-coded styling in Source/iOS/App/Common/**/*.swift -- system font sizes and text styles,
  custom fonts, numeric corner radii and line widths, RGB colours, named system colours, bordered-
  prominent buttons, and .navigationTitle in tvOS code -- outside the design module
  (MenuKit/ICubeDesign*.swift). Debug screens are exempt, as is any line ending in
  `// design-lint: allow <reason>`.

  It is a ratchet, not a hard fail: design_tokens_baseline.json holds each file's count when the
  module landed. --check fails if any file's count rises above its baseline (a file not in the
  baseline has a baseline of 0). When counts fall, --check passes and asks you to run --update so
  the lower count becomes the new ceiling.

  Run from anywhere:
    python3 Source/iOS/App/Project/Scripts/check_design_tokens.py --check
    python3 Source/iOS/App/Project/Scripts/check_design_tokens.py --update
  """
  import argparse
  import json
  import os
  import re
  import sys

  HERE = os.path.dirname(os.path.abspath(__file__))
  APP_ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))  # Source/iOS/App
  SCAN_ROOT = "Common"
  BASELINE = os.path.join(HERE, "design_tokens_baseline.json")
  ALLOW_MARKER = "design-lint: allow"

  TEXT_STYLES = "largeTitle|title|title2|title3|headline|subheadline|body|callout|footnote|caption|caption2"
  PATTERNS = [
      re.compile(r"\.font\(\.system\(size:"),
      re.compile(r"\.font\(\.(?:%s)\b" % TEXT_STYLES),
      re.compile(r"\bFont\.custom\("),
      re.compile(r"\bcornerRadius:\s*[0-9]"),
      re.compile(r"\blineWidth:\s*[0-9]"),
      re.compile(r"\bColor\(red:"),
      re.compile(r"\bColor\.(?:blue|cyan|purple|orange|yellow|green|pink)\b"),
      re.compile(r"\.borderedProminent\b"),
  ]
  NAV_TITLE = re.compile(r"\.navigationTitle\(")


  def is_exempt(rel_path):
      parts = rel_path.split("/")
      name = parts[-1]
      if name.startswith("ICubeDesign") and "MenuKit" in parts:
          return True
      if "Debug" in parts[:-1] or "Debug" in name:
          return True
      return False


  def _strip_comments(text):
      text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
      out = []
      for line in text.split("\n"):
          if ALLOW_MARKER in line:
              out.append("")
              continue
          out.append(re.sub(r"//.*$", "", line))
      return out


  def count_violations(text, rel_path):
      tv_file = os.path.basename(rel_path).startswith("TV")
      stack = []  # one of "tv", "notv", "other" per open #if
      total = 0
      for line in _strip_comments(text):
          s = line.strip()
          if s.startswith("#if"):
              if re.match(r"#if\s+os\(tvOS\)\s*$", s):
                  stack.append("tv")
              elif re.match(r"#if\s+!os\(tvOS\)|#if\s+os\(iOS\)", s):
                  stack.append("notv")
              else:
                  stack.append("other")
              continue
          if s.startswith("#elseif"):
              if stack:
                  stack[-1] = "other"
              continue
          if s.startswith("#else"):
              if stack:
                  stack[-1] = {"tv": "notv", "notv": "tv"}.get(stack[-1], "other")
              continue
          if s.startswith("#endif"):
              if stack:
                  stack.pop()
              continue
          for pattern in PATTERNS:
              total += len(pattern.findall(line))
          in_tv = "tv" in stack or (tv_file and "notv" not in stack)
          if in_tv:
              total += len(NAV_TITLE.findall(line))
      return total


  def scan():
      counts = {}
      root = os.path.join(APP_ROOT, SCAN_ROOT)
      for dirpath, _, files in os.walk(root):
          for name in sorted(files):
              if not name.endswith(".swift"):
                  continue
              rel = os.path.relpath(os.path.join(dirpath, name), APP_ROOT).replace(os.sep, "/")
              if is_exempt(rel):
                  continue
              with open(os.path.join(dirpath, name), encoding="utf-8") as f:
                  n = count_violations(f.read(), rel)
              if n:
                  counts[rel] = n
      return counts


  def compare(current, baseline):
      worse = {p: (baseline.get(p, 0), n) for p, n in current.items() if n > baseline.get(p, 0)}
      better = {p: (b, current.get(p, 0)) for p, b in baseline.items() if current.get(p, 0) < b}
      return worse, better


  def main():
      parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
      mode = parser.add_mutually_exclusive_group(required=True)
      mode.add_argument("--check", action="store_true")
      mode.add_argument("--update", action="store_true")
      args = parser.parse_args()

      current = scan()
      if args.update:
          with open(BASELINE, "w", encoding="utf-8") as f:
              json.dump(dict(sorted(current.items())), f, indent=2)
              f.write("\n")
          print("design-token baseline: %d files, %d findings" % (len(current), sum(current.values())))
          return 0

      with open(BASELINE, encoding="utf-8") as f:
          baseline = json.load(f)
      worse, better = compare(current, baseline)
      for path, (was, now) in sorted(worse.items()):
          print("%s: %d hard-coded style(s), baseline %d. Use ICubeDesign tokens "
                "(Common/Swift/MenuKit/ICubeDesign*.swift) or mark the line "
                "'// %s <reason>'." % (path, now, was, ALLOW_MARKER))
      if better:
          print("design-token ratchet: %d file(s) improved; run --update to lower the baseline." % len(better))
      if worse:
          return 1
      print("design-token ratchet: OK (%d findings across %d files)" % (sum(current.values()), len(current)))
      return 0


  if __name__ == "__main__":
      sys.exit(main())
  ```

- [ ] **Step 4: Run the unit tests.**

  ```bash
  cd Source/iOS/App && python3 -m unittest Project/Scripts/test_check_design_tokens.py -v
  ```

  Expected: `OK`, 6 tests.

- [ ] **Step 5: Generate the baseline and confirm the check passes**

  ```bash
  cd Source/iOS/App && python3 Project/Scripts/check_design_tokens.py --update && python3 Project/Scripts/check_design_tokens.py --check
  ```

  Expected: a baseline line, then `design-token ratchet: OK`. Run `head -20 Project/Scripts/design_tokens_baseline.json` to see it. `GameGridItem.swift` and `TVLibraryView.swift` should be present. No `ICubeDesign*` file and no `Debug` file may appear.

  Then prove the ratchet bites:

  ```bash
  echo '  let x = Color.cyan' >> Common/Swift/MenuKit/TileFace.swift
  python3 Project/Scripts/check_design_tokens.py --check; echo "exit $?"
  git checkout -- Common/Swift/MenuKit/TileFace.swift
  ```

  Expected: a `TileFace.swift: ... baseline ...` line and `exit 1`.

- [ ] **Step 6: Add the CI step**

  In `.github/workflows/tests.yml`, directly after the "Check ButtonType drift" step, add:

  ```yaml
      # Blocking ratchet: no file may gain hard-coded fonts, radii, line widths or colours
      # (design spec §4.3). Lower the baseline with --update when a file improves.
      - name: Check design-token ratchet
        working-directory: Source/iOS/App
        run: |
          python3 -m unittest Project/Scripts/test_check_design_tokens.py
          python3 Project/Scripts/check_design_tokens.py --check
  ```

- [ ] **Step 7: Commit**

  ```bash
  chmod +x Source/iOS/App/Project/Scripts/check_design_tokens.py
  git add Source/iOS/App/Project/Scripts/check_design_tokens.py Source/iOS/App/Project/Scripts/test_check_design_tokens.py \
    Source/iOS/App/Project/Scripts/design_tokens_baseline.json .github/workflows/tests.yml
  git commit -m "ci(design): ratchet hard-coded styling against a per-file baseline"
  ```

---

### Task 9: Whole-branch verification

- [ ] **Step 1:** `cd Source/iOS/App && tuist generate --no-open`
- [ ] **Step 2: Run the design and menu tests**

  ```bash
  make test TEST_ARGS="-only-testing:iCubeTests/ICubeDesignTests -only-testing:iCubeTests/ICubeCardFocusTests -only-testing:iCubeTests/ICubeDesignSnapshotTests -only-testing:iCubeTests/MenuModelTests -only-testing:iCubeTests/MenuFocusRouterTests -only-testing:iCubeTests/LibraryIdleDuringPlayTests"
  ```

  Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 3:** `python3 Project/Scripts/check_design_tokens.py --check && python3 Project/Scripts/check_localized_keys.py --check && python3 Project/Scripts/check_button_types.py`. Expected: all exit 0.
- [ ] **Step 4:** `make gate-release`. Expected: two `BUILD SUCCEEDED` lines, iOS then tvOS, and no `: error:`.
- [ ] **Step 5:** `git checkout -- build/xcframework && git status --short`. Expected: clean.
- [ ] **Step 6: Report.** For each task, give the SHA, the test counts and the snapshot PNG paths.

  The owner's device checks for this step are:
  1. On Apple TV, library cards rest visibly flatter. The cover and the placeholder both rest at 2°, and the focus lift, tilt and glow look exactly as before.
  2. Pause tiles, settings sidebar, controller hub and info shelf look unchanged.
  3. All three Background Styles look unchanged in light and dark. With Animated selected, start a game and confirm the background goes static.
