// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Single source of truth for where iCube's in-app documentation comes from.
///
/// - Note: As of 2026-09-21 the `Provenance-Emu/icube-wiki` repository this points at does
///   **not exist yet** — it is created separately by a maintainer, outside this change. Until
///   then every raw-content fetch below 404s, and ``WikiContentProvider`` transparently falls
///   back to the bundled copy of this exact content shipped in this package's `WikiContent/`
///   directory (sourced from `docs/wiki-seed/` at the repo root — see that directory's contents
///   for the files to push as the new repo's initial commit). Once the repo is live, nothing
///   here needs to change: the raw URL starts resolving and the app picks up live content
///   automatically via the existing cache-refresh path.
public enum WikiConstants {
    /// Raw GitHub content base for the (not yet created) wiki repo.
    public static let baseURL = URL(string: "https://raw.githubusercontent.com/Provenance-Emu/icube-wiki/master/")!

    /// Human-facing web base for "View on Web" / external link-outs. Deliberately reuses
    /// iCube's existing marketing domain and the same path conventions already used by
    /// deep links scattered through the app (Settings' JIT/web-import/support buttons,
    /// the GameCube BIOS alert) rather than inventing a separate "wiki.icube-emu.com" —
    /// see plan task "Keep the site and the in-app docs on one source so they cannot drift."
    public static let webBaseURL = URL(string: "https://icube-emu.com/")!

    /// Cache TTL for both page content and the navigation tree.
    public static let cacheTTL: TimeInterval = 24 * 60 * 60 // 24 hours

    public static let cacheDirectoryName = "PVHelp"
    public static let navigationCacheKey = "PVHelp_NavigationTree"
    public static let navigationTimestampKey = "PVHelp_NavigationTimestamp"
    public static let summaryFileName = "SUMMARY.md"

    public static func rawURL(for path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }

    public static func webURL(for path: String) -> URL {
        let webPath = path
            .replacingOccurrences(of: ".md", with: "")
            .replacingOccurrences(of: "/README", with: "")
        return webBaseURL.appendingPathComponent(webPath)
    }

    /// Well-known wiki page paths, so every call site references a name instead of a string
    /// literal. These paths double as the exact filenames bundled offline in `WikiContent/` and
    /// as the future raw-content paths in `icube-wiki` — one path, three uses (bundled fallback,
    /// raw fetch, and the SUMMARY.md nav entry), so none of them can silently drift apart.
    public enum Paths {
        /// JIT / TXM setup guide. Referenced from Settings → Debug → Environment.
        public static let jitGuide = "guide/jit.md"
        /// Wi-Fi / web-upload import guide. Referenced from Settings → Network.
        public static let webImport = "help/web-import.md"
        /// GameCube BIOS (IPL) guide. Referenced by the missing-BIOS alert.
        public static let biosRequirements = "help/gamecube-bios.md"
        /// Save-state version-mismatch explainer. Referenced from the save state browser.
        public static let saveStateCompatibility = "help/save-state-compatibility.md"
    }
}
