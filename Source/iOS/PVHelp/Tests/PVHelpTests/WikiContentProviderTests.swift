// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import PVHelp

/// Fake transport standing in for `URLSession` so these tests never touch the network — which
/// would also just fail today, since `icube-wiki` doesn't exist yet. Records how many times it
/// was asked to fetch, so tests can assert a cache hit skipped the network entirely. An actor
/// rather than a lock-guarded class, since `WikiURLLoading.data(from:)` is itself async.
private actor MockWikiLoader: WikiURLLoading {
    private(set) var callCount = 0
    private let result: Result<(Data, URLResponse), Error>

    init(result: Result<(Data, URLResponse), Error>) {
        self.result = result
    }

    static func success(_ body: String, statusCode: Int = 200) -> MockWikiLoader {
        let response = HTTPURLResponse(
            url: URL(string: "https://raw.githubusercontent.com/Provenance-Emu/icube-wiki/master/mock")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return MockWikiLoader(result: .success((Data(body.utf8), response)))
    }

    static func failure(_ error: Error = URLError(.notConnectedToInternet)) -> MockWikiLoader {
        MockWikiLoader(result: .failure(error))
    }

    func data(from url: URL) async throws -> (Data, URLResponse) {
        callCount += 1
        return try result.get()
    }
}

final class WikiContentProviderTests: XCTestCase {
    var cache: WikiContentCache!

    override func setUp() {
        super.setUp()
        cache = WikiContentCache()
        cache.clearAll()
    }

    override func tearDown() {
        cache.clearAll()
        super.tearDown()
    }

    // MARK: - Cache miss + no network -> bundled fallback

    func testLoadPage_cacheMissAndNoNetwork_bundledPathReturnsBundledContent() async {
        let loader = MockWikiLoader.failure()
        let provider = WikiContentProvider(session: loader, cache: cache)

        let page = await provider.loadPage(path: WikiConstants.Paths.jitGuide, title: "JIT")

        let callCount = await loader.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertFalse(page.content.contains("**Offline**"))
        XCTAssertTrue(page.content.contains("JIT"), "expected real bundled JIT guide content, got: \(page.content.prefix(80))")
        // The fetch attempt should not have poisoned the cache with anything.
        XCTAssertNil(cache.cachedPage(for: WikiConstants.Paths.jitGuide))
    }

    func testLoadPage_cacheMissAndNoNetwork_unknownPathFallsBackToPlaceholder() async {
        let loader = MockWikiLoader.failure()
        let provider = WikiContentProvider(session: loader, cache: cache)

        let page = await provider.loadPage(path: "made-up/does-not-exist.md", title: "X")

        XCTAssertTrue(page.content.contains("Offline"))
    }

    func testLoadNavigationTree_cacheMissAndNoNetwork_fallsBackToBundledSummary() async {
        let loader = MockWikiLoader.failure()
        let provider = WikiContentProvider(session: loader, cache: cache)

        let tree = await provider.loadNavigationTree()

        XCTAssertFalse(tree.sections.isEmpty, "bundled SUMMARY.md should always parse into at least one section")
    }

    // MARK: - Cache hit within TTL -> no fetch

    func testLoadPage_cacheHitWithinTTL_doesNotHitNetwork() async {
        cache.cachePage("# Cached Content", for: "some/path.md")
        let loader = MockWikiLoader.failure() // would fail the test if it were called
        let provider = WikiContentProvider(session: loader, cache: cache)

        let page = await provider.loadPage(path: "some/path.md", title: "X")

        XCTAssertEqual(page.content, "# Cached Content")
        let callCount = await loader.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testLoadNavigationTree_cacheHitWithinTTL_doesNotHitNetwork() async {
        let tree = WikiNavigationTree(sections: [WikiSection(title: "Help", items: [WikiNavItem(title: "BIOS", path: "help/gamecube-bios.md")])])
        cache.cacheNavigationTree(tree)
        let loader = MockWikiLoader.failure()
        let provider = WikiContentProvider(session: loader, cache: cache)

        let loaded = await provider.loadNavigationTree()

        XCTAssertEqual(loaded.sections.first?.items.first?.title, "BIOS")
        let callCount = await loader.callCount
        XCTAssertEqual(callCount, 0)
    }

    // MARK: - Cache stale -> serves cache immediately, refreshes in background

    func testLoadPage_staleCache_servesStaleContentAndRefreshesInBackground() async {
        cache.cachePage("# Old Content", for: "stale/path.md")
        cache.expirePageCache(for: "stale/path.md")
        let loader = MockWikiLoader.success("# New Content")
        let provider = WikiContentProvider(session: loader, cache: cache)

        let page = await provider.loadPage(path: "stale/path.md", title: "X")

        // Returns the stale cached copy immediately, without waiting on the network.
        XCTAssertEqual(page.content, "# Old Content")

        // The background refresh Task is fire-and-forget; give it a moment to complete.
        try? await Task.sleep(nanoseconds: 300_000_000)

        let callCount = await loader.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(cache.cachedPage(for: "stale/path.md"), "# New Content")
    }

    func testLoadNavigationTree_staleCache_servesStaleAndRefreshesInBackground() async {
        let staleTree = WikiNavigationTree(sections: [WikiSection(title: "Old", items: [WikiNavItem(title: "Old Page", path: "old.md")])])
        cache.cacheNavigationTree(staleTree)
        cache.expireNavigationCache()
        let loader = MockWikiLoader.success("## New\n\n* [New Page](new.md)\n")
        let provider = WikiContentProvider(session: loader, cache: cache)

        let tree = await provider.loadNavigationTree()

        XCTAssertEqual(tree.sections.first?.title, "Old")

        try? await Task.sleep(nanoseconds: 300_000_000)

        let callCount = await loader.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(cache.cachedNavigationTree()?.sections.first?.title, "New")
    }
}
