# tvOS UI release audit

A standalone XCTest UI runner for the installed `com.joemattiello.iCube-debug` app. It sends real `XCUIRemote` presses, asserts navigation/accessible names, tests CPU-engine persistence across relaunch, and retains screenshots and accessibility trees in the xcresult/log. It does not modify the app's Tuist target graph.

Build and install a current NJB Debug tvOS simulator app first. Use a **dedicated simulator**: the tests relaunch iCube with demo/preview arguments and change the CPU engine temporarily, restoring the original choice on the successful path. Interrupted/failed tests can leave test settings changed. They do not validate real emulation, save-state contents, production sync or APPSTORE feature visibility.

Requires Xcode and XcodeGen (`brew install xcodegen`). From the repository root:

```sh
Tools/tvos-ui-audit/run.sh <tvOS-simulator-UDID>
```

To run only navigation, omit the capture sweep with specific test selections:

```sh
Tools/tvos-ui-audit/run.sh <UDID> \
  -only-testing:ICubeTVAudit/TVSettingsAuditTests/testLibraryPlatformsAndContentFocus \
  -only-testing:ICubeTVAudit/TVSettingsAuditTests/testSettingsEntryPaneBackAndDismiss \
  -only-testing:ICubeTVAudit/TVSettingsAuditTests/testPerformanceCycleKeepsFocusAndMenuReturnsToSidebar
```

Generated projects and results go to a unique `/tmp/icube-tvos-audit.*` folder. Set `ICUBE_AUDIT_OUTPUT` to a fresh directory to retain them elsewhere. Export captures with `xcrun xcresulttool export attachments --path <results.xcresult> --output-path <captures>`. The leaf sweep confirms the selected entry and foreground state and captures each screen. Inspect the captures to validate the detail panes; their correctness and adjustment behavior are not established by that sweep. Achievements is build-conditional and is not claimed covered by the generic sweep.
