# Shared Plus feature-gate audit

Date: November 2, 2026. Policy: [shared Plus design](../../superpowers/specs/2026-11-02-shared-plus-policy-design.md).

Historical before-state. See the [implementation follow-up](2026-11-02-plus-policy-implementation.md) for fixes now on isolated review branches.

Static source audit, not an installed-build or purchase acceptance test. No gates
changed. No builds, device tests, purchases, website deployments or App Review
submissions performed. Prior release artifacts and unrelated working changes
were preserved.

## Source scope

| Repository | Inspected checkout HEAD | Scope/limits |
|---|---|---|
| iCube | `322f8d99cf68f7c846470f15542a33c0a0267f55` | App UI, shaders, cloud/nearby services; existing modified native framework artifacts excluded. This is not the selected App Store candidate's source identity. |
| iFly | `97e3d598040245c2897112241b2d4f9dd566a6e3` | Monetization, shader application, transfers, automation, settings, prompts; unrelated dirty Base.xcconfig and backup excluded. |
| Provenance | `efe15726154b3a907b148d1c035ff7e289a6e72a` | PVUI gates/prompts/entitlements, PVShaders and app distribution overrides; unrelated library/UI/web-server WIP excluded. |

Website claims inspected locally in iFly `src/components/plus/plusFeatures.ts`,
Provenance `data/plus.yml`, and iCube downloads/sources/comparison pages. These
are local source statements, not a fresh production-site or ASC inventory.
Pinned source links below identify the app evidence; line references are
inspection anchors, not a claim that every route or runtime was exercised.

## Findings and work queue

### PLUS-01 — Imported shaders can be treated as paid in iFly

**Confirmed source mismatch; fix before asserting the shared shader policy.**

[`ProShaderPolicy.swift`](https://github.com/JoeMatt/iFly/blob/97e3d598040245c2897112241b2d4f9dd566a6e3/Sources/Core/Monetization/ProShaderPolicy.swift#L14)
allows a default preset and free folder names; it has no imported-origin
exemption. `ShaderManager.swift:212` scans Documents/Shaders, and
`ShaderSettingsView.swift:204` leaves non-bundle paths absolute. Its
`applyPreset` at line 165 sends non-free presets into a session-only taste
instead of writing the persistent selection. The tvOS picker calls the same
policy (`ShaderPickerView+tvOS.swift:118`). Thus an imported
`Documents/Shaders/crt/custom.slangp` that matches neither a free folder nor the
default name falls into the paid-preview path for an unpaid App Store user.

Action: identify actual imported origin independently of category and apply
the exception through picker/favorites/MRU/quick routes. Verify persistent use
after relaunch on both platforms. Keep existing default/free buckets free.

### PLUS-02 — Manual nearby pulls share iFly's paid Handoff meter

**Confirmed source mismatch with free manual sharing.**

[`ContinuityPullMetering.swift:8`](https://github.com/JoeMatt/iFly/blob/97e3d598040245c2897112241b2d4f9dd566a6e3/Sources/Core/Continuity/ContinuityPullMetering.swift#L8)
allows three approved pulls per day without `.unlimitedContinuity`.
`ContinuityService.swift:113` injects it as session `grantPolicy`;
`ContinuityLibrarySharingService.swift:192` also injects it as library
`pullPolicy`. The library route therefore charges the same counter, despite
older comments in `ContinuityAllowance.swift` describing ecosystem transfers
as exempt. A Plus gate on automatic mirroring does not justify metering manual
copying through the same transport.

Action: separate manual copy/Handoff admission from automatic rule execution.
Prove unpaid manual copying still works after the former three-use threshold,
including iFly sources paired with iCube/Provenance. Keep trust checks intact.
Do not require Plus on both ends of an authorized transfer.

### PLUS-03 — Provenance gates the whole cloud settings/sync path

**Confirmed source mismatch with the working free save-sync baseline.**

[`SettingsSwiftUI.swift:2534`](https://github.com/Provenance-Emu/Provenance/blob/efe15726154b3a907b148d1c035ff7e289a6e72a/PVUI/Sources/PVSwiftUI/Settings/SettingsSwiftUI.swift#L2534)
wraps iOS Cloud Sync Settings in `PaidFeatureView`; tvOS uses a separate
ungated branch. `CloudSyncUpsellView.swift:38` checks Plus on genuine App Store
installs and its settled `.onAppear` path at line 126 disables the shared
`iCloudSyncEnabled` flag for a non-premium user. It is not scoped to ROM
mirroring. Local website `data/plus.yml` sells saves together with ROMs, BIOS,
settings and artwork, with an explicit free tvOS exception.

Action: separate ordinary save/progress sync from paid whole-ROM-library
automation, retaining free tvOS data protection and backup access. Test genuine
unpaid App Store behavior and lapsed subscriptions, not only TestFlight. Do not
remove current cold-start entitlement-settlement protection.

### PLUS-04 — iFly gates basic per-game tuning together with profiles

**Confirmed mismatch with the working free compatibility-settings baseline.**

[`LibraryItemViews.swift:224`](https://github.com/JoeMatt/iFly/blob/97e3d598040245c2897112241b2d4f9dd566a6e3/Sources/UI/Views/LibraryItemViews.swift#L224)
requires `.perGameProfiles` to open Game Settings; the same requirement appears
at line 397, `PauseMenuView+GameActions.swift:248` and
`PauseMenuView+tvOSGrid.swift:579`. The gate is broader than saved named profile
management. `ProFeature.swift` and website copy advertise per-game tuning as
paid.

Action: permit ordinary per-game performance/compatibility edits and reset;
decide separately whether named multi-profile workflows are Plus. Audit every
entry point and existing override recovery before changing the gate.

### PLUS-05 — Provenance's support nag competes with launching a game

**Confirmed source mismatch with non-interrupting, immediately dismissible asks.**

[`GameLaunchingViewController.swift:1437`](https://github.com/Provenance-Emu/Provenance/blob/efe15726154b3a907b148d1c035ff7e289a6e72a/PVUI/Sources/PVUIBase/GameLaunching/GameLaunchingViewController.swift#L1437)
calls `checkAndShowSupportNag` while presenting the emulator. The helper at
line 1552 schedules a full-screen cover after 0.5 seconds.
`SupportNagView.swift:245` delays the dismiss control for 2.5 seconds.
`SupportNagManager.swift:15` uses launches 10, 25, then every 15, with a four-day
minimum; it records dismissals but has no permanent suppression preference.
The code suppresses a known shared Plus grant; pending ownership is not
explicitly checked there. Presentation success/timing was not tested.

Action: move eligibility/presentation to successful return to the library,
provide immediate dismissal/permanent opt-out, wait for entitlement resolution,
and agree cadence. The proposed 30-day floor is not an approved requirement.

### PLUS-06 — iFly's prompt is safer, but differs in cadence

**Mostly aligned; optional enhancement, not a launch blocker by itself.**

[`ProMomentPrompt.swift:15`](https://github.com/JoeMatt/iFly/blob/97e3d598040245c2897112241b2d4f9dd566a6e3/Sources/Core/Monetization/ProMomentPrompt.swift#L15)
asks once after ten recorded sessions, suppressing `hasPurchased` users.
`AppCoordinator.swift:1181` asks after returning to the library and yields to
the rating prompt. `ProMomentCard.swift` offers Maybe Later. One-time behavior
is less frequent than the proposed recurring prompt and is acceptable to keep.
There is no explicit pending-entitlement check in the prompt predicate.

Action: retain safe timing; verify purchase loading cannot produce a false
upsell. Do not replace the one-time ask with repeated nags without a decision.

### PLUS-07 — Provenance gates practical audio and security controls

**Audio is a working-policy mismatch; free security is an explicit audit safeguard.**

[`SettingsSwiftUI.swift:1731`](https://github.com/Provenance-Emu/Provenance/blob/efe15726154b3a907b148d1c035ff7e289a6e72a/PVUI/Sources/PVSwiftUI/Settings/SettingsSwiftUI.swift#L1731)
locks Audio Engine, including buffer/latency configuration. This needs review
against free compatibility/performance tuning, rather than selling the entire
page as power-user settings. `AdvancedTogglesView.swift:40` also gates Disable
Auto Lock; UI Mode is gated at line 48. Cosmetics and automation are not all
the same classification.

`DebugAPISettingsView.swift:50` uses `PremiumThemedToggle` for Require Password;
its implementation at `PremiumThemedToggle.swift:51` disables the locked toggle.
This is a UI gate, not proof of an unauthenticated server or an exploitable
runtime condition. Nevertheless, protecting a local API must not require Plus.
Developer automation availability can be classified separately from its safety
controls. Do not weaken authentication while adjusting monetization.

### PLUS-08 — Recording differs; no shared decision yet

**Unresolved product classification, not automatically a confirmed violation.**

iFly permits recording and gates watermark removal
(`GameplayRecorder.swift:145`, `PauseMenuView+Recording.swift:103`). Provenance
gates recording, broadcast and buffered clips in
[`RetroMenuView.swift:914`](https://github.com/Provenance-Emu/Provenance/blob/efe15726154b3a907b148d1c035ff7e289a6e72a/PVUI/Sources/PVUIBase/PVEmulatorVC/RetroMenuView.swift#L914),
lines 996/1064, `PauseTileMenuView.swift:502`, its recording settings page and
`PVControllerViewController.swift:2133`. iCube has no Plus facade found in the
audited app sources.

Action: decide whether basic recording should be free everywhere and which
advanced recording conveniences can be paid. Do not change all gates from a
single menu and leave the toolbar/settings paths inconsistent.

### PLUS-09 — Other extras need classification rather than blanket removal

**Decision queue.** iFly gates enabling custom textures
(`SettingsView+Video.swift:654`), Watch VMU (`SettingsView+VMU.swift:151`,
`VMUWatchSession.swift:141`) and watermark removal. Provenance gates themes,
app icons and missing-artwork style through paid wrappers. These are existing
extras but not all named by the new agreement. Imported **shaders** being free
does not itself decide imported **texture packs**. Keep these choices explicit.

### PLUS-10 — Three-app entitlement sharing is not implemented/accepted

**Implementation gap; do not advertise a three-app purchase today.**

iFly's [`ProEntitlement.swift:80`](https://github.com/JoeMatt/iFly/blob/97e3d598040245c2897112241b2d4f9dd566a6e3/Sources/Core/Monetization/ProEntitlement.swift#L80)
reads Provenance and publishes its own direct purchase mirror.
`CrossAppEntitlement.swift` uses `provenance.plus` / `ifly.pro` in a same-team
shared keychain with expiry plus a seven-day renewal grace. Provenance's
`CrossAppEntitlementPublisher.swift` reads/writes the corresponding mirrors and
guards against sibling-grant republishing; its reader latches a sibling grant
for that launch, with revocation deferred until next launch (lines 327–351).
iFly's crossover pitch requires Provenance 3.4.0 according to
`ProvenanceCrossover.swift`; release-check fallback can use a GitHub release
when App Store lookup fails (`ProvenanceReleaseCheck.swift`). That fallback is
not proof a compatible App Store release is available in a user's territory.

No matching StoreKit/Plus purchase facade or sibling-mirror integration was
found in iCube app Swift/ObjC sources. This is an absence-of-integration result,
not a shipping entitlement test. Same-device mirrors do not establish
cross-device/Apple TV/Family Sharing restoration. No purchase may be conveyed
merely because a different-account device is authorized to share ROMs.

Action: specify qualifying existing products and supported restore paths; test
both purchase directions, then iCube recognition, expiry, refunds, renewal,
offline launch and actual App Store signing. Reconcile latch/loading behavior
and launch marketing before claiming one working three-app membership.

### PLUS-11 — iCube's existing free baseline is broader than the target paid extras

**Protect the baseline; not a request to retrofit locks.**

[`ShaderQuickApply.swift:37`](https://github.com/Provenance-Emu/iCube/blob/322f8d99cf68f7c846470f15542a33c0a0267f55/Source/iOS/App/Common/Swift/Shaders/ShaderQuickApply.swift#L37)
applies/persists without a purchase gate.
`CloudSyncModelBuilder.swift:32` exposes save/settings sync without Plus and
states games are never uploaded. `NearbyLibraryMirrorService.swift:32` and its
view expose automatic paired foreground mirroring without a Plus check. No
StoreKit/Plus enforcement was found in the audited app directories.

Action: preserve existing free shader/save behavior. Before charging for
already-previewed mirroring, resolve launch expectations and record the public
baseline. Future Plus shader packs should be additional curated content, not
the current free catalogue relabeled. The draft iCube Lifetime IAP remains
deferred; no new purchase is required for its current free release. Transport
presence in source is not accepted iCube/Provenance interoperability.

### PLUS-12 — Websites and paywall descriptions need alignment

**Confirmed local-copy mismatches; deployment not changed.**

- iFly `plusFeatures.ts` lists paid per-game tuning and three free Handoffs/day;
  these conflict with the working free manual/compatibility boundary. Its
  automatic library-sync pitch fits the target. `PaywallView.swift:115` lists
  skins among paid extras, despite `ProFeature.swift` explicitly keeping bundled
  and imported skins free. Do not create a new skin restriction to match copy.
- Provenance `data/plus.yml` bundles saves into paid sync and has a platform
  exception for TV. Its existing all-shaders-free claim is a baseline to
  preserve, not a reason to lock those shaders under the new shared policy.
- iCube downloads/sources pages mention free access to “every Plus feature” on
  sideloaded copies even though its Plus implementation is deferred. Its
  Provenance comparison describes paid save-state/library sync and undocumented
  iCube cloud sync. Update only after the actual boundaries are implemented;
  do not announce future purchase functionality as shipping.

### PLUS-13 — Debug/TestFlight can conceal purchase-gate failures

**Validation gap.** iFly `AppDistribution.swift` enables freemium for its
App Store/TestFlight classification and offers `-FORCE_FREEMIUM` for local
tests. Provenance's `ProvenanceApp.swift:115` grants tier 1 in DEBUG/simulator
and non-AppStore cases; cloud UI explicitly treats non-genuine-AppStore as
premium. A passing free-development flow cannot prove an unpaid App Store flow
is accessible. Test the actual detection and each intended distribution rather
than trusting comments or assuming the apps use identical TestFlight rules.

## Alignment already visible in source

- iFly has deliberate free basic/default shader buckets and a central Plus
  facade. Its automatic `LibrarySyncEngine.syncNow` checks `.librarySync`
  before reconciliation (line 183); keep that automatic/manual separation.
- iCube's ungated saves, configuration, library editing and shader application
  fit a complete free launch. No new locks are needed to document the policy.
- Provenance preserves a free tvOS cloud-settings route and manual Backup &
  Restore; those data-protection paths should remain accessible.
- The iFly/Provenance entitlement bridge already distinguishes direct ownership
  from granted sibling benefits. Retain that protection when expanding it.

## Acceptance required before calling gates aligned

1. Build a per-app launch feature/catalogue inventory and preserve free access;
   resolve iCube previewed mirroring before introducing a restriction.
2. Prove persistent imported/basic shader use while unpaid on iOS/tvOS,
   including non-free category names, favorites, recents and quick apply.
3. Prove repeated manual library copies and user-initiated Handoff stay free;
   automatic mirroring requires Plus only on the initiating installation.
4. Prove save protection/recovery and per-game compatibility configuration are
   accessible while unpaid or lapsed, without deleting existing data.
5. Verify support prompts only at a calm library boundary, with immediate
   dismissal, opt-out and known-owner suppression; agree recurrence separately.
6. Verify real purchase/restore/expiry/refund/renewal paths in each supported
   distribution and platform before advertising shared purchase coverage.
7. Reconcile all affected menus, settings, websites and sales copy. Resolve the
   recording/texture/Watch/cosmetic extras individually; do not infer a decision.

This is a documentation audit only. These acceptance checks have NOT been run
as part of it. Existing App Store preparation and device/sync acceptance gates
remain separate and unresolved where previously recorded.

## Documentation validation

An independent builder/source check found no additional corrections, confirmed
the pinned imported-shader and cloud-sync findings, and reiterated that a public
free-baseline inventory is required before planning gate changes. All ten pinned
GitHub source anchors were checked against local git objects; both policy/audit
relative links resolve. No app tests were run for this documentation-only change.
