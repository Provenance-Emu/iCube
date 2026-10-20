# Rendered iOS pause Exit regression

`IOSPauseExitAuditTests.swift` is an external XCTest UI harness against an installed
Debug app, bundle ID `com.joemattiello.iCube-debug`. It opens the synthetic pause
preview with `-ICubePausePreview -ICubePausePane exit`. It never activates Quit or
Save & Quit, and does not need a ROM.

The two cases cover portrait and landscape. Each requires Exit Game and the Cancel,
Quit and Save & Quit buttons to exist, be hittable, have noncollapsed bounds and fit
within the application viewport. Cancel must dismiss the prompt and restore a
tappable `pause.tile.exit`; tapping Exit must reopen a complete prompt. Screenshots
and accessibility trees are attached to the result bundle before the assertions.

Generate an XcodeGen `bundle.ui-testing` target for iOS 17+, using the source above,
`GENERATE_INFOPLIST_FILE: YES` and `CODE_SIGNING_REQUIRED: NO`. The 2026-10-20
generated project and results live under
`build/release-audit/2026-10-20-pause-exit/` (not committed).

Example invocation from the repository root:

```sh
xcodebuild \
  -project build/release-audit/2026-10-20-pause-exit/harness/ICubeIOSPauseAudit.xcodeproj \
  -scheme ICubeIOSPauseAudit \
  -destination 'platform=iOS Simulator,id=7A16AA83-4C92-4C7D-841C-A0AD3ACF27DC' \
  -derivedDataPath build/release-audit/2026-10-20-pause-exit/derived \
  -resultBundlePath build/release-audit/2026-10-20-pause-exit/ipad-fixed.xcresult \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

Use only a dedicated audit simulator. The original iPad is `PauseTiles-iPad`
(`7A16AA83-4C92-4C7D-841C-A0AD3ACF27DC`, iOS 26.5). Repeat on a dedicated phone
when available; leave other users' booted simulators alone.
