// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import PVHelp

final class WikiNavigationTreeTests: XCTestCase {

    let sampleSummary = """
    # Table of contents

    * [Welcome](README.md)

    ## Guides

    * [JIT & Performance](guide/jit.md)

    ## Help

    * [Wi-Fi / Web Import](help/web-import.md)
      * [Troubleshooting](help/web-import-troubleshooting.md)
    * [GameCube BIOS](help/gamecube-bios.md)
    """

    func testParseSections() {
        let tree = WikiNavigationTree.parse(markdown: sampleSummary)

        // Root section (items before first ##) + 2 named sections
        XCTAssertEqual(tree.sections.count, 3)
        XCTAssertEqual(tree.sections[0].title, "")
        XCTAssertEqual(tree.sections[1].title, "Guides")
        XCTAssertEqual(tree.sections[2].title, "Help")
    }

    func testParseRootItems() {
        let tree = WikiNavigationTree.parse(markdown: sampleSummary)
        let root = tree.sections[0]

        XCTAssertEqual(root.items.count, 1)
        XCTAssertEqual(root.items[0].title, "Welcome")
        XCTAssertEqual(root.items[0].path, "README.md")
    }

    func testParseNestedItems() {
        let tree = WikiNavigationTree.parse(markdown: sampleSummary)
        let help = tree.sections[2]

        XCTAssertEqual(help.items.count, 2)

        let webImport = help.items[0]
        XCTAssertEqual(webImport.title, "Wi-Fi / Web Import")
        XCTAssertEqual(webImport.children.count, 1)
        XCTAssertEqual(webImport.children[0].title, "Troubleshooting")
    }

    func testSkipsExternalLinks() {
        let markdown = """
        ## Help

        * [Support](help/support.md)
        * [Release Notes](https://github.com/Provenance-Emu/icube/releases)
        * [Troubleshooting](help/troubleshooting.md)
        """

        let tree = WikiNavigationTree.parse(markdown: markdown)
        XCTAssertEqual(tree.sections.count, 1)
        XCTAssertEqual(tree.sections[0].items.count, 2) // external link skipped
        XCTAssertEqual(tree.sections[0].items[0].title, "Support")
        XCTAssertEqual(tree.sections[0].items[1].title, "Troubleshooting")
    }

    func testBlocksAppStoreUnsafePages() {
        let markdown = """
        ## Getting Started

        * [App Store](installation-and-usage/app-store.md)
        * [Sideloading](installation-and-usage/installing-provenance/sideloading.md)
        * [Building from Source](installation-and-usage/installing-provenance/building-from-source.md)

        ## Advanced

        * [Virtualizing macOS](info/miscellaneous/virtualizing-macos.md)
        * [Launch ROMs via URL](info/miscellaneous/launch-roms-via-url.md)

        ## Help

        * [Troubleshooting](help/troubleshooting.md)
        * [Jailbreak Notes](help/jailbreak-notes.md)
        """

        let tree = WikiNavigationTree.parse(markdown: markdown)

        // Getting Started: only App Store should remain
        let gettingStarted = tree.sections[0]
        XCTAssertEqual(gettingStarted.items.count, 1)
        XCTAssertEqual(gettingStarted.items[0].title, "App Store")

        // Advanced: only Launch ROMs should remain
        let advanced = tree.sections[1]
        XCTAssertEqual(advanced.items.count, 1)
        XCTAssertEqual(advanced.items[0].title, "Launch ROMs via URL")

        // Help: only Troubleshooting should remain (Jailbreak Notes hits the "jailbreak" keyword)
        let help = tree.sections[2]
        XCTAssertEqual(help.items.count, 1)
        XCTAssertEqual(help.items[0].title, "Troubleshooting")
    }

    func testBlockedSectionDroppedWhenEmpty() {
        let markdown = """
        ## Blocked Section

        * [Sideloading](installation-and-usage/installing-provenance/sideloading.md)

        ## Good Section

        * [BIOS](help/gamecube-bios.md)
        """

        let tree = WikiNavigationTree.parse(markdown: markdown)
        // Blocked Section should be entirely dropped
        XCTAssertEqual(tree.sections.count, 1)
        XCTAssertEqual(tree.sections[0].title, "Good Section")
    }

    func testEmptyInput() {
        let tree = WikiNavigationTree.parse(markdown: "")
        XCTAssertTrue(tree.sections.isEmpty)
    }

    func testCodable() throws {
        let tree = WikiNavigationTree.parse(markdown: sampleSummary)
        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(WikiNavigationTree.self, from: data)
        XCTAssertEqual(decoded.sections.count, tree.sections.count)
        XCTAssertEqual(decoded.sections[2].items[0].children.count, 1)
    }

    /// `ipa` cannot be a substring rule: it matches `ipad` and `participate`, which would hide
    /// unrelated pages if it were a plain substring keyword instead of a whole-path-component one.
    func testShortKeywordOnlyMatchesWholePathComponent() {
        let markdown = """
        ## Help

        * [iPad Setup](help/ipad-setup.md)
        * [Participate](info/participate.md)
        * [IPA Install](installation-and-usage/ipa/install.md)
        """

        let tree = WikiNavigationTree.parse(markdown: markdown)
        XCTAssertEqual(tree.sections[0].items.map(\.title), ["iPad Setup", "Participate"])
    }

    /// `blockedPaths` compares against `path.lowercased()`; verify an exact-path entry matches
    /// regardless of the casing used in the source Markdown link.
    func testBlockedPathMatchesRegardlessOfSourceCasing() {
        let markdown = """
        ## Advanced

        * [Overview](info/miscellaneous/Virtualizing-macOS.md)
        * [Launch ROMs via URL](info/miscellaneous/launch-roms-via-url.md)
        """

        let tree = WikiNavigationTree.parse(markdown: markdown)
        XCTAssertEqual(tree.sections[0].items.map(\.title), ["Launch ROMs via URL"])
    }

    func testAppStoreFilteredReappliesToDecodedTree() {
        // A tree decoded from cache (e.g. cached before a keyword was added to the blocklist)
        // must still be filterable on read, not just at parse time.
        let unfiltered = WikiNavigationTree(sections: [
            WikiSection(title: "Help", items: [
                WikiNavItem(title: "Jailbreak Notes", path: "help/jailbreak-notes.md"),
                WikiNavItem(title: "BIOS", path: "help/gamecube-bios.md"),
            ])
        ])

        let filtered = unfiltered.appStoreFiltered()
        XCTAssertEqual(filtered.sections.count, 1)
        XCTAssertEqual(filtered.sections[0].items.map(\.title), ["BIOS"])
    }
}
