# iCube Sentry crash audit — October 20, 2026

Current TestFlight build `1792472425` is affected by a release blocker. A fresh Sentry Discover query scoped to project `icube`, release `com.joemattiello.iCube@1.0.0+1792472425`, `level:fatal`, 14-day lookback returns **75 fatal reports across 11 distinct Sentry users**. The release first reported events on October 20. Per-group users overlap and must not be summed.

| Group | Reports on this build | Sentry users | Finding |
|---|---:|---:|---|
| [ICUBE-CB](https://provenance-emu.sentry.io/issues/7765730589/) | 44 | 6 | Swift symbolic-reference lookup failure / stack overflow |
| [ICUBE-GJ](https://provenance-emu.sentry.io/issues/7796858788/) | 16 | 1 | Same signature |
| [ICUBE-J2](https://provenance-emu.sentry.io/issues/7802667311/) | 10 | 2 | Same signature |
| [ICUBE-GW](https://provenance-emu.sentry.io/issues/7797457355/) | 4 | 1 | Same signature |
| [ICUBE-2D](https://provenance-emu.sentry.io/issues/7650903385/) | 1 | 1 | Fatal main-thread hang; inspected event on iOS 26.7.1 |

The four runtime groups total **74 reports** and share symbolic-reference offset `2299409`. Inspected latest events identify TestFlight (`build_type: test`, distribution `1792472425`, environment `appstore`) on iOS **17.6, 17.6.1, 18.0 and 18.7.8**, about one second after launch. Stacks include SwiftUI layout and Swift associated-type metadata resolution. These appear to be multiple groups for one underlying compatibility failure, rather than four independently established root causes.

**Investigation lead, not a confirmed source fix:** current iOS SDK build logs also warn that `TupleContent<repeat each Content>` conformance is only available in iOS 26 or newer. Map the failing symbolic reference in the shipped archive/dSYM and inspect older-OS SwiftUI availability before the next candidate. Passing newer-OS simulator tests does not establish iOS 17/18 startup compatibility. The exact source expression is not yet proven.

## Separate sideload blocker

[ICUBE-HY](https://provenance-emu.sentry.io/issues/7801950034/) reports **101 events / 14 Sentry users**, first seen October 20. All 101 events are tagged `sideload`; release tag distribution is builds 344–363, including modified bundle identifiers. The inspected stack is `CloudSyncCoordinator.start` → `CloudKitSyncProvider.init` → `CloudKitAvailability.makeContainer` → `CKContainer`. Treat this as the sideload CloudKit availability/entitlement failure; do not attribute it to the current TestFlight candidate without matching release evidence. A separate custom-bundle tvOS development event [ICUBE-J0](https://provenance-emu.sentry.io/issues/7802485445/) lacks required app debug symbols, limiting its diagnosis.

Older builds also have watchdog/mutex failures, and the project contains many MetricKit CPU/disk warnings. Their lifetime group counts were not added to the current build's fatal count. No Sentry issue was resolved or ignored during this read-only audit. Raw API payloads remain in gitignored local audit storage; this document omits installation identifiers and personal data.
