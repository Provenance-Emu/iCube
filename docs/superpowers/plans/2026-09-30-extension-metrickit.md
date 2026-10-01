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

## Questions to settle first (Apple docs, not memory)

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
