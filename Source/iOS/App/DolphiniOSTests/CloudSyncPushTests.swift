// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class CloudSyncPushPolicyTests: XCTestCase {
  private let subscription = CloudSyncPushSubscription.iCube
  private let ready = CloudSyncPushState(isSyncEnabled: true, isInstallAvailable: true, isEmulating: false)

  private func ours() -> CloudSyncPushNotification {
    CloudSyncPushNotification(containerIdentifier: subscription.containerIdentifier,
                              subscriptionID: subscription.subscriptionID, kind: .database)
  }

  func testOurPushFetchesWhenSyncCanRun() {
    XCTAssertEqual(CloudSyncPushPolicy.decide(ours(), subscription: subscription, state: ready), .fetch)
  }

  func testSubscriptionWatchesTheSyncContainer() {
    XCTAssertEqual(subscription.containerIdentifier, ICubeCloudSync.configuration.containerIdentifier)
  }

  func testNonCloudKitPushIsIgnored() {
    XCTAssertEqual(CloudSyncPushPolicy.decide(nil, subscription: subscription, state: ready), .ignore)
  }

  func testOtherSubscriptionIsIgnored() {
    var push = ours()
    push.subscriptionID = "someone-else"
    XCTAssertEqual(CloudSyncPushPolicy.decide(push, subscription: subscription, state: ready), .ignore)
  }

  func testOtherContainerIsIgnored() {
    var push = ours()
    push.containerIdentifier = "iCloud.org.provenance-emu.provenance"
    XCTAssertEqual(CloudSyncPushPolicy.decide(push, subscription: subscription, state: ready), .ignore)
  }

  func testNonDatabaseNotificationIsIgnored() {
    var push = ours()
    push.kind = .other
    XCTAssertEqual(CloudSyncPushPolicy.decide(push, subscription: subscription, state: ready), .ignore)
  }

  func testSyncOffDoesNotFetch() {
    var state = ready
    state.isSyncEnabled = false
    XCTAssertEqual(CloudSyncPushPolicy.decide(ours(), subscription: subscription, state: state), .syncOff)
  }

  func testUnavailableInstallDoesNotFetch() {
    var state = ready
    state.isInstallAvailable = false
    XCTAssertEqual(CloudSyncPushPolicy.decide(ours(), subscription: subscription, state: state), .syncOff)
  }

  func testRunningGameDefersInsteadOfFetching() {
    var state = ready
    state.isEmulating = true
    XCTAssertEqual(CloudSyncPushPolicy.decide(ours(), subscription: subscription, state: state), .deferUntilGameEnds)
  }

  func testSyncOffWinsOverRunningGame() {
    let state = CloudSyncPushState(isSyncEnabled: false, isInstallAvailable: true, isEmulating: true)
    XCTAssertEqual(CloudSyncPushPolicy.decide(ours(), subscription: subscription, state: state), .syncOff)
  }
}

final class CloudSyncPushSubscriptionTests: XCTestCase {
  private let subscription = CloudSyncPushSubscription.iCube
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testFirstLaunchWithAccountSaves() {
    XCTAssertTrue(subscription.needsSave(marker: nil, accountIdentity: "_abc", now: now))
  }

  func testNoAccountNeverSaves() {
    XCTAssertFalse(subscription.needsSave(marker: nil, accountIdentity: nil, now: now))
    XCTAssertFalse(subscription.needsSave(marker: nil, accountIdentity: "", now: now))
  }

  func testRecentMarkerForSameAccountSkipsSave() {
    let marker = subscription.marker(accountIdentity: "_abc", savedAt: now.addingTimeInterval(-3600))
    XCTAssertFalse(subscription.needsSave(marker: marker, accountIdentity: "_abc", now: now))
  }

  func testAccountChangeSavesAgain() {
    let marker = subscription.marker(accountIdentity: "_abc", savedAt: now)
    XCTAssertTrue(subscription.needsSave(marker: marker, accountIdentity: "_def", now: now))
  }

  func testOldMarkerIsRevalidated() {
    let marker = subscription.marker(accountIdentity: "_abc",
                                     savedAt: now.addingTimeInterval(-CloudSyncPushSubscription.revalidationInterval))
    XCTAssertTrue(subscription.needsSave(marker: marker, accountIdentity: "_abc", now: now))
  }

  func testMarkerFromTheFutureIsRevalidated() {
    let marker = subscription.marker(accountIdentity: "_abc", savedAt: now.addingTimeInterval(60))
    XCTAssertTrue(subscription.needsSave(marker: marker, accountIdentity: "_abc", now: now))
  }

  func testChangedShapeSavesAgain() {
    var marker = subscription.marker(accountIdentity: "_abc", savedAt: now)
    marker.version = subscription.version - 1
    XCTAssertTrue(subscription.needsSave(marker: marker, accountIdentity: "_abc", now: now))
    marker = subscription.marker(accountIdentity: "_abc", savedAt: now)
    marker.subscriptionID = "old-id"
    XCTAssertTrue(subscription.needsSave(marker: marker, accountIdentity: "_abc", now: now))
    marker = subscription.marker(accountIdentity: "_abc", savedAt: now)
    marker.containerIdentifier = "iCloud.other"
    XCTAssertTrue(subscription.needsSave(marker: marker, accountIdentity: "_abc", now: now))
  }

  func testMarkerRoundTrips() throws {
    let marker = subscription.marker(accountIdentity: "_abc", savedAt: now)
    let decoded = try JSONDecoder().decode(CloudSyncPushSubscriptionMarker.self, from: JSONEncoder().encode(marker))
    XCTAssertEqual(decoded, marker)
  }
}

final class CloudSyncPushResultTests: XCTestCase {
  private let start = CloudSyncRemoteChangeCounters(appliedFromRemote: 3, failures: 1)

  func testAppliedChangeIsNewData() {
    let end = CloudSyncRemoteChangeCounters(appliedFromRemote: 4, failures: 1)
    XCTAssertEqual(CloudSyncPushResult.resolve(before: start, after: end, finished: true, unavailable: false), .newData)
  }

  func testAppliedChangeStillReportedAfterTimeoutOrFailure() {
    let end = CloudSyncRemoteChangeCounters(appliedFromRemote: 4, failures: 2)
    XCTAssertEqual(CloudSyncPushResult.resolve(before: start, after: end, finished: false, unavailable: true), .newData)
  }

  func testQuietRunIsNoData() {
    XCTAssertEqual(CloudSyncPushResult.resolve(before: start, after: start, finished: true, unavailable: false), .noData)
  }

  func testFailureWithNothingAppliedIsFailed() {
    let end = CloudSyncRemoteChangeCounters(appliedFromRemote: 3, failures: 2)
    XCTAssertEqual(CloudSyncPushResult.resolve(before: start, after: end, finished: true, unavailable: false), .failed)
  }

  func testTimeoutWithNothingAppliedIsFailed() {
    XCTAssertEqual(CloudSyncPushResult.resolve(before: start, after: start, finished: false, unavailable: false), .failed)
  }

  func testUnavailableIsFailed() {
    XCTAssertEqual(CloudSyncPushResult.resolve(before: start, after: start, finished: true, unavailable: true), .failed)
  }
}

final class CloudSyncPushCoalescerTests: XCTestCase {
  func testBurstShareOneRun() {
    var coalescer = CloudSyncPushCoalescer()
    XCTAssertEqual(coalescer.arrive(1), .scheduleRun)
    XCTAssertEqual(coalescer.arrive(2), .joined)
    XCTAssertEqual(coalescer.arrive(3), .joined)
    XCTAssertTrue(coalescer.beginRun())
    let finish = coalescer.finishRun()
    XCTAssertEqual(finish.answered, [1, 2, 3])
    XCTAssertFalse(finish.runAgain)
    XCTAssertEqual(coalescer.phase, .idle)
  }

  func testPushesDuringRunGetExactlyOneMoreRun() {
    var coalescer = CloudSyncPushCoalescer()
    _ = coalescer.arrive(1)
    XCTAssertTrue(coalescer.beginRun())
    XCTAssertEqual(coalescer.arrive(2), .joined)
    XCTAssertEqual(coalescer.arrive(3), .joined)

    let first = coalescer.finishRun()
    XCTAssertEqual(first.answered, [1])
    XCTAssertTrue(first.runAgain)
    XCTAssertEqual(coalescer.phase, .collecting)

    XCTAssertTrue(coalescer.beginRun())
    let second = coalescer.finishRun()
    XCTAssertEqual(second.answered, [2, 3])
    XCTAssertFalse(second.runAgain)
  }

  func testArrivalAfterIdleSchedulesAgain() {
    var coalescer = CloudSyncPushCoalescer()
    _ = coalescer.arrive(1)
    _ = coalescer.beginRun()
    _ = coalescer.finishRun()
    XCTAssertEqual(coalescer.arrive(2), .scheduleRun)
  }

  func testExpiredTokenIsNotAnsweredTwice() {
    var coalescer = CloudSyncPushCoalescer()
    _ = coalescer.arrive(1)
    _ = coalescer.arrive(2)
    _ = coalescer.beginRun()
    XCTAssertTrue(coalescer.expire(1))
    XCTAssertFalse(coalescer.expire(1))
    XCTAssertEqual(coalescer.finishRun().answered, [2])
    XCTAssertFalse(coalescer.expire(2), "Already answered by the run")
  }

  func testQueuedTokenCanExpire() {
    var coalescer = CloudSyncPushCoalescer()
    _ = coalescer.arrive(1)
    _ = coalescer.beginRun()
    _ = coalescer.arrive(2)
    XCTAssertTrue(coalescer.expire(2))
    let finish = coalescer.finishRun()
    XCTAssertEqual(finish.answered, [1])
    XCTAssertFalse(finish.runAgain, "Nobody is left waiting for another run")
  }

  func testOutOfOrderCallsAreHarmless() {
    var coalescer = CloudSyncPushCoalescer()
    XCTAssertFalse(coalescer.beginRun())
    XCTAssertEqual(coalescer.finishRun().answered, [])
    _ = coalescer.arrive(1)
    XCTAssertTrue(coalescer.beginRun())
    XCTAssertFalse(coalescer.beginRun(), "A second window closing must not restart the run")
  }

  func testEveryTokenIsAnsweredExactlyOnce() {
    var coalescer = CloudSyncPushCoalescer()
    var answered: [Int] = []
    for token in 0..<5 { _ = coalescer.arrive(token) }
    _ = coalescer.beginRun()
    for token in 5..<8 { _ = coalescer.arrive(token) }
    if coalescer.expire(6) { answered.append(6) }
    var finish = coalescer.finishRun()
    answered += finish.answered
    while finish.runAgain {
      _ = coalescer.beginRun()
      finish = coalescer.finishRun()
      answered += finish.answered
    }
    XCTAssertEqual(answered.sorted(), Array(0..<8))
    XCTAssertEqual(coalescer.phase, .idle)
  }
}
