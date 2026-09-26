# Data-driven menu engine design (D18)

Companion to `docs/superpowers/plans/2026-09-24-controller-followups.md` item 18 and
`docs/audits/2026-09-24-controller-system-audit.md`. Scope: one `MenuModel` +
one `MenuScreen` renderer that replaces the hand-built, per-item focus code in
`PauseMenuView.swift`, `ControllerSetupView.swift`, `CheatsMenuView.swift`,
`Shaders/ShaderSettingsView.swift` and `SaveStateFilmstripView.swift`'s host
list, and adapts (not rewrites) `SettingsRootView.swift`.

**Correction to the plan's framing:** `SettingsRootView.swift` is 395 lines and
already data-driven — `SettingsEntry` / `SettingsListSection` with `AnyView`
destinations, already `.searchable` on iOS (`SettingsRootView.swift:134–239`).
The "~5000 lines" figure in the plan/memory is stale. Settings migrates as a
thin adapter, not a rewrite; its 15 leaf config pages (`ConfigGeneralView`,
`GraphicsHacksView`, …) are plain `Form`/`List` and are explicitly **out of
scope** — they already work on both platforms.

## 1. `MenuModel`

```swift
struct MenuModel {
  var sections: [MenuSection]
}

struct MenuSection: Identifiable {
  let id: String                 // stable, e.g. "gc-players", not UUID()
  var header: String?
  var items: [MenuItem]
}

struct MenuItem: Identifiable {
  let id: String                 // stable — see §6 on why this matters
  var title: String
  var subtitle: String?
  var icon: String?              // SF Symbol name
  var tint: Color?
  var role: MenuItemRole
  var badge: String?             // "3 active", pre-formatted, never computed in `body`
  var isEnabled: Bool = true
}

enum MenuItemRole {
  case action(() -> Void)
  case toggle(Binding<Bool>)
  case picker(options: [(String, AnyHashable)], selection: Binding<AnyHashable>)
  case navigation(() -> MenuModel)          // pushes a child MenuScreen
  case destination(AnyView)                 // adapter escape hatch (Settings leaves)
  case custom(AnyView)                      // opaque leaf (save-state filmstrip, shader thumbnail)
  case destructive(() -> Void)
}
```

`MenuItem.id` is a stable string (`"resume"`, `"gc-port-2"`, `"cheat-\(cheat.id)"`),
**not** `UUID()`. Two existing precedents justify this:
`SettingsEntry.id` is already `title` (derived, not fresh) specifically
because a computed section list with fresh UUIDs "churns `ForEach` identity …
tearing down and rebuilding rows and popping an open destination back to the
list" (`SettingsRootView.swift:134–140`). `PauseMenuView.IOSMenuItem.id =
UUID()` (`PauseMenuView.swift:69`) is exactly that anti-pattern today — it is
masked only because `iosMainMenu` keys its `ForEach` on `\.offset`
(`PauseMenuView.swift:326`), so focus tracks a **position**, not an item. Any
mid-session model change (mute flips a title, a cheats badge arrives, the
`#if os(iOS)` Settings row appears) reshuffles what index N means. `MenuScreen`
tracks the focused **id**, resolving it to an index only at render/move time,
so focus survives a model rebuild.

**Providers, not inline bridge calls.** `ControllerAssignmentService` takes a
`ControllerConfigWriting` protocol instead of calling `DOLConfigBridge` /
`TVControllerMappingBridge` directly (`ControllerAssignmentService.swift:21–26`),
which is what makes it unit-testable. Every `MenuModel` builder in §4 follows
the same shape: `func makePauseMenuModel(state: PauseMenuState, actions: PauseMenuActions) -> MenuModel`
takes a plain snapshot struct and an actions struct, never reaches into a
bridge itself. Without this, §7's "model unit tests" have nothing to construct
against.

## 2. `MenuScreen`

One view, `MenuScreen(model: MenuModel, style: MenuStyle)`, with two renderers
behind `#if os(tvOS)`.

### iOS: manual navigation on `ControllerFocusCoordinator`

iOS has no focus engine (`PauseMenuView.swift:53–55`), so `MenuScreen` drives a
`focusedID: String?` from raw `GCController` input — but it does **not**
reinvent the ownership problem `PauseMenuView.setupPauseControllerNav` /
`prevPauseEGPHandlers` (`PauseMenuView.swift:60–64, 507–527`) has today. That
save/restore-the-previous-handler pattern is precisely the bug
`Controllers/ControllerFocusCoordinator.swift` already exists to fix
elsewhere (its own header: "a stale 'swallow' closure can outlive the screen
that installed it" — `ControllerFocusCoordinator.swift:14–19`). `TVLibraryView`
already uses it correctly: `.controllerScope(controllerScopeID)` plus every
raw handler gated on `ControllerFocusCoordinator.isActiveScope(scope)`
(`TVLibraryView.swift:1232, 2661, 2711`); `EmulationScreen` claims a scope
while the emulator is on screen (`EmulationScreen.swift:1312`). **`PauseMenuView`
never adopted the coordinator** — that gap is the direct mechanism behind
D17 ("library source picker steals focus… the sheet moves focus in the sheet
AND in the library behind it") and behind the "Controllers sheet left a stale
handler" class of bug. `MenuScreen` closes both by construction:

- Every `MenuScreen` instance calls `.controllerScope(_:)` with its own id on
  `.onAppear`/pops on `.onDisappear`, and its single `valueChangedHandler`
  installation gates every move/activate on
  `ControllerFocusCoordinator.isActiveScope(myScope)`.
- A `MenuScreen` presented as a `.sheet` over another `MenuScreen` is a second
  scope pushed on top; the coordinator's stack makes the covered screen inert
  without it ever needing an `onDisappear` (sheets don't fire one on the
  covered view). This is what D17 needs and gets for free.
- `PauseGestureTracker` (`PauseGestureTracker.swift:153–190`) is **not**
  gated by this stack — it is the sole pause-request sink regardless of which
  `MenuScreen` scope is active, exactly as today.

Input handling, replacing `movePauseFocus`/`activatePauseFocus`
(`PauseMenuView.swift:489–526`):

- **Move**: d-pad / left-stick, edge-triggered. Today's flat 0.18 s throttle
  (`PauseMenuView.swift:492`) is a throttle, not repeat — replace with an
  initial 0.4 s delay before the first repeat, then repeat every 0.08 s while
  held, with stick re-arm hysteresis (must fall back below ~0.3 before a new
  push past ~0.6 counts as a new edge) so a stick resting near the deadzone
  doesn't double-fire.
- **Activate (A/B)**: latch-and-rearm. `activatePauseFocus()` fires on
  `buttonA.isPressed` inside `valueChangedHandler`
  (`PauseMenuView.swift:524`), which the GameController framework can call
  more than once per physical press — the likely mechanism behind the
  "profile pick glitchy / double tap" report (plan item A, 4th bullet).
  `MenuScreen` latches on the press edge, fires the action once, and does not
  re-arm until the button reports released. The same primitive is reused
  verbatim by the remap UI's capture-arming guard (see the C7 spec).
- **Shoulders (L1/R1)**: jump between sections (first item of prev/next
  `MenuSection`), for models with more than one section (Controllers, Settings).

### tvOS: native focus only, no `GCController` handlers

`MenuScreen` installs **zero** GameController handlers on tvOS — this is a
hard rule, not a preference. The proof this is required, not a maybe, is
already in the tree: `ControllerSetupView.swift:336–348` documents that "a
List row is a SINGLE focus target" and that SwiftUI `Picker`/`Menu` have "no
usable tvOS presentation here either, the same reason the library toolbar's
`Menu`s were dead" — and ships the fix as `tvPlayerLink` / `tvOptionRow` /
`tvDeviceRows` (`ControllerSetupView.swift:350–398`): one focusable `Button`
per control, compound rows (device + extension + sideways + profile) exploded
into their own screen. `MenuScreen`'s tvOS renderer makes that shape the
**contract**, not a one-off:

- Every `MenuItem` becomes exactly one `List` row with exactly one control.
- `.toggle`/`.picker` roles render as their own `Button` rows (checkmark for
  the selected option), never a `Toggle`/`Picker` control embedded in a
  compound row — mirroring `tvOptionRow`.
- `.navigation` pushes a `NavigationLink` to a child `MenuScreen` — mirroring
  `tvPlayerLink`.
- `.onExitCommand` pops one level (matches every existing tvOS pane in
  `PauseMenuView`, e.g. `PauseMenuView.swift:200-208`, `1180-1182`).

## 3. Menu-chain lifecycle (fixes B1 as part of this, not after)

`PauseMenuView.onDisappear` resumes emulation unconditionally
(`PauseMenuView.swift:180–182`): "Any presentation that makes the menu's body
disappear … resumes the game underneath" (plan item B1). If `MenuScreen`
migration turns each pane into its own pushed/sheeted screen without fixing
this, B1 gets *worse* — more `onDisappear` firings, more spurious resumes.
`MenuScreen` therefore does not resume on its own disappearance; the root
pause-menu host (whatever presents the first `MenuScreen`) tracks "is any pane
in the chain still presented" and resumes only when that goes to zero — the
same scope-stack the coordinator already gives us: resume when
`ControllerFocusCoordinator`'s stack no longer contains this session's pause
scopes.

## 4. Screens as models

| Screen | Current file | Model shape |
|---|---|---|
| Pause menu (main pane) | `PauseMenuView.iosMenuItems` / `tvMainMenu` | One `MenuSection`; items = Resume, Mute, Fast Forward, Save States, Cheats, Controllers, Shaders, Continue Elsewhere, [Settings iOS-only], Reset, Exit. `.navigation` for Save States/Cheats/Controllers (pane push), `.action` + sheet trigger for Shaders/Settings/Controllers on iOS, `.toggle`-shaped `.action` for Mute/Fast Forward (icon+subtitle already flip on state, unchanged). |
| Quick Slots | `SaveStateFilmstripView` host section in `PauseMenuView.savesMenu` | `MenuSection` "Quick Slots" (`.picker` over slots 1–10) + `MenuSection` "Actions" (Save/Load/Open Filmstrip as `.action`). The filmstrip itself (`SaveStateFilmstripView.swift`) stays a `.custom` leaf — its horizontal drag-scroll of thumbnail cards doesn't map onto a linear item list; only the *wrapping* list becomes a model. |
| Controllers | `ControllerSetupSections` in `ControllerSetupView.swift` | Sections: GameCube Controllers / Wii Remotes (each port a `.navigation` item whose child model is Device / Profiles / Customize Buttons / Extension / Sideways — literally `tvPlayerLink`'s existing content, now expressed as a model instead of hand-written per platform), General, Wii Remotes (Global). `applyGC`/`applyWii`/`setWiiExtension`/`setWiiSideways` (`ControllerSetupView.swift:476–543`) become the action closures — unchanged bodies, just called from `MenuItem.role` instead of a `Button`. |
| Cheats | `CheatsMenuView.swift` | One section per type (Gecko/Action Replay) or one flat section; each cheat a `.toggle` item. Pause-menu row badge ("N active") is a **snapshot** taken when the pause menu model is built (`geckoCodeList.filter(\.enabled).count + actionReplayCodeList.filter(\.enabled).count`, from data already read in `CheatsMenuView.loadCheats()`), never recomputed in `body` — it is a per-game disk read via `TVCheatsBridge`. |
| Shaders | `Shaders/ShaderSettingsView.swift` `ShaderPickerView` | Sections: Favorites / Recently Used / All, `.action` per preset (apply + push MRU), `.action` toggle-star item. Live thumbnail preview stays a `.custom` leaf per row. |
| Save States (pause pane) | `PauseMenuView.savesMenu` | Same as Quick Slots above — this is the same screen. |
| Settings root | `SettingsRootView.swift:175–213` | `SettingsEntry` maps 1:1 onto `MenuItem { role: .destination(entry.destination) }`; `SettingsListSection` maps 1:1 onto `MenuSection`. tvOS keeps rendering as `List` of `NavigationLink`s — that already works (one `NavigationLink` = one focus target, same reasoning as `tvPlayerLink`); iOS gains controller navigation it does not have today (a SwiftUI `List` is touch-only on iOS without a focus engine — Settings today is **not** controller-navigable on iOS, which is exactly what item 18 asks to fix). |

Not modeled: the ~15 individual config leaf views (`ConfigGeneralView`,
`GraphicsHacksView`, `DebugRootView`, etc.). They are plain `Form`/`List` with
native `Toggle`/`Slider`/`Picker` controls that iOS presents natively (they
are reached via tap or, on tvOS, native focus through a pushed `List`) — no
tvOS focus-trap has been reported inside them because they don't nest a
`Picker`/`Menu` inside a shared row. Bringing them under `MenuModel` is
explicitly out of scope; doing so would turn a menu-engine spec into a
settings-tree rewrite.

## 5. Style-preservation token table (iOS pause-menu visual language)

`MenuScreen`'s default iOS row renderer reproduces `menuButtonIOS` /
`menuRowIOS` (`PauseMenuView.swift:387–436`) exactly, as constants:

| Token | Value | Source |
|---|---|---|
| Icon chip | 44×44, `RoundedRectangle(cornerRadius: 10)`, fill `tint.opacity(0.15)` | `PauseMenuView.swift:392–394` |
| Title | 16 pt semibold, `.white` | `:400–402` |
| Subtitle | 13 pt medium, `.white.opacity(0.7)` | `:403–405` |
| Card | `RoundedRectangle(cornerRadius: 12, style: .continuous)`, `.ultraThinMaterial` fill, `.white.opacity(0.08)` 1 pt stroke | `:422–428` |
| Focus ring | same shape, `Color.accentColor` stroke, 3 pt, drawn only when the item's id equals the router's `focusedID` | `:430–433` |
| Grid | `LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12)` | `:325` |

tvOS keeps its existing row look (`tvMenuToggleRow` shape, `PauseMenuView.swift:442–469`
and the repeated `HStack`s in `tvMainMenu`) as the default tvOS row renderer's
constants — same numbers, different font weights already tuned for the 10-foot
UI. No visual change is a goal of this migration; only the code path that
produces the pixels changes.

## 6. Migration order and deletions

0. Land `MenuModel` + `MenuScreen` + the iOS input handling in isolation,
   under `DolphiniOSTests` (see §7), with **no callers yet**.
1. **Settings root** (adapter, lowest risk — proves `.destination` and
   confirms the tvOS `List`-of-`NavigationLink` path needs no change).
2. **Pause menu main pane.** Highest value: deletes `iosMenuItems`,
   `menuButtonIOS`, `setupPauseControllerNav`, `movePauseFocus`,
   `activatePauseFocus`, `teardownPauseControllerNav`,
   `prevPauseEGPHandlers` (`PauseMenuView.swift:56–64, 387–436, 471–542`), and
   collapses `tvMainMenu`'s ~300 lines of copy-pasted row `HStack`s
   (`PauseMenuView.swift:640–937`) into one `tvMenuRow` + the model. Also
   where B1 (§3) gets fixed.
3. **Controllers.** Wraps `ControllerSetupSections` in `MenuScreen` for iOS
   nav; the existing `tvPlayerLink`/`tvOptionRow`/`tvDeviceRows`
   (`ControllerSetupView.swift:336–398`) are deleted in favor of
   `MenuScreen`'s tvOS renderer, which now implements that exact contract
   once for every screen instead of per-view.
4. **Cheats**, adding the active-count badge to the pause-menu item.
5. **Shaders** picker.
6. **Save States / Quick Slots** wrapping list (filmstrip itself untouched).

Each step is independently shippable and independently revertable — none
depends on a later step.

Not migrated by this plan, and explicitly out of scope: the top-bar HUD
(plan item 13) and the library source-picker sheet's own list contents (plan
item 17) — this design's `ControllerFocusCoordinator` adoption gives 17 the
mechanism it needs, but 17's actual sheet content is not touched here.

## 7. Test strategy

- **Model unit tests**, in `DolphiniOSTests` (already the home of
  `ControllerAssignmentServiceTests.swift` and `AssignmentEngineTests.swift`,
  so the target and the "fake provider" pattern both already exist — this is
  not new test-infrastructure work). Given a synthetic `PauseMenuState` /
  `ControllerSetupState` / cheat-list snapshot, assert the produced
  `MenuModel`'s section/item ids, titles, badges and enabled-state, with no
  `DOLConfigBridge`/`TVControllerMappingBridge` calls in the test — enforced
  by the builder-takes-a-snapshot rule in §1.
- **Focus-order tests**: pure functions, no `GCController` involved. Feed a
  `MenuModel` and a scripted sequence of synthetic move/activate events into
  the router's move/activate functions directly (not through
  `valueChangedHandler`) and assert the resulting `focusedID` sequence:
  clamping at section ends, shoulder jump targets, wrap behavior (none, by
  design — `movePauseFocus` clamps today, `PauseMenuView.swift:497`, keep
  that), and the repeat-timing edges (initial delay vs. repeat interval) using
  a fake clock.
- **Not unit-testable, needs a device**: actual `GCController` hardware
  input (a synthetic `GCExtendedGamepad` cannot be constructed off-device),
  the coordinator's real cross-scope interaction under real `.sheet`
  presentation, and all tvOS focus/visual verification.

## 8. Risks

- **Single point of failure.** Every menu now shares one router; a router bug
  is a bug in all seven screens at once. Mitigated by §7's isolation tests
  and by shipping migration steps independently (§6) rather than in one PR.
- **Scope-stack integration is manual per call site.** `.sheet`/
  `.fullScreenCover` presentations must each explicitly wrap their content in
  a `MenuScreen` (which self-claims a scope) — forgetting this on a new sheet
  reintroduces exactly the D17 class of bug the coordinator is meant to
  prevent. No compiler check catches a missing scope claim.
- **Compound-row temptation on tvOS.** Any future `MenuItem` role that tries
  to pack two controls into one row (e.g. a labeled slider) will silently
  regress tvOS focus unless it is decomposed per §2's contract — this needs
  to be a review checklist item, not just documentation.
- **Badge cost.** Cheats' active-count is a disk read; computing it lazily
  per pause-menu open (not per `body` evaluation) is required, and there's no
  compiler enforcement of that either — a future edit that inlines the count
  into the view would reintroduce per-frame I/O.
- **This absorbs D13/D17 by design, not by accident** — the plan says so
  explicitly ("This also absorbs 13 (HUD) and the tvOS focus traps"). This
  spec gives 17 its mechanism (§2) but does not redesign the HUD (13); a
  follow-up spec is still needed for the HUD's own visual/interaction design.

## 9. Implementation status (2026-09-26 — engine pass)

The engine (§0 of §6's migration order) landed with one proof-of-life screen.
**No other screen was touched** — `PauseMenuView.swift`, `SettingsRootView.swift`,
`ControllerSetupView.swift`, `Shaders/ShaderSettingsView.swift` and
`SaveStateFilmstripView.swift` are all unchanged.

### What landed

- **`RemapControllerNav` moved, not rewritten.** The struct now lives at
  `Common/Swift/Menu/MenuControllerNav.swift` as `MenuControllerNav`, with two
  additions: `Input.leftShoulder`/`rightShoulder` and `Event.jumpSection(Int)`,
  both added *after* the existing fields/cases so every pre-existing
  `RemapModelTests` call site keeps compiling unchanged.
  `Controllers/Remap/RemapModel.swift` now reads
  `typealias RemapControllerNav = MenuControllerNav`; `RemapPlayerView.swift`
  needed exactly one change, an added `case .jumpSection: break` in its
  (now non-exhaustive) event switch, since it wires no shoulder input.
- **`MenuModel` / `MenuSection` / `MenuItem` / `MenuItemRole`**
  (`Menu/MenuModel.swift`) — matches §1 exactly, plus lookup helpers
  (`allItems`, `focusableIDs`, `item(id:)`, `section(containing:)`,
  `firstFocusableID(sectionOffsetFrom:by:)`) that `MenuFocusRouter` and the
  model-construction tests are built on.
- **`MenuFocusRouter`** (`Menu/MenuFocusRouter.swift`) — the pure router §7
  asks for, composing `MenuControllerNav` with a `MenuModel`. Two behaviors
  the spec's prose didn't spell out, added after review and covered by
  regression tests in `MenuFocusRouterTests`:
  - **Claim-ignore resyncs, it doesn't just drop input.** A naive "skip the
    tick while another scope owns the controller" leaves the B/A latches
    stuck at their last-seen state; if the same physical press that
    dismissed a covering screen is still held the instant this screen
    regains ownership, that reads as a brand-new edge and double-fires
    (e.g. a double pop). `update(..., isActive: false)` calls
    `MenuControllerNav.resync` every inactive tick instead.
  - **Open-press leak.** The press that activated a `.navigation` item in a
    parent screen is still held on the child's first tick, and unlike
    `RemapPlayerView` (which starts with no highlight), a `MenuScreen`
    defaults focus to its first item immediately — so an `update` there
    would self-activate. `MenuScreen` calls `router.resync(...)` once,
    instead of `update(...)`, on the first tick after appearing.
  - `MenuFocusRouter.reconcile(focusedID:previousOrder:model:)` handles a
    model rebuilt out from under a live focus (the id it names may no
    longer exist): keeps focus if the id survived, else falls back to
    whatever now sits at the same flat index, else the first item.
    `MenuScreen` wires this via `.onChange(of: model.focusableIDs)`.
- **`MenuScreen`** (`Menu/MenuScreen.swift`) — renders a `MenuModel` with a
  `MenuStyle` of `.grid` (pause-menu card look, §5 tokens — **visually
  unverified**, no consumer yet) or `.list` (plain `List`, what Settings/
  Cheats/Controllers already look like). Every instance self-claims a
  `ControllerFocusCoordinator` scope via `.controllerScope(_:)`. `.navigation`
  items push a child `MenuScreen` via `.navigationDestination(item:)` on both
  platforms. `onBack` is a plain optional closure, not `dismiss()` — the host
  decides what "back" means (see the Cheats migration below).
  - **Deviation from §2's prose:** iOS polls `GCController` state on a
    `.common`-mode `Timer`, the same mechanism `RemapPlayerView` already
    uses — it does **not** install a `valueChangedHandler`. The design doc's
    §2 describes the router as consuming `valueChangedHandler` callbacks;
    that would fight `PauseMenuView.setupPauseControllerNav`'s handler for
    the same process-wide slot the moment both are alive at once (true for a
    `MenuScreen` presented as a `.sheet`/`.fullScreenCover` over the pause
    menu, though not for a pane swapped in via `switch pane` the way Cheats
    is today — see below). Polling structurally cannot contend for that slot
    regardless of presentation style, so it was kept as the one deliberate
    behavioral deviation from the doc's wording. Revisit once/if
    `PauseMenuView` itself adopts the coordinator.
  - **tvOS** installs zero GameController code: `List`, one `Button`/
    `NavigationLink` per item, `.picker` explodes into one row per option
    (checkmark for the selection) instead of an embedded control,
    `.defaultFocus` on the first focusable item, `.onExitCommand` calls
    `onBack`. No section-jump on tvOS — there is no shoulder input path to
    wire it to; native focus traversal is unchanged either way.
    **Fixed 2026-09-26** (Cheats tvOS pass): the engine pass above shipped
    `.defaultFocus($tvFocusedID, first)` with **no `tvRow` ever attaching a
    matching `.focused($tvFocusedID, equals:)`** — the binding had nothing
    to resolve to, so it was dead on arrival for any real screen. Every
    `tvRow` case now binds `.focused`; a `.picker`'s exploded option rows
    use a composite `"\(item.id)#\(index)"` id, and the default-focus lookup
    (`defaultTVFocusID`) accounts for a first item that happens to be a
    picker. This bit the moment Cheats became the first real tvOS consumer
    (below) — a clean tvOS build proved nothing about it, per this doc's own
    warning that a build is not a focus test.
- **Multi-pad polling, fixed 2026-09-26.** `MenuScreen` originally polled
  only `GCController.controllers().first { $0.extendedGamepad != nil }` —
  a second connected pad could not drive the menu at all.
  `MenuFocusRouter` now keys one `MenuControllerNav` per pad (a
  caller-supplied `AnyHashable`; `MenuScreen` uses
  `ObjectIdentifier(GCController)`), mirroring `PauseMenuView.pauseNavGates`'s
  per-`ObjectIdentifier` latch keying for the same reason a single shared
  latch, or OR-ing raw booleans before edge-detection, can never register a
  fresh press from pad B while pad A holds the same button down. Every
  pad's edges for a tick drain into one focus timeline in `padInputs`
  order — a pad that only moves and a pad that only activates combine
  correctly, and at most one `.activate`/`.back` is honoured per tick, so
  two pads independently pressing A in the same tick still fires once. A
  pad seen for the first time — this screen's very first tick (all pads are
  "new" then), or a controller that connects mid-session — is `resync`ed
  rather than `update`d, exactly like the single-pad open-press-leak fix, so
  an already-held button on first sight never reads as a fresh edge. This
  subsumed the old screen-level `hasSyncedInitialInput` flag entirely: it's
  now a per-pad fact the router itself tracks, not a per-screen one
  `MenuScreen` had to remember.
- **Modal-answer hook, added 2026-09-26.** A host-presented `.alert` (first
  need: Cheats' "Enable Cheats?") has no way to stop `MenuScreen`'s raw
  `GCController` polling from continuing to act on the rows *behind* it —
  unlike touch, which UIKit itself blocks for the covered hierarchy while an
  alert is up, the polling bypasses the responder chain entirely. Added
  `MenuScreen.modal: MenuModal? = nil` (`onConfirm`/`onCancel`), declared
  after `onBack` so every existing `MenuScreen(model:style:onBack:)` call
  site keeps compiling unchanged. While non-`nil`, `tick()` still calls
  `router.update` (so per-pad latch state keeps tracking reality) but routes
  the result differently: an `.activate` edge calls `onConfirm`, a `.back`
  edge calls `onCancel`, and neither reaches the underlying rows. Because
  the SAME per-pad `MenuFocusRouter`/`MenuControllerNav` state is reused —
  never reset or resynced at the modal boundary — the press that toggled a
  row and thereby opened the modal is still latched down on the modal's
  first tick (so it can't replay as an instant confirm), and the confirming
  press is still latched once the modal clears (so it can't replay onto a
  row). tvOS needs no equivalent: its `.alert` is answered by the native
  focus engine like any other tvOS UI, and `MenuScreen` installs no
  `GCController` code there at all.
- **Cheats — no longer iOS-only.** `CheatsMenuView.swift` now renders the
  SAME `CheatsMenuModelBuilder` model on both platforms via
  `MenuScreen(style: .list)`. iOS wires the new `modal:` hook
  (`showEnableCheatsPrompt ? MenuModal(...) : nil`) so the "Enable Cheats?"
  alert is no longer answerable-in-appearance-only; the alert's own buttons
  and the modal hook both call shared `confirmEnableCheats()`/
  `cancelEnableCheats()`. **tvOS's bespoke two-column body is replaced**:
  the cover-image/title column is kept as non-focusable host chrome around
  `MenuScreen` (the "keep the cover-image flavour" option — §2's contract
  bars a compound *row*, not a hero slot beside the list), the bespoke Back
  button is gone (Menu — `MenuScreen`'s own `.onExitCommand` — is back, like
  every other tvOS pane), and inline search is dropped for tvOS entirely (no
  host affordance replaces it; `searchText` stays `""` so every cheat always
  lists — a `TextField` sibling's on-screen-keyboard detour wasn't judged
  worth the focus-order risk for a filter this screen can live without).
  `CheatsMenuState`/`CheatsMenuActions`/`CheatsMenuModelBuilder` are
  unchanged in shape; `CheatItem`/`FocusField`/`CheatRowView` (the last two
  tvOS-only and now dead) — `FocusField` and its `@FocusState` were deleted,
  as was `CheatRowView`.
  - **Also fixed in the same pass**: the builder gated its Download/Refresh
    section on `hasAnyCheats`, preserved verbatim from the pre-D18 iOS body.
    Harmless on iOS (which never had another way to reach Download either),
    but migrating tvOS onto this builder would have been a real regression —
    tvOS's pre-D18 bespoke body always showed Download regardless of
    `hasAnyCheats`, and Download is the *only* way to bootstrap cheats for a
    game that has none yet. The actions section is now unconditional on both
    platforms; `CheatsMenuModelBuilderTests.swift` (new) covers this and the
    enable-cheats-intercept toggle logic.
- **Tests**: `MenuModelTests.swift` (construction/lookup — allItems ordering,
  focusableIDs excluding disabled items, section lookup, section-jump lookup
  including the "already at the edge" no-op case, badge pass-through, binding
  plumbing), `MenuFocusRouterTests.swift` (move/clamp, section-jump
  including the double-press-doesn't-refire case, activate/back, the
  claim-ignore double-back regression, the open-press-leak regression,
  reconcile, **plus 4 new 2026-09-26 multi-pad-merge cases**: one pad moves
  while another activates in the same tick and both edges apply, two pads
  pressing A in the same tick fire exactly once and don't replay while held,
  a brand-new pad already holding A doesn't phantom-activate, and a second
  pad connecting mid-session is resynced independently of an already-known
  first pad), and `CheatsMenuModelBuilderTests.swift` (new — Download/Refresh
  focusable with zero cheats and with cheats, the empty-state row is present
  but not focusable, and the enable-cheats intercept only fires turning a
  cheat ON while global cheats are off). All wired into
  `DolphiniOS.xcodeproj/project.pbxproj`'s `iCubeTests` target — `MenuModelTests`/
  `MenuFocusRouterTests` at ids `...0973`–`...0976` (unchanged this pass),
  `CheatsMenuModelBuilderTests` newly at ids `...09A6`/`...09A7`. The
  existing `RemapModelTests.swift` needed no changes and still exercises the
  moved engine under its old name.
- **Fallback pbxproj**: `Common/Swift/Menu/` was added as a new
  `PBXFileSystemSynchronizedRootGroup` (id `...0977`), mirroring how
  `Common/Swift/Controllers/` is already wired — new files dropped into
  `Menu/` in the future need no further pbxproj edits. `CheatsMenuView.swift`
  itself was already an explicit (non-synced) reference, so its edits needed
  no pbxproj change. The Tuist project (the actual CI/build system) globs
  `Common/**/*.swift` and `DolphiniOSTests/**/*.swift` already, so it picked
  up every new file with a plain `tuist generate`.

### What each remaining screen migration needs (§6, unchanged order)

1. **Pause menu main pane.** The highest-value step (§6 step 2) and the one
   most likely to need `PauseMenuView` adopting `ControllerFocusCoordinator`
   first, since its raw handler is a single global slot that must stop
   fighting `MenuScreen`'s polling the moment both can be alive together
   (currently avoided only because Cheats/Saves are `switch pane` swaps that
   genuinely tear down `iosMainMenu`'s `onAppear`/`onDisappear`, not
   sheets). Also where B1 gets fixed per §3.
2. **Controllers.** Wrap `ControllerSetupSections`; delete `tvPlayerLink`/
   `tvOptionRow`/`tvDeviceRows` in favor of `MenuScreen`'s tvOS renderer,
   which already implements the picker-explosion contract those three
   hand-roll today (and, as of the 2026-09-26 fix above, actually binds
   focus for it).
3. **Shaders.** Sections need `.custom` leaves for the live thumbnail
   preview per row — `MenuItemRole.custom` already supports this; no engine
   changes anticipated.
4. **Save States / Quick Slots.** Lives in `PauseMenuView.savesMenu`
   (`PauseMenuView.swift`) — blocked on the pause-menu-pane migration (step
   1 above) landing first, or on a decision to touch `PauseMenuView.swift`
   in isolation for just this section.
5. **Settings root.** Lowest risk per §6, but note `MenuItemRole.destination`
   already round-trips correctly through both `MenuScreen` renderers in this
   pass (proven by `.destination` support in `MenuScreen.listRow`/`tvRow`,
   though no screen exercises it yet) — the adapter itself is still unwritten.

### Needs a device (not exercised by this pass's tests or builds)

- iOS: any real `GCController` input against `MenuScreen`/Cheats — the
  ticker, `connectedGamepads()`'s "every connected extended gamepad"
  selection (including with two physical pads connected at once), the
  scroll-to-focus behavior, the modal hook (does A actually confirm and B
  actually cancel "Enable Cheats?" with a real Siri Remote/MFi controller,
  not just the router-level unit tests), and the reconcile-on-model-change
  path (toggle a cheat, confirm focus survives; delete the last cheat via a
  fresh download, confirm focus falls back sanely).
- iOS: `ControllerFocusCoordinator` interaction between `MenuScreen` and
  anything else that claims a scope while Cheats is open (there is no such
  sheet today from this pane, so untested in practice, only in the router's
  unit tests).
- tvOS: focus traversal through `MenuScreen`'s `List`/`.defaultFocus`/
  `.onExitCommand` on a REAL Apple TV or simulator with the Siri Remote —
  Cheats is now the first real consumer, and a clean tvOS build (this pass
  has one) proves nothing about focus. Specifically needs verification:
  default focus lands on "Enable Cheats" (not the removed search field, not
  nothing), every cheat toggle is reachable and reachable-back-out-of via
  d-pad/swipe, Menu pops the pane, and the "Enable Cheats?" alert is
  answerable by remote.
- Both: the `.grid` `MenuStyle` (pause-menu card look) has no consumer and no
  device/screenshot comparison against `menuButtonIOS`/`menuRowIOS` — treat
  it as a draft until the pause-menu migration (step 1 above) adopts it.
