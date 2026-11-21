# Onboarding, what's new and required interstitials: one shared framework

Date: 2026-11-21. Status: proposal, not built. Apps: iCube and iFly first; Provenance later (see "Later").

## Why

iCube, iFly and Provenance launch together and share libraries with each other. Hosting a library is off until
the user turns on Share My Library, so a fresh install of every app shares nothing and a sibling app that wants
a game back (Provenance restoring a ROM tvOS purged) finds no source. The 2026-11-19 audit found no flag hiding
these features in iCube; the gap is that nobody is asked.

The owner's decision (2026-11-21): rather than switch sharing on silently, add a first-run flow that walks the
user through the options that matter and ends on adding games, and build it as a general framework that also
carries what's-new pages and required interstitials (settings resets, migrations).

## What exists today (iCube)

- `LibraryWelcomeView`: one full-screen welcome over the empty library with three actions (import, add a
  source, later). Seen-state is the `onboarding_seen_v1` defaults key, written in `TVLibraryView`.
  iOS shows it as an overlay; tvOS as a full-screen cover so focus cannot leave it.
- `Common/Swift/Tips`: TipKit behind a `TipsProviding` protocol, already compiled for iOS 17 and tvOS 17.
  `LibraryTipsState.welcomeFinished` holds the Import tip until the welcome is done.
- Screenshot mode never configures TipKit and pre-sets one-shot keys, so nothing pops over a store shot.
- No what's-new screen, no shared place for required notices, no single list of the app's links
  (wiki base URL is in `ICubeWiki`, others are inline).

## Third-party kits

| Kit | Platforms declared | Decision |
|---|---|---|
| WhatsNewKit (SvenTiigi) | iOS 13, macOS 11, visionOS 1. **No tvOS.** | Do not depend on it. Borrow: a version store protocol (defaults, iCloud KVS, in-memory for tests), "patch falls back to nearest minor/major", a title + feature rows + primary/secondary action page. |
| LinksKit (FlineDev) | iOS 16, macOS 13, **tvOS 17**, visionOS 1, watchOS 9 | Borrow the model (help, legal, social, own apps, friends' apps as nested sections); decide on depending on it in phase 3. Its README states no license; check the repo's LICENSE file first. |
| TipKit (Apple) | In use here on iOS 17 and tvOS 17 | Keep for in-context hints only. Not used to drive pages. |

Platform lines were read from each kit's `Package.swift` on 2026-11-21.

## The package: `PVOnboarding`

Its own repo under Provenance-Emu, consumed by URL like PVWidgets and PVWebServer. iOS 17, tvOS 17, macOS 14,
visionOS 1. No dependency on any app, on PVContinuity or on a design system: apps pass views and a theme in.

### Model

- `FlowStep`: `id` (stable string), `kind`, `revision` (Int; raising it shows the step again),
  `condition` (closure over a `FlowContext`), `isBlocking`, and a view builder that receives a `FlowActions`
  handle (`next`, `skip`, `finish`, `open(route)`).
- `kind` is one of three, and fixes the order they run in at launch:
  1. `required`: blocking, no skip. Settings resets, migrations, a library move that must finish.
  2. `whatsNew(version)`: shown once per version to upgraders; patch versions fall back to the nearest minor.
  3. `onboarding`: shown once to a fresh install, skippable page by page and as a whole.
- `FlowContext`: `isFreshInstall`, `previousVersion`, `currentVersion`, `platform`, plus an app-supplied
  dictionary for conditions such as "JIT available" or "iCloud signed in".
- `FlowStore` protocol with defaults, iCloud key-value and in-memory implementations. It records
  `id -> revision completed`. Fresh install is "no stored version and no prior app data", decided by the app
  (iCube: no `onboarding_seen_v1` and an empty library), so an existing user is never shown the first-run flow.
- `FlowCoordinator` (`@Observable`): given all registered steps and the context, publishes the ordered queue
  and the current step. Pure logic, unit-tested without UI.

### Presentation

- `FlowHost` view modifier on the app's root. iOS: full-screen cover with a page indicator, Back, Skip and a
  primary button. tvOS: full-screen cover, default focus on the primary button, Menu goes back one page and
  never dismisses a `required` step.
- A stock page layout (hero, title, body, up to four rows, primary and secondary action) so most steps are data.
  A step may supply any view instead.
- Never shown while a game is running, in screenshot mode, or under UI tests unless a launch argument asks.

### Rules

- A step that changes a setting writes it when the user continues, not when the page appears.
- A switch on a page shows its real current value. Pre-selected on is allowed only where stated below.
- A `required` step declares what happens if the app is killed mid-step; migrations stay in the app and must be
  resumable. The package only hosts the screen and reports completion.
- Every step is reachable again from Settings (Help > "Show setup again", "What's new").

## The first-run flow (iCube and iFly)

Five pages. Skins, cheats and patches are not pages; they are TipKit hints where the feature lives.

1. **Welcome.** What the app is, one sentence on what the next pages do, Skip All.
   Skip All changes no setting: Share My Library stays off (decided 2026-11-21).
2. **Keep your saves.** iCloud Sync on or off, with what syncs. Hidden when iCloud is unavailable.
3. **Your devices.** Share My Library, **pre-selected on**, with the transport notice
   (`ContinuityManager.transportSecurityNotice`) on the page and "paired devices only". This is the first page
   allowed to cause the local network prompt (see "Local network prompt" below). Existing users see this page once as a `whatsNew` step, pre-selected to
   their current value (off), so upgrading never opens a listener by itself.
4. **Performance.** iCube: JIT status and the one or two choices that matter on this device, link to the wiki.
   iFly: its equivalent, or the page is omitted by condition.
5. **Add games.** Ends the flow. Rows, each opening the app's existing screen:
   - Nearby libraries, Emulation Servers and RomM servers found right now, as one-tap adds (live discovery,
     same model as the library: `NearbyLibrariesModel`). Unpaired devices say "Pair to browse"; nothing is
     paired passively.
   - Files (iOS). Upload over Wi-Fi with the QR code (both platforms; the main route on tvOS).
   - Add a server by address: Emulation Server, RomM, and WebDAV or SMB where the app supports them.
   - Later.

`LibraryWelcomeView` becomes page 5's content and is removed as a separate overlay; `onboarding_seen_v1`
migrates to the store as "onboarding complete" so current users are not shown the flow.

## Local network prompt

Today the library starts Bonjour browsing as soon as it appears (`TVLibraryView` calls
`nearby.setLibraryVisible(true)` in `onAppear`), so the system's local network alert can come up behind the
welcome on first launch, before anything has explained it. With a multi-page flow that would put the alert over
page 1.

- While a flow is on screen the app must not browse or advertise. `FlowCoordinator` publishes `isPresenting`;
  the app holds `setLibraryVisible(true)` (and anything else that touches the local network, such as DSU
  discovery) until it is false.
- A step may declare `needsLocalNetwork`. The host lifts the hold when such a step is reached: page 3 when the
  user continues with sharing on, otherwise page 5, whose live discovery needs it whatever the sharing choice.
  Page 3's text therefore covers both uses: finding other libraries, and sharing this one.
- Skip All before page 3 ends the flow, and the library's own browsing then causes the alert as it does today.

## Phases

1. **Launch.** Package with model, store, coordinator, host and stock page; iCube and iFly first-run flow;
   the sharing page as a what's-new step for upgraders; one `required` step type proven with a real case
   (pick one existing reset or migration notice per app).
2. **What's new.** Per-version pages authored as data in each app, with the Settings entry to reopen them.
3. **Links.** One per-app links manifest (wiki, blog, privacy policy, support, sibling apps, project links)
   feeding About, Help and the "learn more" links on pages. Decide then between LinksKit and a small own model.
4. **Tips.** Move the skins, cheats and patches hints onto TipKit rules that start after onboarding completes.

## Tests

- Coordinator: ordering (required, what's new, onboarding), fresh install vs upgrade, revision bump re-shows,
  patch-version fallback, conditions, skip-all, kill and relaunch mid-flow.
- Store: each implementation round-trips; legacy `onboarding_seen_v1` migrates.
- Per app: Share My Library is unchanged for an upgrader who dismisses the page; on for a fresh install that
  continues; off for one that turns the switch off or skips all.
- Local network: no browse or advert starts while a flow is presenting and no `needsLocalNetwork` step has
  been reached; it starts on reaching one and on dismissal.
- tvOS: focus lands on the primary button on every page; Menu cannot leave a required step.

## Open questions

- Should completion sync through iCloud, so a second device skips the tour but still asks the per-device
  questions (sharing, local network)? Proposed: per-device for pages that set device settings.
- iFly's performance page content, and which of WebDAV and SMB each app supports today.

## Later

- Bring Provenance onto `PVOnboarding`. It already uses the other kits, so this is a replacement, not an
  addition: file a ticket once phase 1 has shipped in iCube and iFly.
