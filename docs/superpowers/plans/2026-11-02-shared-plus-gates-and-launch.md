# Shared Plus Gates and Launch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Execute the owner's approved policy; no new paywalls on existing free features.

**Goal:** Align free feature access and recognize existing qualifying Plus purchases in iCube, iFly and Provenance; refresh iCube's static launch presentation.

**Architecture:** Preserve each app's existing ownership facade and same-team direct-purchase mirrors, separate free manual activity from paid automation, and keep iCube read-only for purchase recognition. Update the actual launch storyboard, rather than adding an artificial SwiftUI splash delay.

**Tech Stack:** Swift, SwiftUI/UIKit, StoreKit 2, Keychain, Interface Builder, native/pure regression harnesses.

**Spec:** ../specs/2026-11-02-shared-plus-policy-design.md and ../../app-store/release-evidence/2026-11-02-shared-plus-gates-audit.md; owner authorized execution November 2 and explicitly left undecided extras unchanged.

## Global Constraints

- Existing free features stay free. No new iCube sales product, Lifetime activation or purchase UI.
- Do not change texture-pack, Watch VMU, recording/watermark, theme/icon/UI-mode decisions.
- Basic/imported shaders persist while unpaid. Manual transfers and basic compatibility settings remain usable.
- Ordinary save protection remains free; ROM automation and manual copies are separate scopes.
- No App Review submission, physical device testing, remote signing mutation or website publication.
- Preserve unrelated WIP; isolated iCube/iFly/Provenance worktrees and disjoint ownership.

## Review Focus

- Imported CRT names, symlinks, traversal and favorites/recents must not bypass trusted origin or charge legitimate imports.
- Free manual copies must continue past old daily quotas; automatic mirroring must not acquire an accidental transport bypass.
- Loading ownership is not expired ownership; lifetime, renewal, revocation and sibling grants must not echo or become permanent accidentally.
- Free save scope must survive relaunch and restore; do not silently sync paid ROM scope or erase user data.
- Launch layout must fit phone landscape, tablet and large text; compile the storyboard and inspect real UIKit renders without a full core rebuild.

## Task 1 — iFly free access (agent)

Files: ProShaderPolicy.swift, shader apply/picker paths, ContinuityPullMetering.swift, Game Settings entry points, ProFeature/Paywall copy and focused tests. Do not modify entitlement files owned by Task 3.

- [x] Add failing trusted imported-origin and expired manual-quota regressions; run them against the old code.
- [x] Exempt real imported shaders in both pickers/persistent apply. Remove manual copy/Handoff quota, preserve automatic engine gate. Expose basic per-game settings in all four routes.
- [x] Leave undecided extras gates intact. Keep the safe one-time post-session prompt; wait for Task 3 ownership settlement.
- [x] Run meaningful targeted harnesses and syntax/format checks; commit owned changes and report limitations.

## Task 2 — Provenance free save/configuration and safe prompt (agent)

Files: CloudSyncUpsellView.swift, SettingsSwiftUI.swift, SupportNagManager/View, game-session return hook, Audio/API safety entry points, focused tests. Entitlement bridge belongs to Task 3.

- [x] Pin free save scope, ownership-loading and safe prompt eligibility regressions before fixes.
- [x] Expose save/progress recovery and practical audio/security controls, separate existing paid ROM automation scope without removing free TV protection.
- [x] Move support prompt to successful library return, immediate dismissal and permanent opt-out. Retain cadence until explicitly decided.
- [x] Verify touched paths and tests, preserve recording/cosmetic gates, commit only owned files.

## Task 3 — Three-app Plus recognition (agent, disjoint files across repositories)

Files: existing iFly/Provenance ownership mirrors/facades/tests; iCube new read-only SharedPlusEntitlement facade, shared-group declaration and tests. Root adds the agreed launch call if needed.

- [x] Test direct ownership, sibling grants, lifetime, missing/invalid payload, loading, expiry/renewal/refund and no echo.
- [x] Reuse compatible existing payloads and grace rules; refresh on lifecycle/purchase updates and recognize qualifying Provenance/iFly purchase in iCube without new sales.
- [x] Inspect cross-device/tvOS restore support and document actual scope. Do not claim same-device Keychain tests prove another-device purchase restore.
- [x] Run focused regression tests, validate declarations and compile touched interfaces; commit per repo with other agents' files excluded.

## Task 4 — iCube launch (root)

Files: DolphiniOS/Base.lproj/LaunchScreen.storyboard, localized LaunchScreen.strings, design resources only if needed. The unused DolphinSplashView is not the screen in the user's screenshot.

- [x] Replace oversized/low-contrast composition with compact existing-brand mark, readable wordmark, dark canvas and short platform caption; remove fake static progress and crowded credits (retain About credits).
- [x] Keep autoresizing safe-area constraints for portrait/landscape and tablet; no new delay, random animation or app-launch blocking.
- [x] Compile with ibtool and render a small dedicated UIKit preview harness; inspect phone/tablet layouts and capture proof. Do not use reserved/stuck simulators.
- [x] Commit only root-owned UI/docs files.

## Integration and completion

- [x] Review each task against policy and tests, then independent whole-change source review; fix actionable findings.
- [x] Verify only intended files committed; retain evidence, unverified device/purchase scope and remaining release gates.
- [x] Update source audit/handoff with actual changes and test results. Never mark App Review submitted or external purchases verified without evidence.

## Execution limits

Implementation/source-review steps are complete; checks above refer to targeted native harnesses and UIKit Catalyst previews. Full app, hosted XCTest, real StoreKit/CloudKit and hardware acceptance remain pending; see the linked implementation evidence. Existing devices/simulators were preserved. GameCube Pocket was additionally bundled as an optional offline skin, with no automatic selection because historical None cannot be distinguished safely.
