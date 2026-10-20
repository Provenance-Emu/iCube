# Startup metadata compatibility diagnosis — 2026-10-20

The four audited fatal Swift symbolic-reference groups (CB, GW, GJ, J2) resolve to the same missing runtime metadata symbol. This is a source-level older-OS compatibility defect in the shipped card's context-menu body, not four independent crashes.

## Evidence chain

- All four events' app image UUID is `CD1CFD46-9F1C-329E-BE9B-41B926D574C3`, matching `build/archives/iCube-ios-1792472425.xcarchive/dSYMs/iCube.app.dSYM`.
- After subtracting each event's ASLR image address and adding the linked image VM address, each crash's symbolic reference is `0x100a9df0f`.
- The signed 32-bit value at that location is `2299409` (`0x231611`), targeting `0x100ccf520`.
- `xcrun dyld_info -fixups` maps that exact GOT slot to the weak import `_$s7SwiftUI12TupleContentVMn`.
- The dSYM's encompassing typeref starts at `0x100a9db24`, immediately following the associated conformance `iCube.GameGridItem:SwiftUI.View.Body`. It contains `View.contextMenu(menuItems:)`, the production card, and the failing reference inside the unreachable fallback's tuple of four buttons.
- Current Xcode 27.1 SwiftUICore SDK declares `TupleContent` and its View conformance only for OS 26+. Both shipped apps' Info.plist and current Tuist deployment targets require OS 17.
- A standalone reproduction of the same nested Cheats menu availability check produces both the missing `buildLimitedAvailability` and OS-26-only `TupleContent:View` warnings. Removing the redundant availability wrapper and its unreachable older-OS fallback passes `swiftc -warnings-as-errors -typecheck` with an iOS 15 target, stricter than the app's iOS 17 deployment.

## Source change

`Source/iOS/App/Common/Swift/GameGridItem.swift` removes the redundant `if #available(tvOS 17.0, iOS 14.0, *)` wrapper and unreachable tvOS 16 fallback in both platform branches. Every supported OS already uses the nested Cheats menu; its action callbacks and labels are preserved. Removing the unreachable generic branch prevents its inferred future-only type from entering the card's associated body metadata.

## Regression checks

- `Source/iOS/App/Project/Scripts/check_swiftui_compatibility.py <app executable>` fails on BOTH shipped apps for the exact `TupleContentVMn` weak import. Run it on each new optimized archive before export/upload.
- `ICubeCardFocusTests.test_cardBodyMetadataDoesNotRequireOS26TupleContent` resolves the actual production `GameGridItem.Body` metadata and rejects any `TupleContent` component, catching the same type leak on a newer runtime before it crashes on an older one. This is added to an existing test file, so Tuist regeneration is unnecessary.
- Swift parsing and `git diff --check` pass for the changed source/test. Localized-key coverage passes.
- The separate modal action header now uses existing design tokens; the global design-token ratchet passes without raising its baseline.

## Pending acceptance

The integrated iOS Debug SDK build passes, and both its app executable and debug library pass the binary guard. No app/core build or hosted XCTest run was started by the startup investigator. The root agent owns serial SDK builds and must execute the hosted regression, run the binary guard on both new optimized archives, and validate app launches. The source diagnosis and Debug checks do not establish that a complete replacement candidate has shipped. No Sentry issues were resolved.

The adjacent mapping JSON and logs contain sanitized symbols and compiler evidence. Original private events stay gitignored and are not copied here.
