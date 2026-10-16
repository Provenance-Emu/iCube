# Handoff: "tvOS redesign" session, closing 2026-10-15

Everything below is pushed unless marked otherwise. iCube develop at handoff: 9e56197285.
Memory index entries carry the same facts: icube-physical-profile-adapter, icube-ecosystem-2026-10-14,
icube-sentry-triage-review-2026-10-15.

## Shipped in this session (iCube develop)

| Commit | What |
|---|---|
| 080592e564, d6d21ab216 | Physical-profile controller adapter (NSO N64 pad on tvOS) + MFi accelerometer fix (m/s², total accel). Prebuilt core refreshed. |
| 5de3f14a4c | Send to Provenance / requestGame now hand over via the share sheet (HTTP same-device pull never worked). Settings > Sync & Network > Connected Apps. |
| c0aac5c16a | CloudKit ON: containerIsProvisioned = true, entitlements in all four files, shared app group + keychain group, push keys removed. docs/entitlements-audit-2026-10-14.md. |
| f49db0c267, 94111aa9a7, 0a7ee0d2f7 | NFC tag-to-play (shared format with Provenance/iFly), https tag recognition, applinks:icube-emu.com, NFC entitlement value TAG (NDEF is rejected at upload, ITMS-90778). |
| 7c6663a6e0, 9e56197285 | ICUBE-G / ICUBE-FJ exit-time mutex race: termination saves+stops without teardown; atexit guard (PGO flush, Config::Save, _exit(0)) registered at launch and in willTerminate. |

## Open, needs the owner

1. **iCube TestFlight is failing** (scheduled run 38754231843, 2026-10-15): "Authentication failed … bearer token … expired", then no profiles for com.joemattiello.iCube. The ASC API key secret in Provenance-Emu/iCube likely expired/rotated; Provenance's run with its own key succeeded the same morning. New entitlements (NFC, associated domains, iCloud) need a fresh profile, so nothing ships until this is fixed. A manual run 38790776983 was queued by someone else at 19:03 UTC.
2. **iFly TestFlight jobs never start**: GitHub billing ("recent account payments have failed or your spending limit needs to be increased") on JoeMatt's account.
3. **AASA on icube-emu.com** before tags/links can use the https form; iCube writes dolphinios:// until then.
4. **CloudKit schema**: first device run with sync on, then ck_schema_promote (asc.sh).

## Device tests owed (none done)

- NSO N64 pad on Apple TV: `[INPUT] connected` log line, Start reaches the game, Home pauses, C buttons drive the C-Stick.
- DualSense in a Wii pointer game: pointer visible and tracking after the accel fix; if axes are wrong, read MotionDebugView held level.
- NFC: Write to NFC Tag, tap from lock screen, Scan NFC Tag; a Provenance tag says "belongs to Provenance".
- Send to Provenance from the game menu → Provenance imports it.
- Close iCube from the app switcher mid-game: no new ICUBE-G/FJ events from builds after 9e56197285.

## Agreements with other sessions

- Library-sharing contract (Provenance PVLibrarySharing, spec docs/superpowers/specs/2026-10-14-cross-app-library-sharing-design.md in Provenance): iCube's API shape is frozen. `_icube-continuity._tcp` stays (16 chars, verified to register and browse). Provenance serves GC/Wii files as `Software/<file>`; pair/complete 404 = paired; TXT must carry `v` and `sid`; catalog/manifest version stays 1 on that type.
- The Provenance session bumps gitlinks through the index only and never checks out inside Cores/Dolphin/dolphin-ios; still verify `git branch --show-current` before committing there.

## Housekeeping state

- Worktrees `~/Workspace/icube-mods*` hold feature/mods-* branches that are merged into develop; they belong to the ROM patching session.
- Weekly Sentry triage routine trig_014fxnY3g7GYXvNQgZsbdRRq: prompt updated with expected-signals rules; Sentry always-allow now includes get_event_stacktrace, search_issue_events, search_sentry_tools, execute_sentry_tool (the last can reach write tools; prompt forbids writes). Next run Mon 2026-10-19 13:13 UTC.
