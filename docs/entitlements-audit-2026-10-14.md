# Entitlements and capabilities across Provenance, iCube and iFly (2026-10-14)

Owner is enabling capabilities in the developer portal and Xcode and asked which of a
long list are worth having, and what has to land in the project generators so the
changes stay. Portal state below comes from the App Store Connect API
(`bundleIdCapabilities`, read 2026-10-14 ~23:30 UTC); file state from the three
working trees, including the owner's uncommitted Xcode edits. Research on the
capability list was done by a separate agent against Apple's entitlement reference;
"NV" marks what it could not verify.

## 1. Where things stand

### Portal (App IDs)

| App ID | Capabilities enabled |
|---|---|
| `com.joemattiello.iCube` (+ the 7 other shipping iCube ids) | App Groups, **iCloud (new)**, Extended Virtual Addressing, Increased Memory Limit (+debugging), Inter-App Audio, In-App Purchase, Push Notifications, Sustained Execution (not on every id) |
| `com.joemattiello.iFly` | App Groups, Associated Domains, EVA, Game Center, iCloud, Increased Memory (+debugging), IAP, Network Slicing, Push, SiriKit, Spatial Audio Profile, Sustained Execution |
| `org.provenance-emu.provenance` | Access Wi-Fi Info, Sign in with Apple, App Attest, App Groups, Associated Domains, DriverKit, EVA, FileProvider Testing Mode, Font Installation, Game Center, Group Activities, Hotspot, iCloud, Increased Memory (+debugging), Inter-App Audio, IAP, Journaling Suggestions, Messages Collaboration, Multipath, NFC Tag Reading, Push, Shared With You, SiriKit, Sustained Execution, System Extension Install, Time-Sensitive Notifications, User Management |

`com.joemattiello.iCube-patreon-beta` has neither App Groups nor iCloud; it is not in
`Project.swift`'s `appConfigs`, so it does not matter unless it ships.

The public API cannot list app groups or iCloud containers, so whether
`group.org.provenance-emu.provenance` exists in plain form (the code and every
entitlements file use the plain id; the portal shows a `.S32Z3HMYVQ` one) is for the
owner to confirm in the portal. On iOS the group id needs no team prefix; a
team-suffixed name is just a unique name, nothing more. If only the suffixed one
exists, Provenance would have failed automatic signing long ago, so the plain one is
probably there under a different description.

### Files, and what persists

- **iCube** (Tuist): `CODE_SIGN_ENTITLEMENTS` points at `DolphiniOS/DolphiniOS.entitlements`
  and `DolphiniOS/iCube AppStore.entitlements`, `infoPlist: .file("DolphiniOS/Info.plist")`.
  Xcode capability edits write into those files, so they persist. Only the pbxproj's
  `SystemCapabilities` block is regenerated, and signing does not read it.
- **iFly** (Tuist): entitlements persist (`iFly.entitlements`). **Info.plist does not**: it is
  `.extendingDefault(with: sharedInfoPlist)` in `Project.swift`, and the owner's edits
  landed in `Derived/InfoPlists/iFly-Info.plist`, which the next `tuist generate`
  overwrites. See §3.
- **Provenance** (hand-kept xcodeproj): everything persists; the pbxproj diff in the
  working tree is Xcode re-sorting the `C0C0CAFE…` core entries, not capabilities.
- CI re-sign entitlements for iCube's sideload builds live in
  `Source/iOS/App/Project/Entitlements/{Public,Private}.entitlements` and were not
  touched; they must stay minimal (re-signing under another team strips iCloud,
  app groups, keychain groups, EVA, increased memory, NFC, associated domains).

### Owner's uncommitted edits (not committed by this session)

| Repo / file | What changed | Notes |
|---|---|---|
| Provenance `Provenance-AppStore.entitlements` | iFly + iCube iCloud containers added to both container lists; `com.joemattiello.shared` already in `keychain-access-groups` | A comment about the cross-app purchase bridge was dropped; the bridge itself (`CrossAppEntitlementPublisher`) is unchanged. |
| Provenance `Provenance-AppStore-Info.plist` | RetroAchievements ATS exceptions, GameKit friend-list text, motion text | Contains a leftover **`New Exception Domain`** placeholder entry: remove before commit. ATS already has `NSAllowsArbitraryLoads`, so the exception entries are redundant there. |
| iCube both entitlements | `aps-environment` + `com.apple.developer.aps-environment` (push), `sustained-execution`, keychain group `com.joemattiello.shared`; AppStore file: all three iCloud containers + CloudKit + CloudDocuments + ubiquity containers + KVS id; debug file: **empty** `icloud-container-identifiers` | iCube has no push code, and `com.apple.developer.aps-environment` is the macOS key. The staged patch (`docs/cloudkit-entitlements.patch`) deliberately used CloudKit only, no ubiquity container, and the same container in both files. The empty array in the debug file leaves dev builds inert. iCube's entitlements do **not** list `group.org.provenance-emu.provenance` yet (iFly's do). |
| iFly `iFly.entitlements` | iCube + Provenance iCloud containers, `group.org.provenance-emu.provenance` app group | Persists. |
| iFly `Derived/InfoPlists/iFly-Info.plist` | RetroAchievements ATS exceptions, `NSMotionUsageDescription` (headphone motion) | **Lost on regenerate.** iFly has no RetroAchievements and no head-pose code; decide whether to keep either before moving them to `sharedInfoPlist`. |

## 2. What each capability is, and whether we want it

P = Provenance, C = iCube, F = iFly. "Profile" = must be on the App ID.

| Item | What / key | Verdict |
|---|---|---|
| Camera | `NSCameraUsageDescription`, no entitlement | MAYBE LATER everywhere (QR pairing / invite scan). Drop the string until a feature uses it. |
| Location | `NSLocation*UsageDescription`; Wi-Fi SSID needs `networking.wifi-info` | NO. LAN features need only `NSLocalNetworkUsageDescription` + `NSBonjourServices`. Provenance's `personal-information.location` entitlement and strings are dead weight. |
| Background audio / AirPlay / PiP | `UIBackgroundModes: audio`, plist only | NO. Emulators pause in background; "audio" without real background playback is a known rejection, and a backgrounded core hits the Metal `nextDrawable` deadlock. PiP of the game view: MAYBE LATER (iOS only). |
| GameKit | `com.apple.developer.game-center` (Profile) + friend-list text | P: USE NOW for `GKMatch` invites into PVNetplay. C/F: MAYBE LATER. Degrade when re-signed. |
| Sustained execution | `com.apple.developer.sustained-execution` (Profile), iOS 17+, **not tvOS** | USE NOW on all three (thermal throttling is the adaptive-clock problem). A/B with the ABBA method. |
| App Attest (+ opt-in) | `devicecheck.appattest-environment` (Profile) | NO. Needs a server verifier; signing the sibling apps changes nothing. The "opt-in" key is macOS 27 only (NV). |
| App Identifier for OS Data Transfer | App Store Connect setting for Android → iOS migration (AppMigrationKit, iOS 26.3+) | NO. No Android twins. |
| Background GPU access | `background-tasks.continued-processing.gpu` (Profile), iOS 26+ | NO now. MAYBE LATER for finite jobs (shader pre-compile, conversion), not for running a core. |
| Background inference | `background-tasks.continued-processing.inference`, OS 27+ | NO. No ML. |
| Associated domains | `com.apple.developer.associated-domains` (Profile) + AASA file | USE NOW on all three: universal links `https://<domain>/<app>/play?id=…` are what NFC tags and shared links boot. Not needed for skin downloads or RetroAchievements. One AASA can list all three app IDs. |
| Custom network protocol | Key not found in Apple docs | NO. `NWProtocolFramer` needs no entitlement. |
| Extended Virtual Addressing | `kernel.extended-virtual-addressing` (Profile), iOS+tvOS | USE NOW; all three App IDs have it and all three entitlements files request it. |
| Family Controls / App & Website Usage | Screen Time APIs (Profile, Apple approval) | NO. Cannot rate content. For age gating use **Declared Age Range** (`declared-age-range`, iOS 26+, not tvOS): P MAYBE LATER, C/F NO. |
| FileProvider testing mode | `fileprovider.testing-mode` (Profile, development only) | NO in shipping configs; Apple rejects uploads with it. Provenance has it on the App ID: keep it out of the AppStore entitlements. Sharing one provider across apps is not a thing; each app embeds its own over the group container (C/F MAYBE LATER). |
| Fonts | `user-fonts` (Profile) is for font-provider apps | NO on all three; ITMS-90807/90793 if enabled without installable fonts. Bundled UI fonts need `UIAppFonts` per bundle (extensions too) or runtime `CTFontManagerRegisterFontsForURL` for package resources. Provenance's `Provenance.entitlements` (dev) carries `user-fonts`; the AppStore one does not. |
| FSKit | macOS 15.4+ filesystem modules | NO. |
| Head pose | `coremotion.head-pose` (Profile), head-tracked spatial audio | NO. Retro stereo should not be head-locked. |
| Group Activities (SharePlay) | `group-session` (Profile), iOS+tvOS | MAYBE LATER as a netplay rendezvous over FaceTime (metadata only, each side owns its ROM). |
| Mac Catalyst | App ID platform, needs sandbox + `cs.allow-jit` | C/F MAYBE LATER (a Mac build gets a real JIT). P: NO, native macOS is the plan. |
| Wi-Fi Aware | `wifi-aware` (Profile), iOS 26+ | MAYBE LATER (router-less LAN continuity / netplay). |
| Wi-Fi network sharing | `wifi-infrastructure`, accessory Wi-Fi provisioning | NO. |
| Tap to Share | No such entitlement; the page is Tap to Pay | NO. |
| Suggested actions | Messaging apps, OS 27 | NO. |
| Spatial audio profile | `spatial-audio.profile-access` (Profile), iOS/tvOS 18+ | NO (C MAYBE LATER if DPL II is ever rendered through a spatial mixer). iFly has it on its App ID for no code reason. Also: iOS/tvOS 18 spatialize game audio by default; opt out with `AVGameBypassSystemSpatialAudio` if it colours retro output. |
| Siri | `com.apple.developer.siri` (Profile), SiriKit extensions | NO. App Intents / App Shortcuts do not need it (NV). Provenance's dev entitlements and iFly's App ID have it idle. |
| Side button access | Japan-only voice-assistant launch, iOS 26.2 | NO. |
| Shared with You | Messages link surfacing (Profile) + associated domains | P MAYBE LATER for skin/shader links. Never for ROMs (copyright rejection risk). |
| Personal VPN | `networking.vpn.api` (Profile), strict review | NO. |
| NFC tag reader | `nfc.readersession.formats: [NDEF]` (Profile) + `NFCReaderUsageDescription`, iPhone only | USE NOW for the owner's idea, on all three: the in-app "write tag" needs the entitlement; tap-to-boot is a universal link on the tag, which needs associated domains, not NFC. Only one app can claim a URL path, so the AASA decides which app opens `/icube/...`. |
| Nearby Interaction | UWB, plist usage string only | NO. |
| Multipath | `networking.multipath` (Profile), iOS only | NO. Netplay is LAN; relays rarely speak MPTCP. |
| Managed App Installation UI | MDM vendors only | NO. A Mac sideloader needs nothing from Apple here. |
| Low latency streaming / LL-HLS | visionOS-only key; LL-HLS needs no entitlement | NO. HLS latency is unplayable. |
| Journaling suggestions | Import picker only (Profile) | NO. No API writes game sessions into Journal. |
| Increased memory limit (+debugging) | `kernel.increased-memory-limit` (Profile), iOS only | USE NOW on C and P (both have it), F MAYBE. The debugging variant is development-only. |
| iCloud Extended Share Access | `icloud-extended-share-access`, OS 26+ | NO unless a custom CloudKit sharing UI exists. |
| Keychain sharing | `keychain-access-groups: $(AppIdentifierPrefix)com.joemattiello.shared` | USE NOW. Already in all three. This is the group the Provenance ↔ iFly purchase bridge uses; iCube can now join it (see §4). |
| Shared app group | `com.apple.security.application-groups` | USE NOW for a shared library index and handoff markers. Use `NSFileCoordinator` and never open one Realm/SQLite from two apps. iCube still needs the group in its entitlements files. |
| Shared iCloud containers | All three containers in all three apps | Works (same private DB, zones, records), but production schema is additive-only and shared: a field type chosen by one app binds the others, and every app must tolerate unknown record types. Give push subscriptions distinct IDs per app. Unless an app reads another's records, listing the sibling containers buys nothing and widens the blast radius; CloudDocuments (ubiquity) is a separate feature iCube and iFly do not use. |

## 3. Changes ready to make on request (no decisions needed)

1. **iFly `Project.swift`:** move whatever survives of the generated-plist edits into
   `sharedInfoPlist` (ATS exception domains, `NSMotionUsageDescription`), or drop them.
2. **iCube CloudKit, finish:** with iCloud now on all eight shipping App IDs, apply the
   staged patch's intent to the four entitlements files (CloudKit + the iCube container
   in both app files and both CI re-sign files), set
   `CloudKitAvailability.containerIsProvisioned = true`, then create the schema from a
   device run and promote it (`ck_schema_promote` in `asc.sh`). One device build to
   verify "Up to date".
3. **iCube app group:** add `group.org.provenance-emu.provenance` to both iCube
   entitlements files (the App ID has App Groups; the portal assignment is the
   owner's to confirm).
4. **Provenance plist:** delete the `New Exception Domain` placeholder.

## 4. Decisions for the owner

- Keep or drop on iCube: push notifications (`aps-environment`; no code uses it),
  CloudDocuments + ubiquity containers (patch said CloudKit only), the sibling apps'
  iCloud containers (no code reads them).
- Keep or drop on iFly: the RetroAchievements ATS exceptions and the headphone-motion
  string (no code behind either), and the idle App ID capabilities (Siri, Spatial Audio
  Profile, Network Slicing).
- Provenance App ID carries many capabilities with no code behind them (App Attest,
  DriverKit, Hotspot, Journaling, Multipath, System Extension, User Management,
  FileProvider testing mode). Harmless on the App ID, but none should enter the
  AppStore entitlements file.
- Confirm the plain `group.org.provenance-emu.provenance` exists in the portal.
- Shared purchase for a future iCube Plus: the bridge already exists in Provenance
  (`CrossAppEntitlementPublisher`, keychain service
  `com.joemattiello.shared.entitlements`, accounts `provenance.plus` / `ifly.pro`).
  iCube joining means a reader/publisher pair and a new account name; decide whether
  iCube Plus is its own product or unlocked by either sibling.
- Associated domains + NFC are the two "USE NOW" items that need a domain decision
  (one AASA serving all three apps, path per app) before any code.
