# iCube local DEV loop

Standard-library Python CLI for incremental Debug builds, recorded DEV installs,
reusable native XCTest runners and RocketSim captures. It never cleans caches,
uninstalls apps, rebuilds the C++ core, or launches the production bundle.
Run from any directory; `cd Source/iOS/App && make fast ARGS='…'` also works.

Register your own explicit destinations (no personal UDIDs are embedded):

```sh
python3 Tools/dev-loop/icube.py target add phone --platform ios --kind simulator --udid YOUR_SIMULATOR_UDID
python3 Tools/dev-loop/icube.py target add tv --platform tvos --kind simulator --udid YOUR_TV_SIMULATOR_UDID
python3 Tools/dev-loop/icube.py target list
```

First adopt a locally validated core candidate. This checks both platforms' archive
and IPA acceptance, accepted/current Git core trees, dirty/untracked core inputs,
submodules, all packaged binary hashes and the framework aliases consumed by the
app build. Every fast app build repeats freshness checks and refuses stale cores.

```sh
python3 Tools/dev-loop/icube.py prepare --core-baseline build/release-audit/2026-10-21-tvos-settings/candidate-manifest.json
python3 Tools/dev-loop/icube.py build --target phone
python3 Tools/dev-loop/icube.py install --target phone
python3 Tools/dev-loop/icube.py launch --target phone
```

When core development is in progress, an explicitly pinned accepted engine can be
used for UI-only iteration:

```sh
python3 Tools/dev-loop/icube.py prepare --core-baseline build/release-audit/2026-10-21-tvos-settings/candidate-manifest.json --pin-core
```

To pin only the accepted engine slice for a registered destination, add its target:

```sh
python3 Tools/dev-loop/icube.py prepare --target tv --core-baseline build/release-audit/2026-10-21-tvos-settings/candidate-manifest.json --pin-core
```

Target-scoped adoption still requires both platforms' accepted archive/IPA
provenance, but validates only the selected platform/kind binary and its consumed
framework alias. The saved scope is enforced on build/install/test; an iOS or
device target cannot reuse a tvOS simulator pin. Explicit `--existing-dev`
launch/test runs may target an unrelated existing DEV installation: they skip
configured pin validation, record that it is inapplicable/unvalidated, and claim
no installed app or engine freshness. Without `--target`, all accepted
artifacts remain mandatory. Baseline-only preparation stops after adoption;
include `--suite` explicitly to also prepare a runner. No binary is replaced.

This persists `policy=pinned-accepted-engine`; it permits differing or dirty core
source while preserving the accepted commit/tree and requiring every accepted
raw binary and consumed framework alias to keep its exact hash. A rebuilt or
changed framework still fails. Build/install/test print the accepted engine,
pending core paths and exclusions, and record them in `timings.json`. Verified
results are labeled `current-app/pinned-engine`: they exercise current app code
against the accepted engine and **exclude pending core changes from acceptance**.
No work in progress is restored, staged or rebuilt. This mode does not establish
that new core code compiles or behaves correctly. App fingerprints exclude
`Source/iOS/Library` engine sources, which are governed by the explicit core
policy instead. Re-adopt without `--pin-core` to return to strict freshness; that
will reject pending core changes until a matching accepted core exists.

Build uses Debug (Non-Jailbroken), existing `build-Xcode-ios` / `build-Xcode-tvos`
simulator caches, and separate `build-Xcode-ios-device` / `build-Xcode-tvos-device`
device caches. It reuses the existing library-audit package checkout directory
when present. No automatic package updates or per-run dependency checkout is
requested. Core reuse requires the accepted baseline. Sentry upload is skipped
through `ICUBE_FAST_DEV=1`; localization regeneration runs normally on the first
build, then can be skipped only while all localization inputs still match the
postbuild digest of that successful normal run. App source/build settings, PO/localization inputs, core, Xcode, generated project
and product hashes guard whole-app cache hits. Audit sources and tool/docs edits
do not stale the app. A changed Tuist manifest/configuration, source/resource path
list or generated project triggers Tuist generation before building; ordinary
existing Swift content edits keep the generated graph. App/bridge/build inputs
are hashed before and after xcodebuild; concurrent Swift/ObjC/PO/input edits reject
cache acceptance and require a rerun. Only `.strings` outputs may change during
a normal localization pass; skipped-localization builds require all inputs stable. Simulator products receive
ad hoc signing during the build, including embedded frameworks.

For physical destinations, register `--kind device`. Build and prepare use generic
destinations without hardware control and require `--team YOUR_DEVELOPMENT_TEAM`.
Install, launch and test additionally require `--allow-device-control`. There is
no provisioning update flag and no automatic app/data removal. Existing app data
is preserved by normal DEV bundle installation. Tests may exercise mutations
explicitly described by their suite; use disposable DEV fixtures for those tests.

Prepare once, then rerun tests directly from `.xctestrun`, without a workspace or
package graph resolution in the test invocation. The runner selector matches the
active target SDK version (`xcrun --sdk … --show-sdk-version`, cached per process),
so products from older installed Xcodes may coexist:

```sh
python3 Tools/dev-loop/icube.py prepare --target phone --suite unit
python3 Tools/dev-loop/icube.py test --target phone --suite unit --only SomeTests/testExample
python3 Tools/dev-loop/icube.py prepare --target tv --suite settings
python3 Tools/dev-loop/icube.py test --target tv --suite settings --only TVSettingsInteractionAuditTests/testChoiceLeftReturnsCategoryWithoutMutating
```

`--only CLASS/METHOD` may repeat. A suite-wide run requires explicit `--all`.
A current install record is required. Simulator runs compare the actual installed
DEV container against normalized relative-path/content hashes of the recorded
app, detecting replacement by another tool. `--existing-dev` explicitly accepts an
unverified existing DEV installation and records that limitation. Physical
launch/test always require `--existing-dev` because this CLI cannot verify the
installed device payload; `--allow-device-control` remains independently required. The app under
test is always `com.joemattiello.iCube-debug`. Device runner preparation and reruns
must use the same `--team` so their cache key matches. iOS app builds include unit
products; unit preparation will reuse verified products. UI preparation builds
only the small standalone harness and never installs the app under test.

UI suites: `settings` and `library` (tvOS), `pause-exit` (iOS), `portrait` (iOS
simulator), `physical-play` (iOS device), and `actions` (both platforms). Suite
sources live in `Tools/release-audit/`, except `FastInteractionTests.swift` here.
Harnesses are keyed by every source digest, Xcode/developer directory, active SDK
path/version, platform, simulator/device, project spec and signing/build flags.
The actions harness copies and hashes both `FastInteractionTests.swift` and its
shared `FastInteractionSchema.swift`.
The physical play suite retains its separate operator preflights, passed explicitly
as `--env ICUBE_PLAY_CONTROLS_PREFLIGHT=enabled` and
`--env ICUBE_PLAY_CONTROLS_WIDE_PREFLIGHT=enabled`; read its source before use.

```sh
python3 Tools/dev-loop/icube.py prepare --target phone --suite actions
python3 Tools/dev-loop/icube.py test --target phone --suite actions --only FastInteractionTests/testActions --actions /absolute/path/actions.json
python3 Tools/dev-loop/icube.py capture --target phone
python3 Tools/dev-loop/icube.py inspect --target phone
```

Actions JSON is injected into a copy of the cached `.xctestrun` as
`ICUBE_UI_ACTIONS`. Physical runs additionally inject `ICUBE_ALLOW_DEVICE_CONTROL=1`.
The root-owned native harness validates all actions before operating the app. Its
array entries use `op`: `launch` (arguments), `activate`, `capture` (name, optional
ax), `remote` (button, optional duration), `tap` (identifier/label, optional type),
`type` (identifier/label, text, optional clear/type), or `assert` (identifier/label,
optional type/exists/enabled/focused/value/valueContains/timeout).
The copied plist stays beside its original to preserve XCTest relative paths and
is removed after the run. See `FastInteractionTests.swift` for the action schema.

Capture/inspect require an already running simulator and RocketSim CLI. They do
not open or quit either app. Capture writes PNG plus AX JSON; inspect writes AX
JSON. Both surface RocketSim's live preview URL. Every JSON operation checks
`rs/1` and `ok`; quota/error responses terminate the operation, with no simctl
capture fallback or allowance bypass. Raw screenshot stderr is also checked for
rs/1 errors before accepting PNG bytes.

Build/prepare/control commands use a nonblocking `build/dev-loop/sdk.lock`; a
busy lane gives a friendly error and does not queue. Capture/inspect use a shared
`ui.lock`, so they can inspect during compilation but cannot overlap test, install
or launch control mutations. Tests export `summary.json` through active Xcode
`xcresulttool`, record passed/failed/skipped counts and reject zero-test selections
even if xcodebuild exits zero. All-skipped runs have status `skipped`, never passed. Target registry,
baseline, install/cache records, runners and per-phase command/log/timing/result
evidence live under ignored `build/dev-loop/`. Timings use monotonic wall time;
a top-level `elapsed_seconds` also measures the complete recorded run, including
cache hits with no subprocess phases. Source/product fingerprints distinguish
verified current installs from explicitly
unverified existing ones. This lock coordinates this CLI; other SDK users must
honor the repository's shared build lane separately.

Pure Python checks (no Xcode or device commands):

```sh
python3 -m unittest discover -s Tools/dev-loop -p test_icube.py
```

SDK execution and device acceptance are separate from these unit checks.
