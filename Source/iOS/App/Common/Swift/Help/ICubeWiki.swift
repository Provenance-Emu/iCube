// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import PVHelp

/// iCube's wiki identity and offline content. Keep the cache namespace and page
/// paths stable so existing cached pages and in-app links continue to work.
enum ICubeWiki {
    static let configuration = WikiConfiguration(
        baseURL: URL(string: "https://raw.githubusercontent.com/Provenance-Emu/icube-wiki/master/")!,
        webBaseURL: URL(string: "https://icube-emu.com/")!,
        cacheNamespace: "PVHelp",
        bundledContent: .init(bundle: .main, subdirectory: "WikiContent")
    )

    static func webURL(for path: String) -> URL { configuration.webURL(for: path) }

    enum Paths {
        static let jitGuide = "guide/jit.md"
        static let webImport = "help/web-import.md"
        static let biosRequirements = "help/gamecube-bios.md"
        static let saveStateCompatibility = "help/save-state-compatibility.md"
        static let wiiSystemFiles = "guide/wii-system-files.md"
    }
}
