# Shared Plus policy: iCube, iFly and Provenance

Date: November 2, 2026. Owner: Joseph Mattiello.

This is the canonical cross-app product policy for this release discussion. It
documents the owner's direction; it does not change purchases, feature gates,
App Store metadata or release scope. The companion [source audit](../../app-store/release-evidence/2026-11-02-shared-plus-gates-audit.md)
records where current implementations differ.

## Intent and decision status

The free apps should feel complete. Plus funds development by adding a wider
curated collection and convenience, especially automation. Installing another
app in the family should not reveal a contradictory definition of the same
feature or demand another purchase for an advertised shared benefit.

The owner explicitly approved keeping **basic and imported shaders free**,
allowing most functionality free, additional shaders and automatic features as
Plus candidates, and considering occasional support prompts for active users.
The preceding discussion established the working boundary of free manual
sharing versus paid automatic ROM/library mirroring. Protecting iCube's launch
baseline from later feature removal is a central requirement.

Exact shader-pack membership, prices, subscription products, lifetime purchase
mapping, Family Sharing coverage and prompt cadence have NOT been approved.
The detailed safeguards below are the author's proposed implementation rules
for that direction. App-specific extras listed as undecided are not silently
approved or removed by this document.

## Shared feature boundary

| Capability | Working policy | Meaning |
|---|---|---|
| Emulation, supported systems, game imports and exports | Free | No play-time limit or arbitrary library-size limit. |
| Save/load states, automatic resume, memory cards and ordinary game saves | Free | Protection and recovery of progress are core functionality. |
| Controllers, touch controls, basic performance and compatibility settings | Free | Users must be able to make their own games playable. Reset/recovery controls stay accessible. |
| Library titles, covers, tags, favorites and ordinary organization | Free | Local editing and access to user-created data are not subscription benefits. |
| Manual nearby browsing, authorized copy/import/export and manual sharing of edits | Free | No daily transfer meter. Pairing and permission requirements still apply. |
| Basic shaders, the default shader, turning effects off and shader parameters | Free | A useful selection must work persistently, rather than only as a temporary preview. |
| User-imported shaders | Free | Import, persistent selection, favorites and application remain free irrespective of their filename or shader family. |
| Additional app-curated shader collections | Plus | Sell the convenience of the curated collection. Basic/imported access must not depend on buying it. Only suitably licensed material may be offered. |
| Ordinary save/progress sync and access to existing backups | Free working baseline | Do not interpret “automatic features” as a blanket permission to charge for save protection. Provenance currently differs; implementation must separate saves from whole-library sync. |
| Automatic ROM/library mirroring | Plus target | Opt-in rules that copy newly discovered games without an individual transfer action. Includes starting a subscription's full mirror reconciliation with “Sync Now”; ordinary one-off manual copying remains free. |
| Future batch automation and orchestration | Plus candidate | Evaluate individually. Do not gate all existing auto-prefixed settings. |

Cheats, achievements, controller skins, existing free settings sync and current
free functionality remain protected by each app's baseline. This policy does
not promise technical compatibility where a core/platform cannot provide it.

### Shaders: classify provenance, not directory spelling

Use an explicit bundled catalogue classification and a trusted imported origin.
An imported CRT or NTSC shader must remain free even when a bundled curated CRT
or NTSC collection is Plus. Applying, reloading and persisting an imported
preset must behave the same way from the main picker, favorites, recents and
quick controls on iOS and tvOS.

Keep the active default free by construction. Do not relabel an existing free
collection as paid. Where iCube or Provenance already supplies more shaders
free, preserve that baseline; additional Plus packs can be introduced later.
Free-import support must remain real, rather than blocking imports that look
similar to a curated pack. Paid previews must be explicit and cancellable.

### Transfers: distinguish who requested the work

Free manual transfers include browsing another authorized installation and
choosing a game or a batch to copy now. Automatic mirroring means enabling a
rule that subsequently finds and copies new games. A scheduled operation does
not become free merely because its control is named “Sync Now.” Conversely,
using a transport shared with automation does not make a manual copy paid.

Proposed rule for paired devices: the device initiating automatic mirroring
needs Plus; an authorized source or receiving peer must not need a second
purchase just to serve/accept the transfer. Check entitlement before admitting
paid automation, not after a file has partially transferred. Continue normal
trust, capacity and file-integrity checks. Nearby/different-account ROM sharing
does not convey another person's Plus membership.

Do not conflate save sync, library metadata sync, ROM mirroring and session
Handoff. Their current code paths overlap, but their product policies need
separate decisions. Manually initiated Handoff belongs on the free side of this
working policy; automatic follow-me behavior may be evaluated separately.

## Membership and data safeguards

The target is one recognizable Plus membership across the three apps, honoring
qualifying existing purchases without a duplicate charge for shared benefits.
Cross-app recognition is a release claim only after purchase/restore tests pass
in the shipping distributions. A shared same-device keychain mirror alone is
not proof of cross-device, tvOS, Family Sharing or different-account entitlement
coverage. Library-pairing permission is separate from purchase ownership.

Before expanding the sales promise, document which existing monthly, annual and
lifetime products qualify, their original commitments, supported devices and
restore path. Preserve valid existing purchases. No new price or lifetime
product is authorized here. iCube's draft Lifetime purchase remains deferred;
its current free release must not advertise an implemented Plus tier.

On expiry or entitlement uncertainty:

- Never delete or hide games, edits, saves, backups or completed transfers.
- Keep manual export, recovery, security and basic configuration available.
- Stop admitting new paid automation after the actual entitlement decision;
  retain configuration so it can be resumed, and finish or safely cancel
  admitted work without corrupting files.
- Treat loading/unknown separately from confirmed inactive. Never turn off
  save sync or rewrite settings because StoreKit has not finished loading.
- Preserve selected settings and paid-pack configuration. Explain any fallback
  at a safe menu boundary; do not interrupt gameplay or erase the selection.
- Test expiry, refund/revocation, renewal, restore and offline behavior in each
  app. Do not republish a sibling grant as a new independent lifetime purchase.

## Launch expectations and existing users

Record the exact public free baseline per app/version before changing gates.
Preserve access that was publicly shipped/promised free. New features can have
a clearly communicated paid boundary from introduction; existing free features
must not silently move behind a paywall in a later update.

iCube's current public TestFlight includes ungated shaders, cloud settings/save
sync and nearby automatic mirroring code. The source audit does not establish
which of those behaviors passed hardware acceptance or what each tester was
promised. Before adding any restriction, explicitly reconcile that preview,
the approved release-blocker scope and the intended first App Store baseline.
Do not assume a local install-date flag is a reliable ownership record. Do not
promise testers all future paid features forever without an explicit decision.

This document does not remove library editing/sharing/sync from the existing
1.0 acceptance gates. A monetization decision is not evidence the feature works.
For the current candidate, iCube remains free and its unimplemented purchase
remains out of submission. No new paywall is added by this audit.

## Occasional support prompts

The owner is open to a low-frequency prompt for active free users. Proposed
rules: show only after a successful session returns to the library; provide an
immediately usable dismissal and “Don't ask again”; suppress for qualifying
Plus members, during purchase restoration and when ownership is unknown.
Never interrupt gameplay, launching, saving, loading, recovery or transfers.
Do not stack it with review requests or error dialogs. Describe funding and
actual optional benefits without suggesting core gameplay is a trial.

An initial proposal is eligibility after ten successful sessions and a minimum
30 days between dismissed prompts. These are NOT owner-approved numbers.
Existing one-time prompts can remain less frequent. Cross-app coordination is
desirable but must not require behavioral tracking or block launch; per-app
limits are the minimum until shared suppression is verified.

## App-specific extras needing a separate decision

iFly currently sells texture-pack use, per-game tuning, Watch VMU and watermark
removal. Provenance sells recording/broadcast/clips, audio settings, certain
themes/icons and assorted advanced controls. This policy does not automatically
approve all these gates or require every app to offer identical optional tools.

Basic per-game compatibility adjustments must be accessible under the working
free baseline; named multi-profile management could remain a separate Plus
extra. Purely cosmetic extras may fit Plus. The owner has not decided whether
imported texture packs or basic recording should be shared free benefits.
Security/authentication controls must remain usable regardless of membership
(author's safety rule); do not charge users to protect an exposed local API.

## Audit and follow-through

See the [gate audit and remediation queue](../../app-store/release-evidence/2026-11-02-shared-plus-gates-audit.md)
for pinned source evidence, confirmed mismatches and unresolved classifications.
Implementation should begin with shader-origin classification, free manual
transfers, save-sync separation and prompt safety. Capture the existing free
catalogues before introducing any new paid pack. Align app text, websites and
App Store disclosures only with behavior verified in the release candidate.

Out of scope for this documentation task: changing gates or prices, deploying
websites, creating new subscriptions, modifying signing, publishing a Plus
purchase, hardware automation or submitting either app for review.
