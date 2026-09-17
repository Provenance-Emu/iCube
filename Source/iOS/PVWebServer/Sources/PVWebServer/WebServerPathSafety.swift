//
//  WebServerPathSafety.swift
//  PVWebServer
//
//  Sandbox path resolution for the HTTP/WebDAV server. Extracted from
//  NativeWebServer so the traversal guard is unit-testable in isolation.
//

import Foundation

/// Resolves a client-supplied relative path against a base directory and rejects any path
/// that escapes the sandbox — lexically (`..`) OR via an on-disk symlink. `internal` so it
/// can be exercised directly by `PVWebServerTests`.
enum WebServerPathSafety {

    enum Resolution: Equatable {
        /// Path is safely inside the sandbox; carries the (lexically-standardized) URL.
        case ok(URL)
        /// `.`/`..` collapsing lands the path outside the base directory.
        case lexicalEscape
        /// The path is lexically inside, but a symlink component resolves outside on disk.
        case symlinkEscape
    }

    /// - Returns: `.ok(url)` with the LEXICAL url (so callers' relative-path/href math is
    ///   unchanged), or a rejection reason. The rejection reasons are distinguished so the
    ///   caller can log which guard fired.
    static func resolve(_ rawPath: String, within baseDir: URL) -> Resolution {
        let lexical = baseDir.appendingPathComponent(rawPath).standardized
        let basePath = baseDir.standardized.path

        // 1. Lexical guard — collapses `.`/`..`.
        guard lexical.path == basePath || lexical.path.hasPrefix(basePath + "/") else {
            return .lexicalEscape
        }

        // 2. Symlink guard — resolve BOTH sides the SAME way and re-check, so a symlink
        //    INSIDE the sandbox pointing outside is caught (lexical `..` can't see an
        //    on-disk symlink). Resolving both keeps the iOS Documents /var→/private/var
        //    (and /tmp→/private/tmp) symlink from causing a false reject.
        let realBase = realPathResolvingExistingPrefix(baseDir.standardized)
        let realTarget = realPathResolvingExistingPrefix(lexical)
        guard realTarget == realBase || realTarget.hasPrefix(realBase + "/") else {
            return .symlinkEscape
        }

        return .ok(lexical)
    }

    /// `resolvingSymlinksInPath()` only resolves links when the FULL path exists — a PUT to
    /// a not-yet-created file has a non-existent leaf, so a symlinked parent dir would go
    /// unresolved and escape the guard. Resolve the deepest EXISTING ancestor's symlinks,
    /// then re-append the non-existent tail so the check still sees the real on-disk parent.
    private static func realPathResolvingExistingPrefix(_ url: URL) -> String {
        let fm = FileManager.default
        var existing = url.standardized
        var tail: [String] = []
        while !fm.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            if parent.path == existing.path { break } // reached "/"
            tail.insert(existing.lastPathComponent, at: 0)
            existing = parent
        }
        var resolved = existing.resolvingSymlinksInPath()
        for comp in tail { resolved.appendPathComponent(comp) }
        return resolved.standardized.path
    }
}
