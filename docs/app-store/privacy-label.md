# App Store Connect: App Privacy answers (iCube 1.0, iOS and tvOS)

One privacy label covers the whole app record (iPhone, iPad and Apple TV). It must match `Source/iOS/App/DolphiniOS/PrivacyInfo.xcprivacy`, the website policy at `https://icube-emu.com/privacy/`, and Settings > Privacy in the app.

Items marked **OWNER** are decisions or confirmations that cannot be settled from the code.

## Answers to paste into the questionnaire

**Do you or your third-party partners collect data from this app?** Yes. The partner is Sentry (crash and performance reporting).

| Data type (Apple's name) | Collected | Linked to the user | Used for tracking | Purpose |
|---|---|---|---|---|
| Diagnostics > Crash Data | Yes | No | No | App Functionality |
| Diagnostics > Performance Data | Yes | No | No | App Functionality |
| Diagnostics > Other Diagnostic Data | Yes | No | No | App Functionality |

These three rows are exactly the three `NSPrivacyCollectedDataTypes` entries in `PrivacyInfo.xcprivacy` (Crash Data, Performance Data, Other Diagnostic Data; `Linked` false, `Tracking` false, purpose `AppFunctionality`). `NSPrivacyTracking` is false and `NSPrivacyTrackingDomains` is empty.

Every other data type: **Data Not Collected**. That covers Contact Info, Health and Fitness, Financial Info, Location, Sensitive Info, Contacts, User Content, Browsing History, Search History, Identifiers, Purchases, Usage Data and Other Data.

**Tracking:** the app does not track users. No IDFA, no App Tracking Transparency prompt, no data brokers, no advertising SDKs.

## What each declared type covers

- **Crash Data.** Crash reports and stack traces, including app hangs and watchdog terminations (Sentry crash handler, hang tracking).
- **Performance Data.** Launch and screen-load timings, hang durations, and frame-rate summaries from a sample of play sessions (about 1 in 10) and 20 percent of non-emulation traces (`SentryTelemetryService.swift`: `releaseTraceSampleRate` 0.2, `releaseSessionSampleRate` 0.10). Tracing is off while a game is running.
- **Other Diagnostic Data.** Device model, OS version, app build, the console family of a play session (GameCube or Wii, not which game), emulation settings tags (`jit`, `cpu_core`, `gfx_backend`), and MetricKit diagnostic payloads. MetricKit is iOS and iPadOS only: `options.enableMetricKit` is compiled out on tvOS.

## What the App Store build leaves out (basis for "not linked")

From `SentryTelemetryService.swift` and `SentryEventScrubber.swift`, under `#if APPSTORE`:
- No game ID or game title: the `game_id` and `game_title` tags are stripped from every event, transaction and span, and `game_id` is not set on the boot scope. Game titles are not sent, and file names ending in known game and data extensions are replaced by `<path>` in messages.
- File paths: absolute user paths in event, exception and breadcrumb messages are replaced by `<path>`; breadcrumb `url` data is removed.
- Network breadcrumbs, network tracking, failed-request capture and file-manager spans are all off (they could carry WebDAV host names and file names).
- No accounts and no email, name or user object is ever set. `sendDefaultPii` is not enabled.
- The reporting switch is Settings > Privacy > Share Crash Reports, on by default. Turning it off persists the choice, closes the SDK and deletes the SDK's on-disk queue (`applyConsent`, `removeSDKDiskState`), so nothing already queued is sent later.

## Data not collected by the developer, and why

- **Games, saves, states, settings, BIOS and system files.** Stay on the device. The app has no developer-run server for them.
- **iCloud Sync (if it ships in 1.0).** Saves, save states and settings go to the user's own private iCloud (CloudKit) container. The developer cannot read it and it does not pass through any developer server, so it is not "collected". The statement is correct whether or not Task 14 ships iCloud Sync.
- **Web UI, WebDAV and Nearby Devices.** Local-network transfers between the user's own devices. Nothing is sent to the developer.
- **Requests to public servers that the app makes on the user's behalf.** The developer receives nothing from these:
  - cheat codes from `codes.rc24.xyz` (fetched when the cheats pane opens; the game's GameTDB ID is the request key);
  - box art from GameTDB (a setting that is off by default);
  - the skin catalog from `provenance-emu.com` and `raw.githubusercontent.com` (iPhone and iPad);
  - the Dolphin blog feed from `dolphin-emu.org`;
  - WiiLink, only if the user turns on "Enable WiiConnect24 via WiiLink".

  These servers see an IP address and the request, as any web server does. They are public databases and services, not data partners of the developer.
- **Permissions.** Microphone (Wii microphone input), motion (headphone motion for spatial audio), local network (transfers, DSU controllers, nearby devices) and photo library add-only (saving replay clips). None of this leaves the device.

## OWNER: confirm before answering

1. **"Not linked to the user".** Sentry attaches a random per-install ID to events. It is app-scoped and generated by the SDK (not the IDFA or IDFV), and the app sets no user, email or account. That is the basis for "not linked". If you want the most conservative reading, you can add **Identifiers > Device ID** (App Functionality, not linked); I do not think the random install ID needs it, but it is your call.
2. **IP addresses.** Sentry's servers receive the sender's IP address in transit. In the Sentry project settings, turn on "Prevent Storing of IP Addresses" so the answer "not linked, no identifiers stored" stays true.
3. **Taps in breadcrumbs.** Sentry's default breadcrumbs include screen and UI interaction events (outside active emulation, where the touch-control selectors are filtered out), and release-health sessions are on by default. These support crash diagnosis. If you consider UI-event breadcrumbs "how the user interacts with the app", either also declare **Usage Data > Product Interaction** (App Functionality, not linked), or switch the user-interaction breadcrumbs off in the App Store build. I chose the diagnostics-only reading to match Task 5's manifest; this is the item most worth a second look.
4. **Purpose.** Declared as App Functionality (minimizing crashes and improving performance). If you also use the data for product analytics, Apple would require adding Analytics as a purpose.
5. **Third-party SDK manifest.** Run Xcode > Organizer > Generate Privacy Report on the archive and compare it with this page; Sentry ships its own privacy manifest, which the report merges.
6. **Keep three things in step.** If the declared types change, change them together in `PrivacyInfo.xcprivacy`, here, and `src/app/privacy/page.tsx` on the website.
