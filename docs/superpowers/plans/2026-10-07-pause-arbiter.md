# PauseArbiter Implementation Plan (PR 1 of the unified menu UX)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One refcounted owner of the core's pause state, so opening or closing any sub-sheet or pane of the pause menu can never resume the game underneath it.

**Architecture:** A `@MainActor` `PauseArbiter` singleton hands out claim tokens; the core is paused on the first claim and resumed on the last release (deferred one main-queue turn so a release-then-claim inside one SwiftUI transition never resumes). Every presentation claims through a `.pauseClaim("reason")` view modifier. All `TVEmulationBridge.pause()` / `.resume()` calls in the Swift UI layer move into the arbiter; a source-scanning test keeps them there.

**Tech Stack:** Swift 5, SwiftUI, XCTest in the `iCubeTests` target (iOS simulator only, run with `make test`), Tuist-generated project.

**Spec:** `docs/superpowers/specs/2026-10-07-unified-menu-ux-design.md` §1 (pause leak), §4.3, §8, §9, §10 item 1.

## Global Constraints

- Minimum targets iOS 17 / tvOS 17; no availability guards for anything older.
- Every changed Swift file must compile for iOS **and** tvOS. `TVEmulationBridge`, `ControllerManager`, `PauseGestureTracker` are shared by both.
- Conventional commits, subject < 72 chars, no LLM attribution trailers (per the owner's memory rule; the harness trailer is stripped at merge).
- New test files are picked up by the `DolphiniOSTests/**/*.swift` glob but the Xcode project must be regenerated: run `cd Source/iOS/App && tuist generate --no-open` after adding a test file, or the test silently does not exist.
- Run tests with `cd Source/iOS/App && make test DEST="platform=iOS Simulator,name=iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/<ClassName>"`. A full `make test` takes several minutes; use `-only-testing` while iterating.
- tvOS compile check: `cd Source/iOS/App && xcodebuild build -workspace iCube.xcworkspace -scheme "iCube-tvOS (NJB)" -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-tvos 2>&1 | tail -20` (scheme name: confirm with `xcodebuild -list -workspace iCube.xcworkspace`).
- Work in a worktree on branch `fix/pause-arbiter` created from `develop`. After `git worktree add`, run `git config --worktree core.worktree <absolute worktree path>` and confirm `git rev-parse --show-toplevel` prints the worktree path (submodule worktree trap). DO NOT git reset / rebase / push / touch develop.
- Paths below are relative to `Source/iOS/App/` unless they start with `docs/`.

## File map

| File | Responsibility |
|---|---|
| Create `Common/Swift/PauseArbiter.swift` | The arbiter, its `Core` seam, the `.pauseClaim` modifier, the observer install. |
| Create `DolphiniOSTests/PauseArbiterTests.swift` | Unit tests with a fake core and a manual scheduler. |
| Create `DolphiniOSTests/UILayerPauseCallsTests.swift` | Source scan: no bridge pause/resume outside the arbiter. |
| Modify `Common/Swift/Controllers/PauseGestureTracker.swift:187` | Pending claim instead of a raw pause. |
| Modify `Common/Swift/PauseMenuView.swift` (lines 68, 129, 188-210, 243-280, 697, 1324, 1346) | Adopt the pending token, claim per sheet, resume through the arbiter. |
| Modify `Common/Swift/EmulationScreen.swift` (lines 277, 415-419, 533-536, 732-734, 795-799, 1330-1331, 1403, 1483, 1495, 1525-1529) | PausedPill, exit command, settings cover, controller-settings sheet, layout edit. |
| Modify `Common/Swift/TopBar/EmulationTopBar.swift:577-588` | Bar pause = a `"user"` claim. |
| Modify `Common/Swift/TopBar/TopBarConstants.swift:80-100` | Delete `PauseOwnership`. |
| Modify `Common/Swift/Controllers/ControllerManager.swift:151, 200, 239` | Disconnect pause = a `"disconnect"` claim. |
| Modify `Common/AppDelegate.swift:32` | Install the arbiter's start/stop observers. |
| Modify `DolphiniOSTests/TopBarHandoffTests.swift:108-131` | Delete the three `PauseOwnership` tests. |

---

### Task 1: PauseArbiter core with tests

**Files:**
- Create: `Common/Swift/PauseArbiter.swift`
- Create: `DolphiniOSTests/PauseArbiterTests.swift`

**Interfaces:**
- Produces:
  ```swift
  @MainActor final class PauseArbiter {
    struct Token: Hashable { let id: UUID; let reason: String }
    struct Core {
      var isRunning: () -> Bool
      var isPaused: () -> Bool
      var pause: () -> Void
      var resume: () -> Void
      static let bridge: Core
    }
    static let shared: PauseArbiter
    init(core: Core, schedule: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) })
    var isHeld: Bool
    var holders: [String]
    @discardableResult func claim(_ reason: String) -> Token
    func release(_ token: Token)
    func release(reason: String)
    func userResume()                 // releases "user" and "disconnect" tokens
    func resumeIfUnheld()             // PausedPill: nothing held, core paused by someone else → resume
    func claimPending(_ reason: String)
    func adoptPending() -> Token?
    func emulationDidStart()
    func emulationDidStop()
    func installObservers()
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// DolphiniOSTests/PauseArbiterTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// `PauseArbiter` against a fake core and a manual scheduler: the deferred resume runs only when the
/// test says so, which is what lets a release-then-claim within one transition be asserted.
@MainActor
final class PauseArbiterTests: XCTestCase {
  private final class FakeCore {
    var running = true
    var paused = false
    var pauseCalls = 0
    var resumeCalls = 0
    var core: PauseArbiter.Core {
      PauseArbiter.Core(
        isRunning: { self.running }, isPaused: { self.paused },
        pause: { self.pauseCalls += 1; self.paused = true },
        resume: { self.resumeCalls += 1; self.paused = false })
    }
  }

  private var fake = FakeCore()
  private var scheduled: [() -> Void] = []
  private var arbiter: PauseArbiter!

  override func setUp() {
    super.setUp()
    fake = FakeCore()
    scheduled = []
    arbiter = PauseArbiter(core: fake.core, schedule: { self.scheduled.append($0) })
  }

  private func runScheduled() {
    let work = scheduled
    scheduled = []
    work.forEach { $0() }
  }

  func test_firstClaimPauses_nestedClaimDoesNot() {
    let a = arbiter.claim("menu")
    XCTAssertEqual(fake.pauseCalls, 1)
    let b = arbiter.claim("saves")
    XCTAssertEqual(fake.pauseCalls, 1, "a nested claim must not pause again")
    XCTAssertEqual(arbiter.holders, ["menu", "saves"])
    arbiter.release(b)
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 0, "an inner release keeps the game paused")
    arbiter.release(a)
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 1)
    XCTAssertFalse(arbiter.isHeld)
  }

  func test_outOfOrderRelease_resumesOnlyWhenEmpty() {
    let a = arbiter.claim("menu")
    let b = arbiter.claim("cheats")
    arbiter.release(a)
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 0)
    arbiter.release(b)
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 1)
  }

  func test_doubleRelease_isNoOp() {
    let a = arbiter.claim("menu")
    arbiter.release(a)
    arbiter.release(a)
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 1)
  }

  func test_releaseThenClaimInSameTurn_doesNotResume() {
    let root = arbiter.claim("menu")
    arbiter.release(root)                 // SwiftUI onDisappear of the covered presenter
    _ = arbiter.claim("shaders")          // the cover's onAppear, same transition
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 0, "the deferred resume must re-check the token count")
    XCTAssertTrue(fake.paused)
  }

  func test_userPause_survivesMenuClose_andUserResumeClearsIt() {
    arbiter.claim("user")
    let menu = arbiter.claim("menu")
    arbiter.release(menu)
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 0, "the bar pause outlives the menu")
    XCTAssertTrue(arbiter.isHeld)
    arbiter.userResume()
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 1)
    XCTAssertFalse(arbiter.isHeld)
  }

  func test_releaseByReason_removesEveryTokenWithThatReason() {
    arbiter.claim("disconnect")
    arbiter.claim("disconnect")
    arbiter.release(reason: "disconnect")
    runScheduled()
    XCTAssertFalse(arbiter.isHeld)
    XCTAssertEqual(fake.resumeCalls, 1)
  }

  func test_externalPause_isNotResumedByArbiter() {
    fake.paused = true                    // paused by the debug API, no token
    let a = arbiter.claim("menu")
    XCTAssertEqual(fake.pauseCalls, 0, "already paused: nothing to do")
    arbiter.release(a)
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 0, "the arbiter never resumes a pause it did not make")
    XCTAssertTrue(fake.paused)
  }

  func test_resumeIfUnheld_resumesExternalPause_butNotAHeldOne() {
    fake.paused = true
    arbiter.resumeIfUnheld()
    XCTAssertEqual(fake.resumeCalls, 1)
    arbiter.claim("menu")
    arbiter.resumeIfUnheld()
    XCTAssertEqual(fake.resumeCalls, 1, "a held pause is not the pill's to resume")
  }

  func test_claimWhileNotRunning_isDeferredUntilStart() {
    fake.running = false
    let a = arbiter.claim("menu")
    XCTAssertEqual(fake.pauseCalls, 0)
    fake.running = true
    arbiter.emulationDidStart()
    XCTAssertEqual(fake.pauseCalls, 1)
    arbiter.release(a)
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 1)
  }

  func test_emulationDidStop_dropsAllTokens() {
    arbiter.claim("menu")
    arbiter.claim("user")
    arbiter.emulationDidStop()
    XCTAssertFalse(arbiter.isHeld)
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 0, "a stopped core is never resumed")
  }

  func test_pendingClaim_isAdoptedOnce_andReplacedByTheNextPending() {
    arbiter.claimPending("pause-menu-request")
    XCTAssertEqual(fake.pauseCalls, 1)
    let adopted = arbiter.adoptPending()
    XCTAssertEqual(adopted?.reason, "pause-menu-request")
    XCTAssertNil(arbiter.adoptPending(), "adopt hands the token over exactly once")
    arbiter.claimPending("again")
    arbiter.claimPending("again-2")
    XCTAssertEqual(arbiter.holders, ["pause-menu-request", "again-2"], "an unadopted pending claim is replaced, not leaked")
  }

  func test_claimWhileHeldButCoreRunning_rePauses() {
    let a = arbiter.claim("menu")
    fake.paused = false                   // something outside resumed under us
    _ = arbiter.claim("saves")
    XCTAssertEqual(fake.pauseCalls, 2, "every claim ensures a running core is paused")
    _ = a
  }
}
```

- [ ] **Step 2: Regenerate the project and run the tests to verify they fail**

Run:
```bash
cd Source/iOS/App && tuist generate --no-open && make test DEST="platform=iOS Simulator,name=iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/PauseArbiterTests" 2>&1 | grep -E "error:|Executed|BUILD" | head
```
Expected: compile error "cannot find 'PauseArbiter' in scope".

- [ ] **Step 3: Write the arbiter**

```swift
// Common/Swift/PauseArbiter.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SwiftUI

/// The one owner of the core's pause state in the UI layer (unified menu UX spec §4.3).
///
/// Every surface that must keep the game paused — the pause menu, each of its panes and sheets, the
/// Settings cover, the controller-settings sheet, the user's bar pause, a controller disconnect — holds
/// a `Token`. The core is paused on the first claim and resumed when the last token goes, and nowhere
/// else: `UILayerPauseCallsTests` fails the build of any other Swift file that calls
/// `TVEmulationBridge.pause()` / `.resume()`.
///
/// Two rules keep the old behaviour that mattered:
/// - A pause the arbiter did not make (the debug API, a core-side stop) is never resumed by it.
/// - The last release resumes one main-queue turn later and re-checks the count, so a covered presenter's
///   `onDisappear` release followed by the cover's `onAppear` claim inside one SwiftUI transition never lets
///   the game run for a frame.
@MainActor
final class PauseArbiter {
  struct Token: Hashable {
    let id: UUID
    let reason: String
  }

  /// The core seam, so tests never touch `TVEmulationBridge`.
  struct Core {
    var isRunning: () -> Bool
    var isPaused: () -> Bool
    var pause: () -> Void
    var resume: () -> Void

    static let bridge = Core(
      isRunning: { TVEmulationBridge.isRunning() },
      isPaused: { TVEmulationBridge.isPaused() },
      pause: { TVEmulationBridge.pause() },
      resume: { TVEmulationBridge.resume() })
  }

  static let shared = PauseArbiter(core: .bridge)

  /// Reasons used by more than one file. A one-off presentation can pass any string.
  enum Reason {
    static let user = "user"
    static let disconnect = "disconnect"
    static let pauseMenu = "pause-menu"
    static let pauseMenuRequest = "pause-menu-request"
  }

  #if DEBUG
  /// A token still held this long after its claim is logged with its reason (spec §8).
  static let leakWarningDelay: TimeInterval = 60
  #endif

  private let core: Core
  private let schedule: (@escaping () -> Void) -> Void
  private var tokens: [Token] = []
  /// True once this object paused the core itself; only then does the last release resume.
  private var ownsPause = false
  /// A claim made while no game was running; applied on `emulationDidStart()`.
  private var deferred = false
  private var pending: Token?
  private var observers: [NSObjectProtocol] = []

  init(core: Core, schedule: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
    self.core = core
    self.schedule = schedule
  }

  var isHeld: Bool { !tokens.isEmpty }
  var holders: [String] { tokens.map(\.reason) }

  @discardableResult
  func claim(_ reason: String) -> Token {
    let token = Token(id: UUID(), reason: reason)
    tokens.append(token)
    if core.isRunning() {
      if !core.isPaused() {
        core.pause()
        ownsPause = true
      }
    } else {
      deferred = true
    }
    #if DEBUG
    let id = token.id
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.leakWarningDelay) { [weak self] in
      guard let self, self.tokens.contains(where: { $0.id == id }) else { return }
      NSLog("[PAUSE] token '%@' still held after %.0fs; holders: %@", reason, Self.leakWarningDelay, self.holders.joined(separator: ", "))
    }
    #endif
    return token
  }

  func release(_ token: Token) {
    guard let index = tokens.firstIndex(of: token) else { return }
    tokens.remove(at: index)
    if pending == token { pending = nil }
    resumeWhenEmpty()
  }

  /// Releases every token claimed with `reason`. For holders that keep no token: the top bar's pause
  /// button and the controller-disconnect pause.
  func release(reason: String) {
    guard tokens.contains(where: { $0.reason == reason }) else { return }
    tokens.removeAll { $0.reason == reason }
    if pending?.reason == reason { pending = nil }
    resumeWhenEmpty()
  }

  /// The pause menu's Resume and the exit command: the user wants the game running, so their own bar
  /// pause and a disconnect pause go too. Presentation tokens are released by their presentations.
  func userResume() {
    tokens.removeAll { $0.reason == Reason.user || $0.reason == Reason.disconnect }
    resumeWhenEmpty()
  }

  /// The PausedPill shows only when no menu is up. If nothing is held and the core is paused, someone
  /// outside this object paused it (the debug API); the pill is the user's way out of that.
  func resumeIfUnheld() {
    guard tokens.isEmpty, core.isRunning(), core.isPaused() else { return }
    core.resume()
    ownsPause = false
  }

  /// A claim made before its presenting surface exists: the gesture tracker pauses the instant Menu
  /// is pressed, and the pause menu appears a few frames later and `adoptPending()`s the token. A
  /// pending claim nobody adopted is released by the next `claimPending`, so a request that never
  /// presented (the menu was already up) cannot leak.
  func claimPending(_ reason: String) {
    if let old = pending { release(old) }
    pending = claim(reason)
  }

  /// Hands the pending token to the caller exactly once; nil when there is none.
  func adoptPending() -> Token? {
    defer { pending = nil }
    return pending
  }

  /// `DOLEmulationDidStartNotification`: apply a deferred claim.
  func emulationDidStart() {
    guard deferred, isHeld else { deferred = false; return }
    deferred = false
    if !core.isPaused() {
      core.pause()
      ownsPause = true
    }
  }

  /// `DOLEmulationDidEndNotification`: nothing can be paused any more. Tokens are dropped; the
  /// presentations that hold them release no-ops later.
  func emulationDidStop() {
    tokens.removeAll()
    pending = nil
    ownsPause = false
    deferred = false
  }

  func installObservers() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: Notification.Name("DOLEmulationDidStartNotification"), object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.emulationDidStart() }
    })
    observers.append(center.addObserver(forName: Notification.Name("DOLEmulationDidEndNotification"), object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.emulationDidStop() }
    })
  }

  private func resumeWhenEmpty() {
    guard tokens.isEmpty else { return }
    schedule { [weak self] in
      guard let self, self.tokens.isEmpty else { return }
      if self.ownsPause, self.core.isRunning(), self.core.isPaused() {
        self.core.resume()
      }
      self.ownsPause = false
      self.deferred = false
    }
  }
}

// MARK: - SwiftUI

private struct PauseClaim: ViewModifier {
  let reason: String
  @State private var token: PauseArbiter.Token?

  func body(content: Content) -> some View {
    content
      .onAppear { if token == nil { token = PauseArbiter.shared.claim(reason) } }
      .onDisappear {
        if let held = token {
          PauseArbiter.shared.release(held)
          token = nil
        }
      }
  }
}

extension View {
  /// Keeps the game paused for as long as this view is on screen. Put it on the CONTENT of every
  /// `.sheet` / `.fullScreenCover` opened over a paused game. A covered presenter releases and re-claims
  /// around its cover; the arbiter's deferred resume absorbs that.
  func pauseClaim(_ reason: String) -> some View {
    modifier(PauseClaim(reason: reason))
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the same command as Step 2.
Expected: `Executed 12 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Common/Swift/PauseArbiter.swift DolphiniOSTests/PauseArbiterTests.swift
git commit -m "feat(pause): PauseArbiter, one refcounted owner of the core pause"
```

---

### Task 2: Source-scan test that pins pause/resume calls inside the arbiter

**Files:**
- Create: `DolphiniOSTests/UILayerPauseCallsTests.swift`

**Interfaces:**
- Consumes: nothing. Reads `Common/Swift/**/*.swift` relative to `#filePath`.

- [ ] **Step 1: Write the failing test**

```swift
// DolphiniOSTests/UILayerPauseCallsTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

/// Spec §4.3: the arbiter owns every `TVEmulationBridge.pause()` / `.resume()` in the Swift UI layer.
/// A new direct call is the bug this PR fixes coming back, so it fails here.
final class UILayerPauseCallsTests: XCTestCase {
  private static let allowed: Set<String> = ["PauseArbiter.swift"]
  private static let patterns = ["TVEmulationBridge.pause()", "TVEmulationBridge.resume()"]

  func test_noDirectBridgePauseOrResumeOutsideArbiter() throws {
    let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let swiftRoot = testsDir.deletingLastPathComponent().appendingPathComponent("Common/Swift")
    let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: swiftRoot, includingPropertiesForKeys: nil))
    var offenders: [String] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
      guard !Self.allowed.contains(url.lastPathComponent) else { continue }
      let text = try String(contentsOf: url, encoding: .utf8)
      for (number, line) in text.components(separatedBy: "\n").enumerated() {
        let code = line.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? line
        if Self.patterns.contains(where: { code.contains($0) }) {
          offenders.append("\(url.lastPathComponent):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
        }
      }
    }
    XCTAssertTrue(offenders.isEmpty, "Pause/resume must go through PauseArbiter:\n" + offenders.joined(separator: "\n"))
  }
}
```

The `split(separator: "/")` strips a trailing `// comment`, so a doc comment that mentions the call does not count.

- [ ] **Step 2: Regenerate and run; verify it fails listing the 17 current call sites**

Run:
```bash
cd Source/iOS/App && tuist generate --no-open && make test DEST="platform=iOS Simulator,name=iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/UILayerPauseCallsTests" 2>&1 | grep -E "swift:[0-9]+:|Executed" | head -30
```
Expected: FAIL, listing `EmulationScreen.swift`, `PauseMenuView.swift`, `EmulationTopBar.swift`, `ControllerManager.swift`, `PauseGestureTracker.swift` lines.

- [ ] **Step 3: Commit the test (red is intended until Task 7)**

```bash
git add DolphiniOSTests/UILayerPauseCallsTests.swift
git commit -m "test(pause): fail on bridge pause/resume outside PauseArbiter"
```

---

### Task 3: Gesture tracker and pause menu adopt the arbiter

**Files:**
- Modify: `Common/Swift/Controllers/PauseGestureTracker.swift:183-188`
- Modify: `Common/Swift/PauseMenuView.swift:68, 125-130, 185-211, 243-280, 695-699, 1323-1324, 1343-1348`

**Interfaces:**
- Consumes: `PauseArbiter.shared.claimPending(_:)`, `.adoptPending()`, `.claim(_:)`, `.release(_:)`, `.userResume()`, `View.pauseClaim(_:)`.

- [ ] **Step 1: Gesture tracker claims a pending token**

In `PauseGestureTracker.requestPauseMenu`, replace
```swift
      TVEmulationBridge.pause()
      NotificationCenter.default.post(name: Notification.Name("DOLShowPauseMenu"), object: nil)
```
with
```swift
      // Pause the instant Menu is pressed; `PauseMenuView.onAppear` adopts this token a few frames later.
      PauseArbiter.shared.claimPending(PauseArbiter.Reason.pauseMenuRequest)
      NotificationCenter.default.post(name: Notification.Name("DOLShowPauseMenu"), object: nil)
```

- [ ] **Step 2: Pause menu holds a token instead of `menuOwnsPause`**

Replace the state at line 68:
```swift
  /// True when opening this menu is what paused the game (see `PauseOwnership`).
  @State private var menuOwnsPause = false
```
with
```swift
  /// This menu's hold on the pause (spec §4.3). Adopted from the gesture tracker's pending claim when
  /// there is one, otherwise claimed here. Released only on a real teardown, see `onDisappear`.
  @State private var pauseToken: PauseArbiter.Token?
```

In `.onAppear` (line 185-189) replace
```swift
      if !menuOwnsPause {
        menuOwnsPause = PauseOwnership.claim(isPaused: TVEmulationBridge.isPaused(), pause: TVEmulationBridge.pause)
      }
```
with
```swift
      // onAppear runs again each time a child sheet closes: keep the token we already hold.
      if pauseToken == nil {
        pauseToken = PauseArbiter.shared.adoptPending() ?? PauseArbiter.shared.claim(PauseArbiter.Reason.pauseMenu)
      }
```

In `.onDisappear` (lines 204-210) replace
```swift
      // Only resume a pause this menu made: a game the user paused from the top bar stays paused.
      let ownedPause = menuOwnsPause
      menuOwnsPause = false
      if TVEmulationBridge.isRunning() && TVEmulationBridge.isPaused() {
        PauseOwnership.release(owned: ownedPause, resume: TVEmulationBridge.resume)
      }
```
with
```swift
      if let token = pauseToken {
        PauseArbiter.shared.release(token)
        pauseToken = nil
      }
```
Keep the `guard !isPauseMenuChildPresented else { return }` above it: SwiftUI reports the covered root as disappeared, and the root must keep its token while a child is up.

- [ ] **Step 3: Every sheet the menu opens claims**

Add `.pauseClaim(...)` to the content of each presentation:
```swift
    .sheet(isPresented: $showShaders) {
      NavigationStack {
        ShaderQuickPickerView()
      }
      .pauseClaim("shaders")
      #if os(tvOS)
      .focusSection()
      #endif
      .claimsController()
    }
    #if os(iOS)
    .sheet(isPresented: $showSettingsSheet) {
      NavigationStack { ... }
      .pauseClaim("settings")
      .claimsController()
    }
    .sheet(isPresented: $showControllersSheet) {
      NavigationStack { ... }
      .pauseClaim("controllers")
      .claimsController()
    }
    #endif
    .sheet(isPresented: $showContinuitySheet) {
      ContinuityHandoffSheet(game: game)
        .pauseClaim("continuity")
        .claimsController()
    }
```
and in `savesMenu` (line ~1304):
```swift
        .sheet(isPresented: $showFilmstripSheet) {
          NavigationStack { SaveStateFilmstripView(gameID: game.gameID) }
            .pauseClaim("filmstrip")
            .claimsController()
        }
```

- [ ] **Step 4: Resume goes through the arbiter**

Four direct resumes become closes or user resumes:

Line 129 (`selectFastForwardSpeed`): replace `TVEmulationBridge.resume()` + `onClose()` with
```swift
    PauseArbiter.shared.userResume()
    onClose()
```
Line 697 (tvOS hero Resume button): `Button(action: { PauseArbiter.shared.userResume(); onClose() })`.
Line 1324: `resume: { PauseArbiter.shared.userResume(); onClose() },`.
Line 1346 (`recenterPointer`): replace `TVEmulationBridge.resume()` with `PauseArbiter.shared.userResume()`.

`userResume` clears the user's bar pause and a disconnect pause; the menu's own token goes in `onDisappear` and the deferred resume then runs.

- [ ] **Step 5: Build both platforms**

Run:
```bash
cd Source/iOS/App && xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-ios 2>&1 | grep -E "error:|BUILD" | head
```
and the tvOS command from Global Constraints. Expected: `BUILD SUCCEEDED` for both.

- [ ] **Step 6: Commit**

```bash
git add Common/Swift/Controllers/PauseGestureTracker.swift Common/Swift/PauseMenuView.swift
git commit -m "fix(pause): pause menu and its sheets hold arbiter tokens"
```

---

### Task 4: EmulationScreen, top bar and controller manager adopt the arbiter

**Files:**
- Modify: `Common/Swift/EmulationScreen.swift:277, 415-419, 533-536, 732-734, 795-799, 1330-1331, 1403, 1483, 1495, 1525-1529`
- Modify: `Common/Swift/TopBar/EmulationTopBar.swift:577-588`
- Modify: `Common/Swift/Controllers/ControllerManager.swift:151, 200, 239`
- Modify: `Common/AppDelegate.swift:32`

- [ ] **Step 1: EmulationScreen**

Line 277: replace `@State private var controllerSettingsOwnsPause = false` with
```swift
  @State private var controllerSettingsToken: PauseArbiter.Token?
```

Both PausedPill sites (tvOS 415-419, iOS 795-799):
```swift
        PausedPill(onResume: {
          PauseArbiter.shared.userResume()
          PauseArbiter.shared.resumeIfUnheld()
          isPaused = false
        })
```

tvOS settings cover (533-536):
```swift
    .fullScreenCover(isPresented: $showSettings) {
      TVSettingsPage()
        .pauseClaim("settings")
        .interactiveDismissDisabled(true)
        .onExitCommand { showSettings = false }
    }
```

tvOS exit command (732-734): the menu's `onDisappear` releases, so
```swift
    .onExitCommand { if showPauseMenu { showPauseMenu = false } }
```

iOS poll (1330-1331): delete `if !isPaused { PauseOwnership.pausedFromBar = false }`; keep `isPaused = TVEmulationBridge.isPaused()`.

Exit confirm "Continue" (1403): delete the `TVEmulationBridge.resume()` line. Nothing paused for that alert; the user's bar pause, if any, is theirs.

Top-bar controller settings (1483):
```swift
    case .controllerSettings:
      controllerSettingsToken = PauseArbiter.shared.claim("controller-settings")
      showControllerSettings = true
```
and `controllerSettingsDismissed()` (1493-1497):
```swift
  private func controllerSettingsDismissed() {
    if let token = controllerSettingsToken {
      PauseArbiter.shared.release(token)
      controllerSettingsToken = nil
    }
    isPaused = TVEmulationBridge.isPaused()
  }
```

`endLayoutEdit()` (1523-1530): the menus closed by `beginLayoutEdit` released their tokens then; a bar pause or disconnect pause still holds. So:
```swift
  private func endLayoutEdit() {
    isEditingLayout = false
    isPaused = TVEmulationBridge.isPaused()
  }
```

- [ ] **Step 2: Top bar pause button**

Replace `togglePause()` (577-588):
```swift
  private func togglePause() {
    if PauseArbiter.shared.holders.contains(PauseArbiter.Reason.user) {
      PauseArbiter.shared.release(reason: PauseArbiter.Reason.user)
    } else {
      // Same as the pause menu: grab the last live frame first so a save made while paused has a thumbnail.
      SaveStateService.capturePausePreview()
      PauseArbiter.shared.claim(PauseArbiter.Reason.user)
    }
    isPaused = TVEmulationBridge.isPaused()
  }
```
`isPaused` reads one turn early after a release (the resume is deferred); the 1 s poll corrects it. If that flicker shows on the icon, read it inside `DispatchQueue.main.async`.

- [ ] **Step 3: Controller manager disconnect pause**

Line 239 (`TVEmulationBridge.pause()` in the disconnect handler) → `PauseArbiter.shared.claim(PauseArbiter.Reason.disconnect)`.
Line 151 (`useTouchControlsForDisconnectedSlot`) and line 200 (reconnect) → `PauseArbiter.shared.release(reason: PauseArbiter.Reason.disconnect)`.

- [ ] **Step 4: Install observers at app start**

`Common/AppDelegate.swift:32`, next to `SaveStateService.installDidStartObserver()`:
```swift
    PauseArbiter.shared.installObservers()
```

- [ ] **Step 5: Build both platforms** (commands as Task 3 Step 5). Expected: both succeed.

- [ ] **Step 6: Commit**

```bash
git add Common/Swift/EmulationScreen.swift Common/Swift/TopBar/EmulationTopBar.swift Common/Swift/Controllers/ControllerManager.swift Common/AppDelegate.swift
git commit -m "fix(pause): screen, top bar and disconnect pause go through the arbiter"
```

---

### Task 5: Delete PauseOwnership and its tests

**Files:**
- Modify: `Common/Swift/TopBar/TopBarConstants.swift:80-100` (delete the `PauseOwnership` enum and its doc comment)
- Modify: `DolphiniOSTests/TopBarHandoffTests.swift:108-131` (delete the three `PauseOwnership` tests)

- [ ] **Step 1: Delete the enum and the three tests**

Remove lines 80-100 of `TopBarConstants.swift` (from `/// Who paused the game.` through the closing brace of `enum PauseOwnership`). Remove `testASurfaceThatPausedTheGameResumesIt`, `testAPauseTheUserMadeFromTheBarIsNotResumedByTheSurface`, `testSomeOtherPauseIsResumedOnCloseAsBefore` from `TopBarHandoffTests.swift`.

- [ ] **Step 2: Grep for stragglers**

Run: `grep -rn "PauseOwnership" Common DolphiniOSTests`
Expected: no output.

- [ ] **Step 3: Run the whole test target**

Run: `cd Source/iOS/App && make test DEST="platform=iOS Simulator,name=iPhone 17 Pro" 2>&1 | grep -E "Executed|error:|failed" | tail -5`
Expected: `UILayerPauseCallsTests` now passes; every other test still passes.

- [ ] **Step 4: Commit**

```bash
git add Common/Swift/TopBar/TopBarConstants.swift DolphiniOSTests/TopBarHandoffTests.swift
git commit -m "refactor(pause): delete PauseOwnership, superseded by PauseArbiter"
```

---

### Task 6: Device gate and PR

- [ ] **Step 1: Device gate (iPhone, DEBUG build, Xbox pad or touch)**

1. Boot a game, open the pause menu, open Save States, close it, open Settings, close it, open Shaders, close it. The game must stay paused throughout; the `[PAUSE]` log lines never interleave with an unpaused frame counter.
2. Press Resume. The game runs.
3. Pause from the top bar, open the pause menu, close it with Close (not Resume). The game stays paused; tap the pill to resume.
4. Pull a controller mid-game: paused with banner. Open the pause menu, press Resume: the game runs and the banner clears.
5. Leave the menu open for 70 s on a DEBUG build: no `[PAUSE] token ... still held` line for the menu's own token (a leak line here means a release path is missing).

- [ ] **Step 2: Device gate (Apple TV, Xbox pad)**

1. Menu opens the pause menu; the opening press does not close it.
2. Enter Save States and back out with B; enter Settings and back out with Menu. Paused throughout.
3. Siri Remote Menu while the pause menu is up closes it and resumes.

- [ ] **Step 3: Open the PR against `develop`**

Title: `fix(pause): PauseArbiter — one owner of the core pause`. Body: the spec section §4.3 summary, the device gate results, and that `UILayerPauseCallsTests` now guards the invariant. Do not push `develop`.
