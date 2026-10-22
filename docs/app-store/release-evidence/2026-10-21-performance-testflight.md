# Performance/locale TestFlight delivery — October 21, 2026

Source: `3ddef3d7bdea736f3da2b7bfd6e5ef2bc9adb292`.
[Hosted run 39711927274](https://github.com/Provenance-Emu/iCube/actions/runs/39711927274).
This candidate includes the approved Performance and quick-state work and locale defaults;
it excludes subsequent shared-metadata implementation and concurrent uncommitted UI/audio work.

| Platform | Version/build | App Store Connect build ID | Upload job |
|---|---|---|---|
| iOS | 1.0.0 / **1792639845** | `44ac8df4-01a6-4322-ac64-988b550c163a` | `119605268466` |
| tvOS | 1.0.0 / **1792640361** | `9a757f60-62b2-42b4-a069-df5285c83bb0` | `119605268783` |

Direct job logs prove successful uploads at 03:39:32Z and 03:45:52Z October 22 UTC,
respectively. Both archive/upload, Sentry and distribution steps passed. Root read-only
ASC reconciliation after both distribution steps confirms each exact platform/build:
VALID, not expired, beta review APPROVED, internal and external IN_BETA_TESTING,
autoNotifyEnabled true, and membership in Friends and Family, Internal, Moderators,
Patrons and Public Website. App ID `6752685822`, bundle `com.joemattiello.iCube`.
[TestFlight invitation](https://testflight.apple.com/join/9ZEfnyMP).

## Symbol evidence and limits

| Platform | App UUID | Embedded core UUID | Sentry result |
|---|---|---|---|
| iOS | `64b2dbef-bcac-3944-ada7-f17e9b823b6c` | `16d893a4-0beb-3efb-93b5-c1b45c70ec70` | Found 7, uploaded 14 debug/source objects |
| tvOS | `baf5f1cc-b9d9-3410-aae6-9dbcab095755` | `7fb5c54d-7b7f-3f08-946a-ed777a022f2f` | Found 6, uploaded 12 debug/source objects |

Sentry logs explicitly contain these app/core debug and source UUID uploads. Apple
also warned that the prebuilt core dSYM was absent from each archive; tvOS additionally
warned about Sentry.framework UUID `b23d3475-2819-3b98-9377-206109f165d3`.
These warnings did not prevent processing or distribution. Matching core symbols were
uploaded separately to Sentry; this evidence does not establish Apple crash-log
symbolication for those frameworks. Archive dSYM packaging remains follow-up work.
No final IPA/entitlement artifact inspection is claimed by these hosted log checks.

The current run used the older workflow building four core slices in each platform
job. The future selected-device optimization at `24ce80dd78` was not exercised here;
no speedup measurement is claimed. Physical iPad/Apple TV automation remains deferred
by the owner. Installed UI, real-game performance and cross-app/Production CloudKit
acceptance remain separate release gates.

Ignored local evidence: `build/release-audit/2026-10-21-performance-distribution/`
contains exact ASC readback, candidate JSON and direct platform job logs. Credentials
remain outside the evidence and were never printed or committed.
