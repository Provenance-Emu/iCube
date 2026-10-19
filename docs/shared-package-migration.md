# Shared Swift packages — 2026-10-19

The app consumes PVWebServer, PVContinuity, PVSyncRules, PVCloudSync, PVHelp and
PVLibrarySnapshot from their Provenance-Emu GitHub repositories using 1.x version
requirements. Change generic behavior in those repositories, run their tests, tag
a release, then resolve the app packages. The deleted Source/iOS copies are no
longer the place to edit shared code.

PLzmaShim deliberately remains a small, self-contained local package. It permits
the revision-pinned PLzmaSDK dependency's unsafe build flags; moving that wrapper
behind another remote package boundary would defeat the workaround.

## App-owned configuration and resources

- `App/Common/Services/ICubeCloudSync.swift` supplies the **existing** private
  CloudKit container, zone and record type. Do not change those identifiers during
  a package update: existing user data lives under them.
- `App/Common/Swift/Help/ICubeWiki.swift` supplies the wiki URLs, cache namespace,
  page paths and bundled-content location. `App/Common/Resources/WikiContent` is
  copied as a folder so the help hierarchy stays usable offline.
- `App/Shared/Snapshot` contains the App Group/deep-link configuration and iCube's
  platform, disc-header and lookup adapters. These sources compile into the app,
  Live Activity/widget, Top Shelf, thumbnail and Quick Look targets. They use
  Foundation plus the shared snapshot package, without linking the Dolphin core.
  `SnapshotDiscContainer` is deliberately distinct from the patch planner's
  `DiscContainer` type.

The App Group remains `group.com.joemattiello.icube`, links remain
`dolphinios://play?id=…`, and snapshot platform JSON remains a string such as
`"gamecube"`. `ICubeSnapshot` bridges the shared String field to iCube's enum.
The relocated DiscHeaderReader and LibraryLookup XCTest suites live in
`App/DolphiniOSTests`; SharedPackageMigrationTests covers old snapshot JSON and
bundled help when the remote is unavailable.

## Separate consumers

PVContinuity preserves the existing iCube discovery and transfer protocol. It is
not interchangeable with iFly's ContinuityKit package. Provenance's older
PVWebServer exposes different ObjC and Hummingbird products; that consumer needs
its own API migration before depending on the new server package.

## Migration validation

- Tuist generation/package resolution and iOS/tvOS device compiles succeeded with
  `DOL_SKIP_CORE_BUILD=1` and the existing core framework.
- Explicit Live Activity, thumbnail and Quick Look builds pass; Top Shelf also
  compiles in the tvOS app build.
- The moved disc/lookup helpers plus legacy snapshot/offline-help regressions
  passed 24 host XCTest tests against the published packages. The host harness
  uses its SwiftPM resource bundle; the app's copied WikiContent hierarchy was
  separately verified in the built iOS app, with all nine original files retained.
- The actual iOS simulator test bundle compiles, but app-hosted execution did not
  reach tests on this machine. The first unsigned run hit MoltenVK's unsigned
  library check; ad-hoc signing removed that error. Subsequent launch attempts
  stalled while Xcode reported invalidDigitCount for installed 27.x runtime build
  identifiers, including during a retry targeting a dedicated 26.5 device. Those
  runs were stopped and are not recorded as passing tests.
- Button type drift checks pass. Localization and design-token checks produce
  byte-identical diagnostics on the migration and the unchanged develop checkout
  (existing missing localization keys and PauseCardFace token violations).
