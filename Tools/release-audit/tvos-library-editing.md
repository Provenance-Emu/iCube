# Rendered tvOS library editing audit

This XCTest source compiles and has been exercised against the integrated tvOS app. See [dated SDK evidence](../../docs/app-store/release-evidence/2026-10-20-library-sdk-verification.md) for individual case results and remaining gates. Earlier rendered runs exposed a real tvOS long-select selection side effect and several harness assumptions: native context-menu actions are cells/other elements, the focused library card reports focus on its subtitle, and offscreen preview screenshots are clipped. Selection, title/tag persistence, Back navigation and cover set/reopen/clear have independent passing results; report other cases only after checking their result bundle. Use the separately installed current tvOS app and external `ICubeTVAudit` UI-testing target; this harness change does not modify production code.

## Library-only fixture

`UICommon::GameFile` first attempts volume detection, then marks a file valid when `IsElfOrDol()` matches the lowercase `.elf` or `.dol` extension (`Source/Core/UICommon/GameFile.cpp:144,346`). It does not inspect a DOL/ELF executable header on this path. A 64-byte text marker with a `.dol` suffix therefore exercises a real local `GameFile`, content-derived metadata identity, and editor availability without requiring copyrighted game content or executable homebrew.

Generate inputs in a scratch directory:

```sh
python3 Tools/release-audit/prepare_library_editing_fixture.py --output /tmp/icube-library-edit-fixtures
```

The script emits byte counts and SHA-256 values and creates `ICube Library Edit Audit NEVER LAUNCH.dol` plus a 32×32 PNG. It does not install them anywhere. **Never launch this tile**: it is intentionally invalid executable content. Avoid Play/Pause and short Select on the library tile; the test only long-selects it to request its context menu. If long-select enters selection mode instead, the test fails at editor entry and records the tree/screenshot. Do not work around that failure by booting the file.

Use a dedicated, already bootstrapped simulator/application container with no personal games or metadata. While the app is terminated, copy **only** the `.dol` marker into the container's `Library/Caches/Software/` folder (`UserFolderUtil.getSoftwareFolder()` uses the tvOS caches root). Start normally so `GameFileCacheManager` scans it. Verify exactly one real tile appears as `ICube Library Edit Audit NEVER LAUNCH.dol` (the homebrew title includes the extension). The suite passes `-SCREENSHOT_MODE 0`; synthetic demo items intentionally exclude editing. Clear only this disposable fixture's prior metadata through the editor (blank title/tags, Use Original Cover, Save) before a run. Setup also resets the known `Audit Custom Title` left by a failed prior run through the real editor. The tests expect an otherwise clean baseline and restore it after successful Save paths; a failed run may leave test edits, so reset the disposable fixture before retrying.

## External harness

Durable test source: `Tools/release-audit/TVLibraryEditingAuditTests.swift`.

The current working copy is at `build/release-audit/2026-10-20-library/harness/Tests/TVLibraryEditingAuditTests.swift`; copy the durable source there before each harness build. The older `/tmp` harness is no longer retained. Existing `project.yml` includes all `Tests/` sources. Regenerate that **external harness** before its next SDK build so its generated project includes the new file; no app Tuist generation is needed for these test sources. The UI test launches `com.joemattiello.iCube-debug` in English. Use an installed build containing the actual metadata editor and explicit tile redraw epoch.

For the URL-cover case, run the scratch fixture server in another terminal:

```sh
python3 Tools/release-audit/prepare_library_editing_fixture.py --output /tmp/icube-library-edit-fixtures --serve
```

It binds `127.0.0.1:8765` only. Simulator loopback reaches the host. A physical Apple TV requires an explicitly reachable fixture host and HTTP transport permission; this loopback recipe targets the simulator. The test defaults to that URL; `ICUBE_AUDIT_COVER_BASE_URL` can be set in the UI-test target's test environment for another host. `/oversized.png` advertises 12MiB+1; `/oversized-stream.png` omits Content-Length for a separate streaming-cap check. The server streams oversized bytes without allocating that entire body. It exposes no arbitrary local files.

Run the `ICubeTVAudit` scheme against the chosen tvOS simulator with only `TVLibraryEditingAuditTests` selected. Enable XCTest timeouts in the scheme or pass `-test-timeouts-enabled YES -maximum-test-execution-time-allowance 180`. Each case sets `executionTimeAllowance = 180` and helpers stop issuing actions after 165 seconds. The runner timeout is essential to interrupt a single stuck synchronous XCTest text-entry call; a helper deadline alone cannot interrupt that call. Generating fixture inputs alone performs no simulator install or app launch. The XCTest command operates the dedicated installed app.

## Assertions and evidence

- Title/tags: Save changes the rendered tile; reopening and relaunch retain values. Editing a second draft then Cancel preserves the saved values.
- Back: discard an unsaved draft, return focus to the invoking tile, and reopen without the draft.
- Cover: URL artwork must render the fixture's magenta/black signature (over 30% magenta pixels), Save/reopen retains it, and clearing removes that signature and matches the original preview through Save/reopen. An independent case checks oversized input displays an error without changing the draft, then Cancels. Saved and cleared tile screenshots are attached; the card also has independent magenta-signature assertions so editor persistence cannot hide a library rendering defect.
- Focus: waits for the invoking tile's actual accessibility focus after each dismissal; existence alone does not pass. Keyboard dismissal must leave the editor open.
- Selection: real native context-menu cells expose Edit/Select Games. Opening a menu must not select; choosing Select Games selects once, and short Select is used only after selection mode is proven, to deselect without launching.

Keyboard completion is gated on two consecutive predicate samples with no keyboard/key accessibility nodes, a restored focused field/native focus owner, a still-present editor, and the exact intended field value. If native keyboard AX nodes were never observed, a diagnostic is attached so that uncertainty is visible; field focus and repeated absence remain required. Existence of the underlying Save button alone is insufficient. Replacement deletes the bounded raw field-value length plus one: a persisted custom title can equal its placeholder, so treating that value as empty before deletion would append the new draft to it. Text lengths are bounded for this fixture.

Focus navigation follows the actual target/current frames and stops after 16 presses or 12 seconds, instead of searching 80 presses in both directions. Missing/phantom focus targets fail with evidence. For preview sampling, the image's containing native cell must be focused and its entire image rect must lie inside the table/app viewport below the navigation bar, with a stable rect across repeated samples. Original/cleared comparisons use normalized 32×32 RGB pixels and a mean rounding allowance of 6/255 per channel, together with an independent rejection of the magenta fixture signature. Clipped/offscreen images cannot pass. Failure to focus/fully expose a nonfocusable image cell is a harness gate to resolve from captured UI evidence, not a reason to weaken visibility checks.

Every diagnostic records the accessibility tree and screenshot. Review saved/cleared grid tile screenshots as well as editor preview assertions; the card-level signature assertions complement the editor pixel checks. The bounded keyboard/focus checks and fully visible preview sampling have now run against the SDK build. The tvOS preview is explicitly focusable so the remote can reach and scroll the full artwork into view. Report failures as gates and refine only from captured UI evidence. Native store/service tests establish persistence and bounds separately; they do not substitute for these rendered checks.
