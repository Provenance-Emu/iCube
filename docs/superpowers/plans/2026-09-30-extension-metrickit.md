# Plan: MetricKit (and crash/perf data) for iCube's app extensions — 2026-09-30

Request (user): "while on MetricKit, make sure extensions record important data there too."
Written at the end of a long session; start a fresh session from this file.

## Current state (verified 2026-09-30)

- Extensions (Tuist `Source/iOS/App/Project.swift`): `LiveActivityExtension` (iOS/iPad/Catalyst,
  ~line 448), a factory-built app extension (~line 558 — name it), `iCubeTopShelf` (tvOS, ~602),
  `iCubeQuickLookPreview` (iOS, ~628).
- None of them uses MetricKit, os_signpost, or Sentry. The only MetricKit hookup is in the main
  app: `options.enableMetricKit = true` in `SentryTelemetryService.configure()` (~line 165).
- That hookup is currently crashing: Sentry ICUBE-A6, `-[SentryEvent isMetricKitEvent]:
  unrecognized selector` from `SentryMXManager.captureEvent` (sentry-cocoa 9.27.0, build
  1790351911). Reported to the "Watchdog memory exhaustion in iCube" session, which owns
  `SentryTelemetryService`. Coordinate before touching it.

## Answers (researched 2026-09-30, second session)

1. **Extensions can't subscribe.** Apple DTS (forums 652719, 709546): a MetricKit subscriber in an
   extension is "not a supported workflow" and doesn't receive payloads, even simulated ones. The
   host app's subscriber is the supported path. `MXMetaData.pid` (iOS 17) and
   `MXMetaData.bundleIdentifier` (iOS 26) identify the process, but Apple doesn't say whether
   QL / widget / Top Shelf payloads reach the app.
2. **No MetricKit on tvOS** (framework lists iOS, iPadOS, Catalyst, macOS 12, visionOS). Sentry's
   MetricKit integration is compiled out on tvOS too. Top Shelf = unified log only.
3. **Custom signposts** (`mxSignpost` on a `makeLogHandle` log) land in `MXMetricPayload.signpostMetrics`.
   The count is capped (no number given), and extension attribution is undocumented. iOS 27
   deprecates `MXMetricManager` for `MetricManager` (AsyncSequence reports, StateReporting).
4. **Sentry in extensions: not now.** Widgets ~30 MB, QL preview ~100 MB, Top Shelf maybe 10–16 MB
   (none official). Sentry auto-disables hang tracking only for widget/intent/share-style
   extensions, not QL or Top Shelf.
5. **Nobody reads `signpostMetrics` today.** sentry-cocoa's `SentryMXManager` implements only
   `didReceive(_: [MXDiagnosticPayload])` (cpuException, diskWriteException, hang). The app has no
   subscriber of its own.

## Done (2026-09-30)

- `LibrarySnapshotStore.loadWithOutcome()` + `LibrarySnapshotLoadOutcome` (loaded / neverWritten /
  appGroupUnavailable / decodeFailed / newerSchema(v)); `load()` unchanged. Commit 681fdd1b38.
- `PVLibrarySnapshot/ExtensionTelemetry.swift`: one signpost interval per extension
  (ThumbnailLookup, PreviewBuild, TopShelfBuild, WidgetEntry), events SnapshotNoAppGroup /
  SnapshotDecodeFailed / SnapshotNewerSchema / CoverUnreadable, category "Extensions". Failures logged
  at `.error`, timing at `.notice` (subsystem com.joemattiello.iCube, category = surface).
  `mxSignpost` where MetricKit exists, `os_signpost` on tvOS. `LibraryLookup.resolveWithOutcome`.
- Wired into Thumbnail, Preview (also records an unreadable cover instead of silently falling back),
  Top Shelf (summary log moved .info → .notice so it persists), RecentGamesWidget. The widget ships
  nothing while `APP_EMBEDS_APPEX = false`.

## App-side reader (decided 2026-09-30: option a)

- `ExtensionMetricsReport` (PVLibrarySnapshot): pure summary of one payload's "Extensions" signposts
  (failure counts, interval count / approx mean / max from the histogram), `decision()` = always send
  failures, sample timing-only payloads at 10 %, stable fingerprint per failure combination.
  `ExtensionSignpostSample.init(MXSignpostMetric)` is the only MetricKit-typed code.
- `App/Common/Services/ExtensionMetricsReporter.swift`: its own `MXMetricManagerSubscriber`, started
  from AppDelegate after `SentryTelemetryService.configure()`. Independent of Sentry's
  `enableMetricKit` (ICUBE-A6 session may change that). Sends `SentrySDK.capture(message:)`
  "App extension failures" (warning) / "App extension timing" (info) with contexts `app_extensions`
  and `metrickit_payload` (window, app version, pid, iOS 26 `bundle_id` — tells us whether extension
  signposts are attributed to the app at all). Also listed in the fallback DolphiniOS.xcodeproj.
- Verify: Xcode → Debug → Simulate MetricKit Payloads exercises the subscriber path (simulated payloads
  carry Apple's sample signposts, not ours, so expect `.skip`); the real check is a Sentry event
  after ~24 h of using Files previews on a device.

## Device check still owed

`log stream --device --predicate 'subsystem == "com.joemattiello.iCube" AND category IN {"thumbnail","preview","topshelf","widget"}'`
while browsing a disc image in Files (thumbnail + preview) and opening Top Shelf on tvOS. MetricKit
attribution can't be verified in-session (24 h payload delay).

## Original questions (kept for context)

1. Does `MXMetricManager` deliver metric/diagnostic payloads to a subscriber running in an app
   extension process, or are extension metrics only rolled into the containing app's payloads?
2. Is MetricKit available on tvOS at all? (If not, Top Shelf needs a different path, e.g. Sentry
   or os_log only.)
3. Do `mxSignpost` / `MXMetricManager.makeLogHandle(category:)` custom signposts emitted from an
   extension show up in MetricKit payloads (signpostMetrics), and under which process?
4. Sentry in extensions: is it worth starting the SDK in short-lived extensions (Quick Look,
   Top Shelf, Live Activity) given memory limits (widget/Live Activity ~30 MB)? Which DSN /
   environment / release naming so extension events are distinguishable?

## Proposed "important data" per extension

- **Quick Look preview** — time to produce a preview (disc header parse + cover load), failures
  by reason (unreadable image, unsupported format), memory high-water mark.
- **Top Shelf** — time to build the shelf content from the App Group library snapshot, item
  count, snapshot-read failures.
- **Live Activity / widget** — snapshot read latency, update/render failures, memory.
- All — crash and hang diagnostics (MXCrashDiagnostic / MXHangDiagnostic) if delivered there.

## Approach (pending the answers above)

1. Shared, tiny `ExtensionTelemetry` helper (one file, compiled into each extension target):
   a `MXMetricManager.makeLogHandle(category:)` handle + `mxSignpost` intervals for the operations
   above; no-op where MetricKit is unavailable (`#if canImport(MetricKit)` / tvOS guard).
2. If extensions receive their own payloads: subscribe in each extension's principal class and
   forward to Sentry (if the SDK runs there) or write to the App Group for the app to upload.
3. If payloads only reach the app: rely on the app's existing subscriber (Sentry enableMetricKit,
   once ICUBE-A6 is fixed) and make sure the signpost categories are distinctive per extension.
4. Unit-test the helper's interval bookkeeping; device-verify by running each extension and
   waiting for the next daily payload (MetricKit is ~24 h delayed; Xcode "Simulate MetricKit
   Payloads" for the subscriber path).

## Constraints

- Shared checkout with other sessions: stage only your own files; check `git branch
  --show-current` before editing (the iCube submodule sometimes gets detached at Provenance's
  pointer by other agents).
- Tuist: new extension sources need `tuist generate --no-open`; extensions use
  GENERATE_INFOPLIST_FILE (see memory "Top Shelf / Quick Look extensions").
- Gates: `make test` (wrap in `timeout`), `make gate-release` (iOS + tvOS Release).
