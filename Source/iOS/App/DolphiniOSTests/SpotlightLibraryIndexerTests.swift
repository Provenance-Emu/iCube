// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CoreSpotlight
import os
import XCTest

@testable import iCube

/// `SpotlightIndexService` used to build a `TVGameItem` and PNG-encode a cover for every game on the
/// main thread, at launch and on every `RemoteLibraryUpdated` — main-thread work proportional to
/// library size (the next hang after ICUBE-F). The indexer must do that work off the caller's
/// thread and fold bursts of requests into one pass.
final class SpotlightLibraryIndexerTests: XCTestCase {

    private let timeout: TimeInterval = 5

    private static func demoGame() -> TVGameItem {
        TVGameItem(demoTitle: "Test Title", gameID: "GTST01", platform: 0, maker: "Test Maker",
                   countryName: "USA", fileSize: 1, accentHue: 0.3)
    }

    func test_searchableItem_carriesIdentityMakerYearAndCountry() {
        let item = SpotlightLibraryIndexer.searchableItem(for: Self.demoGame())

        XCTAssertEqual(item.uniqueIdentifier, "dios.game.GTST01")
        XCTAssertEqual(item.domainIdentifier, "dios.games")
        XCTAssertEqual(item.attributeSet.title, "Test Title")
        let description = item.attributeSet.contentDescription ?? ""
        XCTAssertTrue(description.contains("Test Maker"), description)
        XCTAssertTrue(description.contains("2024"), description)
        XCTAssertTrue(description.contains("USA"), description)
        XCTAssertNotNil(item.attributeSet.thumbnailData)
    }

    func test_reindexAll_buildsItemsOffTheCallingThread() {
        XCTAssertTrue(Thread.isMainThread, "precondition: tests call in from the main thread")
        let builtOnMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let submitted = expectation(description: "pass submitted")
        let indexer = SpotlightLibraryIndexer(
            queue: DispatchQueue(label: "test.spotlight.offmain"),
            games: {
                builtOnMain.withLock { $0 = Thread.isMainThread }
                return [Self.demoGame()]
            },
            submit: { _ in submitted.fulfill() })

        indexer.reindexAll()

        wait(for: [submitted], timeout: timeout)
        XCTAssertEqual(builtOnMain.withLock { $0 }, false)
    }

    func test_reindexAll_foldsRequestsMadeWhileAPassIsQueued() {
        let queue = DispatchQueue(label: "test.spotlight.coalesce")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() } // hold the queue the way a long pass would
        let passes = OSAllocatedUnfairLock(initialState: 0)
        let submitted = expectation(description: "pass submitted")
        submitted.assertForOverFulfill = false // the pass count below is the assertion
        let indexer = SpotlightLibraryIndexer(
            queue: queue,
            games: {
                passes.withLock { $0 += 1 }
                return []
            },
            submit: { _ in submitted.fulfill() })

        for _ in 0..<5 { indexer.reindexAll() }
        gate.signal()

        wait(for: [submitted], timeout: timeout)
        queue.sync {} // let anything else that was queued run before counting
        XCTAssertEqual(passes.withLock { $0 }, 1)
    }
}
