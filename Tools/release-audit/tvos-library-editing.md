# Rendered tvOS library editing audit

These XCTest sources are prepared, **not compiled or run**. They make no acceptance claim. Use the separately installed current tvOS app and the external `ICubeTVAudit` UI-testing target; production code and generated application projects are unchanged.

## Library-only fixture

`UICommon::GameFile` first attempts volume detection, then marks a file valid when `IsElfOrDol()` matches the lowercase `.elf` or `.dol` extension (`Source/Core/UICommon/GameFile.cpp:144,346`). It does not inspect a DOL/ELF executable header on this path. A 64-byte text marker with a `.dol` suffix therefore exercises a real local `GameFile`, content-derived metadata identity, and editor availability without requiring copyrighted game content or executable homebrew.

Generate inputs in a scratch directory:

```sh
python3 Tools/release-audit/prepare_library_editing_fixture.py --output /tmp/icube-library-edit-fixtures
```

The script emits byte counts and SHA-256 values and creates `ICube Library Edit Audit NEVER LAUNCH.dol` plus a 32×32 PNG. It does not install them anywhere. **Never launch this tile**: it is intentionally invalid executable content. Avoid Play/Pause and short Select on the library tile; the test only long-selects it to request its context menu. If long-select enters selection mode instead, the test fails at editor entry and records the tree/screenshot. Do not work around that failure by booting the file.

Use a dedicated, already bootstrapped simulator/application container with no personal games or metadata. While the app is terminated, copy **only** the `.dol` marker into the container's `Library/Caches/Software/` folder (`UserFolderUtil.getSoftwareFolder()` uses the tvOS caches root). Start normally so `GameFileCacheManager` scans it. Verify exactly one real tile appears with the filename stem above. The suite passes `-SCREENSHOT_MODE 0`; synthetic demo items intentionally exclude editing. Clear only this disposable fixture's prior metadata through the editor (blank title/tags, Use Original Cover, Save) before a run. The tests expect that baseline and restore it after successful Save paths; a failed run may leave test edits, so reset the disposable fixture before retrying.

## External harness

Durable test source: `Tools/release-audit/TVLibraryEditingAuditTests.swift`.

The working copy is also placed at `/tmp/icube-tvos-audit-2026-10-19/fixed-ui/project/Tests/TVLibraryEditingAuditTests.swift`. Existing `project.yml` includes all `Tests/` sources. Regenerate that **external harness** before its next SDK build so its generated project includes the new file; no app Tuist generation is needed for these test sources. The UI test launches `com.joemattiello.iCube-debug` in English. Use an installed build containing the actual metadata editor and explicit tile redraw epoch.

For the URL-cover case, run the scratch fixture server in another terminal:

```sh
python3 Tools/release-audit/prepare_library_editing_fixture.py --output /tmp/icube-library-edit-fixtures --serve
```

It binds `127.0.0.1:8765` only. Simulator loopback reaches the host. A physical Apple TV requires an explicitly reachable fixture host and HTTP transport permission; this loopback recipe targets the simulator. The test defaults to that URL; `ICUBE_AUDIT_COVER_BASE_URL` can be set in the UI-test target's test environment for another host. `/oversized.png` advertises 12MiB+1; `/oversized-stream.png` omits Content-Length for a separate streaming-cap check. The server streams oversized bytes without allocating that entire body. It exposes no arbitrary local files.

Run the `ICubeTVAudit` scheme against the chosen tvOS simulator with only `TVLibraryEditingAuditTests` selected. This preparation deliberately performs no project generation, build, simulator install, container mutation, app launch, or test execution.

## Assertions and evidence

- Title/tags: Save changes the rendered tile; reopening and relaunch retain values. Editing a second draft then Cancel preserves the saved values.
- Back: discard an unsaved draft, return focus to the invoking tile, and reopen without the draft.
- Cover: bounded URL artwork changes rendered preview pixels, Save/reopen retains it, oversized input displays an error, and clearing restores the original preview through Save/reopen. Saved and cleared tile screenshots are attached for rendered grid-art inspection.
- Focus: waits for the invoking tile's actual accessibility focus after each dismissal; existence alone does not pass. Keyboard dismissal must leave the editor open.

Every diagnostic records the accessibility tree and screenshot. Review saved/cleared grid tile screenshots as well as editor preview assertions; this source does not yet automatically crop/compare tile artwork. Text-entry keyboard focus behavior, actual long-select context-menu reachability, preview pixel stability across reopen, the harness API compile, and all assertions remain unverified until the real run. Report failures as gates and refine only from captured UI evidence. Native store/service tests establish persistence and bounds separately; they do not substitute for these rendered checks.
