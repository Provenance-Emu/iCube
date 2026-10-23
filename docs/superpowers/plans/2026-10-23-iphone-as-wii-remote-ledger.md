# iPhone as Wii Remote: build ledger

The subagent-driven build of [the plan](2026-10-23-iphone-as-wii-remote.md), kept for its rulings and the
minor findings that were deferred. Merged into develop as 05e9eab973. Nothing here is device-verified.

## Ledger

# SDD ledger — plan: docs/superpowers/plans/2026-10-23-iphone-as-wii-remote.md

Branch feature/iphone-wii-remote from develop d0f8f9cfcb (develop is 3 docs commits ahead of origin, unpushed).
Spec: docs/superpowers/specs/2026-10-22-iphone-as-wii-remote-design.md (owner decisions 2026-10-23).

## Pre-flight scan

| Pair / task | Produces vs consumes | Finding |
|---|---|---|
| T2 x T4 | both edit DSUServerBridge.mm publishBonjour (name vs TXT identity) | compatible; T4 must keep T2's name lookup |
| T4 -> T5, T7 | DSUAdvert(pid,name,deviceType,isController), txtRecord/parse | consistent |
| T5 -> T6 | PhoneControllerConnector.actions, DSUEntry, PhoneConnectorState | consistent |
| T6 -> T9 | PhoneControllerService.advertisingPhones, connect(pid:) | connect semantics unstated -> Ruling 1 |
| T3 x T7 | both touch DSUControllerView (lifecycle vs presenting) | compatible |
| T2 | ContinuityBrowseModelBuilder.make signature change | callers: ContinuityBrowseView + ContinuityModelBuildersTests must be updated in T2 |
| T9 | NoControllerNotice.model signature change | EmulationScreen call site + NoControllerNoticeTests updated in T9 |
| T1 | iOS unit test covers iOS plist only | tvOS plist checked by PlistBuddy step; agrees with itself |
| T6 | toast posted from TVRootView context | EmulationToast may not render outside the game -> Ruling 2 |
| T8 | new Kind raw value | must not reorder/rename existing raw values (test pins it) |
| T3,T4,T5,T7,T10 | self-consistency | tests match signatures; agree |

Ruling: T9's "Use <phone>" row and T6 connect(pid:) count as the TV-side confirmation (the user just picked that phone on the TV), so connect(pid:) marks the pid confirmed and adds it without a second prompt — the explicit tap is the confirm the trust model asks for — if wrong, one extra prompt is missing for a phone the user explicitly chose.
Ruling: T6's "connected" feedback uses EmulationToast when a game is running and an in-library banner/toast otherwise (implementer picks the existing library notice surface) — EmulationToast only renders over the game — if wrong, the confirmation is silent in the library but the hub's Phones section still shows Connected.
Task 1: dispatched (BASE d0f8f9cfcb, implementer a9a9b6e72111c0e6d, sonnet)
Task 1: complete (commits d0f8f9cfcb..a8e95be972, review clean)
Task 1: minor (deferred): tvOS Info-TV.plist has no automated regression test (iOS test reads Bundle.main only); verified by PlistBuddy and by the diff
Task 2: dispatched (BASE a8e95be972, implementer a61c7a18907f30295, sonnet)
Task 2: complete (commits a8e95be972..ddc0cafb7d, review clean)
Task 2: minor (deferred): Continuity identity/sourceDevice capture the name at launch, so a rename reaches other devices' Continuity view only after relaunch (DSU advert picks it up at next publish)
Task 2: minor (deferred): Bonjour service name not bounded to 63 UTF-8 bytes for multi-byte names (DSUServerBridge.publishBonjour) — carried into Task 4, which edits the same function
Task 2: minor (deferred): Core.strings keys not in alphabetical position; no RED run captured
Task 3: dispatched (BASE ddc0cafb7d, implementer ae1d107d0ba65e91b, sonnet)
Task 3: review -> Needs fixes (Important: idle timer bypasses KeepAwake ref-count; Important, plan-mandated: background stop leaves DSUSessionView's Start Server toggle stale)
Ruling: keep the unconditional background stop (spec bug 3: no silent half-stream) and treat DSUSessionView as an open session too — it applies DSUSessionLifecycle on scene changes, restarting its server on return when its toggle is on and refreshing `running` from DSUServerBridge.isRunning() — the toggle the user set is what the screen promises — if wrong, a server the user left on restarts on return while the session form is visible, which matches its toggle.
Task 3: minor (deferred): test_onlyTheThreeRulesProduceAnAction duplicates the three rule tests; a failed restart snackbar repeats on every .active
Task 3: fix round 1/5 (2 addressed, 0 open; commits 5033ec21b2..1f0b52b509)
Task 3: minor (deferred): DSUSessionView ip/QR can stay stale after background if the controller view restarted the server first and the LAN address changed
Task 3: complete (commits ddc0cafb7d..1f0b52b509, review clean)
Task 4: note for dispatch — carry Task 2's deferred minor: bound the Bonjour service name to 63 UTF-8 bytes in DSUServerBridge.publishBonjour
Task 4: dispatched (BASE 1f0b52b509, implementer a87452b0ec5107959, sonnet)
Task 7: note for dispatch — setIdentity: replaces identity keys as a set; call it without role when the phone leaves the controller screen (from Task 4 report)
Task 4: complete (commits 1f0b52b509..b6172e5f51, review clean)
Task 4: minor (deferred): TXT values over 255 bytes make dataFromTXTRecordDictionary return nil and wipe the TXT (name not byte-capped); first character over 63 bytes yields an empty service name; emoji test hard-codes 15; no parse test for missing dt; possible unused block-parameter warnings
Task 5: dispatched (BASE b6172e5f51, implementer a27b7b1098413cc46, sonnet)
Ruling: Task 5 departure rule — an owned pid counts as departed when absent from servers and now - lastSeen > departureGrace, and a pid with no lastSeen entry counts as departed immediately — the brief left lastSeen ownership open and the caller (Task 6) maintains it — if wrong, a phone whose lastSeen was never recorded loses its entry at once instead of after 10 s.
Task 6: note for dispatch — connector .prompt repeats every call until pid is confirmed/declined: executor must track an in-flight prompt (prompt once); prune owned[pid] when its entry no longer exists in entries (user deleted it); removes come last in descending index order (apply in order)
Task 5: complete (commits b6172e5f51..5e2cebfcb2, review clean)
Ruling: persisted owned DSU entries must not reconnect before re-confirmation — Task 6's service removes every owned entry from DSUClient.ini when it starts (each TV launch) and removes a pid's owned entry when the user answers "Not Now" — trust model (a): nothing connects silently; owned persists only so a crash-left entry can be cleaned up — if wrong, a paired phone needs one TV confirm per launch, which is what the owner chose.
Task 5: minor (deferred): owned lookup by description can hit a same-named manual entry; no test for descending remove order or the exact 10.0 s boundary; TXT read once at resolve (role change needs re-resolve); empty service names fall back to "DSU" and can replace each other
Task 6: dispatched (BASE 5e2cebfcb2, implementer ac8bbe3fd6fa6f2d3, opus — integration + trust model)
Task 6: implemented 4d909b7f0f (DONE_WITH_CONCERNS: no device check; removed .disabled from root after it broke covers; panel focus may leak to the library behind; prompt raised under a cover gets no focus; deleting a phone row in DSU settings marks it declined for the launch); review dispatched (opus)
Task 6: review -> Needs fixes (Important: a waiting phone is stranded when the pending phone stops advertising)
Ruling: keep the implementer's "a phone whose owned row disappears (user deleted it) counts as declined for this launch" — otherwise the connector re-adds it behind the user's back; connect(pid:) still brings it back — if wrong, a row lost to a failed bridge write also declines that phone until relaunch (see deferred minor).
Ruling: keep "Not Now" before "Allow" on tvOS (default focus lands on the safe answer) — trust model (a) favours an explicit Allow — if wrong, one extra d-pad press to allow.
Task 6: minor (deferred): iOS alert set: closure reads live pendingPrompt pid (latent; start() is tvOS-only); a failed re-add in update reads as a user deletion and declines the phone; owned matched by description only (cleanup could hit a same-named manual row); DSU client stays enabled after the last phone leaves; start()/stop() lifecycle untested; prompt over a running game and focus escape unchecked on device
Task 6: fix round 1/5 (1 addressed, 0 open; commits 4d909b7f0f..8dcfaa5c7f)
Task 6: complete (commits 5e2cebfcb2..8dcfaa5c7f, review clean)
Task 7: dispatched (BASE 8dcfaa5c7f, implementer ae3f305e0c87e5923, sonnet; notes: drop role + restore approval on leaving; pid = Continuity identity id)
Task 7: implemented 690ea55be6 (DONE_WITH_CONCERNS: fullScreenCover may not present over a sheet; intent opens its own URL; end() also restores layout/pointer/restriction; begin() untested; approval prompt shows TV ip:port); review dispatched (opus)
Task 7: review -> Needs fixes (Important: same TV never re-prompted in a run; killed app leaves session allowance/layout/pointer/approval persisted; session stuck active if the cover cannot present)
Ruling: the overwritten/absent TV restriction (reviewer Minor) is raised to Important — trust model (a) requires the session to answer only the approved TV — if wrong, a cheap re-assert of the restriction was added that a minor would not have required.
Ruling: fix shape for Task 7 — clear the bridge's once-per-IP prompt memory at begin() and end(); keep the session's TV allowance in memory only (not in dsu_allowed_clients); persist the pre-session snapshot (approval, layout, pointer mode) and restore it at the next launch if end() never ran; mark the session active from the cover's onAppear so a refused presentation does not wedge it — smallest changes that keep trust model (a) across crashes — if wrong, a session TV must be re-approved after an app restart, which the trust model wants anyway.
Ruling: the iOS "Play on Apple TV" toolbar control stays icon-only with the text as its accessibility label, matching the other library toolbar icons — the plan said "visible button", the toolbar convention is icons — if wrong, a one-line label change.
Task 7: minor (deferred): second-TV approval replaces the first in allowedBySession; end() leaves a begun server running and the layout TXT stale until the controller view reappears; test tearDown overwrites host DSU settings; begin() untested; DSUSessionView approval observer coexistence unchecked
Task 7: fix round 1 implemented e9877757c7 (session-only allowance, snapshot restore at launch, cover-onAppear activation, session restriction re-assert); no RED for the round; pointer mode still global mid-session; re-review dispatched (opus)
Task 7: fix round 1/5 (4 addressed, 0 open; commits 690ea55be6..e9877757c7)
Task 7: minor (deferred): an earlier begin()'s 3 s timeout can drop a quick re-tap; the controller's Target menu still writes the persisted restriction mid-session; ending a session re-arms prompts for receivers blocked before it; didAppear hard-codes Presentation.shared; one pendingAddress means a second TV's prompt overwrites the first
Task 7: complete (commits 8dcfaa5c7f..e9877757c7, review clean)
Task 8: dispatched (BASE e9877757c7, implementer a005b13f9bb106526, sonnet)
Task 8: complete (commits e9877757c7..8ff77cd004, review clean)
Task 8: minor (deferred -> carried into Task 9): stale tvOS "Automatic picks the controller's gyro, then its touchpad, then the Siri Remote." help line at PointerSource.swift ~239 should mention the phone
Task 8: minor (deferred): long doc-comment line ~128; "below a pad gyro" half of a test is vacuous; (.ios, .phone) branch untested; bare "DSUClient/" names the phone "DSUClient"
Task 9: dispatched (BASE 8ff77cd004, implementer a8f3161cc9640a9fd, sonnet; includes Task 8's stale help-line fix)
Task 9: ⚠️ resolved — hub Phones section is platform-independent and absent on iOS because iOS never browses; the plan said "tvOS and iOS host", so this matches
Task 9: complete (commits 8ff77cd004..d17f708225, review clean)
Task 9: minor (deferred): isConnected(pid:) untested; badge reads owned loaded before start() cleanup (doc comment overstates); notice offers only the first phone and the help panel doesn't refresh when a phone appears; phoneChanges->reload subscription untested
Final review: dispatched (opus) over d0f8f9cfcb..HEAD
Final review: ready with fixes — Important: (1) end() never stops the server and the TV reads TXT once, so Done leaves the phone seated and a re-tap is invisible; (2) a phone already added by hand gets a second row and seats twice; (3) scenePhase never used before in this UIHostingController app, must be verified in the simulator or replaced by app notifications
Ruling: the final fix wave also takes two minors — capture the phone pid in the notice row's action (TV half of trust model a) and say "waiting for <phone>" instead of "connected" until the phone has approved — both are cheap and change what the user is told — if wrong, two extra small diffs.
Final review: fix wave dispatched (opus) from d17f708225
Final review: fix wave interrupted by app restart after commits eca1ca4a39, d05484adeb, 2d887df9ed (DSUDiscovery.swift uncommitted); fixer a0977c73439918d6e resumed to finish
Final review: fix wave commits d17f708225..d21e0e9879 (4); scoped re-review + full suite dispatched
Final review: fix wave re-review — all 5 findings addressed, no new Critical/Important
Final review: parked — two lifecycle handlers on the manual DSU screen (foreground order undefined; stale IP label at most) — Ruling: acceptable, manual flow only — if wrong, the IP label is stale until the screen reappears.
Final review: parked — .update re-records owned by description+port only — Ruling: contrived (needs a same-named manual row at another address after ours) — if wrong, a user row could be removed after a phone IP change.
Final review: parked — NetService resolve-after-TXT-update and monitor survival unverified on hardware — Ruling: only the user-started-server path depends on it; the one-tap path re-publishes on restart — device-test item.
Final review: parked — a failed restart in didAppear falls back to a configured-port start that end() won't stop — Ruling: rare failure path — if wrong, the server stays up after Done until backgrounded.


## Final review findings

# Final-review findings to fix (one fix wave)

Branch feature/iphone-wii-remote, head d17f708225. Paths under Source/iOS/App/Common/.

## Important 1 — leaving the session never disconnects the phone; a re-tap can be invisible to the TV
- `PhoneControllerSession.end()` (Swift/DSU/PhoneControllerSession.swift ~125-141) never calls `DSUServerBridge.stop()`; `DSUControllerView.onDisappear` (Swift/Widgets/DSUControllerView.swift ~161-171) stops motion only; the TV reads the TXT once at resolve (UI/Settings/SwiftUI/DSUDiscovery.swift ~101), no `startMonitoring()` / `netService(_:didUpdateTXTRecord:)`.
- Result: after Done the phone keeps sending frozen state, keeps Wii Remote 1, suppresses the no-controller notice, and is an open server the user didn't start; a second "Play on Apple TV" while the server is still running only updates the TXT, which the TV never re-reads.
- Required: `end()` stops the server when the session started it (record whether a server was already running in the snapshot; leave/restart a user-started server as it was). `didAppear()` restarts an already-running server so the TV re-resolves a record with the role. The TV monitors TXT updates (`startMonitoring()` + `netService(_:didUpdateTXTRecord:)` updating the server's advert, so a role change or IP change reaches the connector). Tests at the decision/state level (session start/stop decisions; discovery advert update path if seamable).

## Important 2 — a phone the owner already added by hand gets a second row and seats twice
- Manual "Add" names the row after the Bonjour name (e.g. `Joe's iPhone:ip:26760`); one-tap adds `Joe's iPhone (2)` at the same ip:port (PhoneControllerConnector.swift ~59-65); `addDsuServer` doesn't catch it (DOLConfigBridge.mm ~1730-1744); the core makes one device per row, so the engine seats the phone on Wii Remote 1 and 2.
- Required: the connector skips `.add` when an existing row already targets the advertised address and port (leave that row untouched, treat the phone as present); owned rows are matched by (description, address, port), not description only, everywhere (connector update/remove and the service's launch cleanup / ownedIndex). Tests: manual row at same ip:port → no add, no prompt-driven duplicate; owned-match ignores a same-named manual row at a different address.

## Important 3 — scenePhase has never been used in this UIHostingController-rooted app
- Root is a UIHostingController (MainDisplaySceneDelegate.swift ~26), not a SwiftUI App; three places now depend on `@Environment(\.scenePhase)`: DSUControllerView (~285, ~313), DSUSessionView (~236), TVRootView (~92, `initial: true`).
- Required: verify in the simulator (iOS: background/foreground with the DSU controller open and the server running — server stops and restarts; tvOS: the phone service starts at launch and restarts on return), recording the evidence (log lines) in the report. If scenePhase does not propagate, switch those three to the UIApplication didEnterBackground / willEnterForeground (or didBecomeActive) notifications that EmulationScreen and RecordingManager already use.

## Minor (included by controller ruling)
- EmulationScreen.swift ~583-589 connects `advertisingPhones.first` at tap time while the title came from `.first` at render time: capture the shown phone's pid in the row's action.
- PhoneControllerService.swift ~207 toast "%@ is connected as a controller" and the hub "Connected" badge appear before the phone approves: change the toast to "Waiting for %@ to allow this Apple TV" (add the Core.strings key; remove the old key if unused) and keep the hub badge but label it "Added" instead of "Connected" (key swap), so nothing claims a connection that hasn't happened.
