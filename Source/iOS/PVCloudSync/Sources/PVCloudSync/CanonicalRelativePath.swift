// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One correct way to turn an absolute file URL into a path relative to a root.
///
/// Ported deliberately from iFly, where the naive version
///
/// ```swift
/// url.path.replacingOccurrences(of: root.path + "/", with: "")   // ← don't
/// ```
///
/// was written wrong three separate times and shipped two real bugs.
///
/// **Mixed path forms.** `FileManager` directory enumeration hands back
/// `/private/var/…` URLs while a container URL (or anything through
/// `standardizedFileURL`) is `/var/…`. The substring then matches at offset 8 —
/// *past* the `/private` — and the orphaned prefix is glued onto the result, so
/// `foo.log` became `/privatefoo.log`. Silent in both directions: a download
/// 404'd on a file that had just been listed, and a transfer dropped files with
/// no error. The fix is not "standardize" or "don't standardize" — it is to put
/// BOTH sides in the same form before comparing.
///
/// **Replace-ALL.** `replacingOccurrences` has no notion of a prefix, so a later
/// occurrence of the search text is stripped too. Narrow in practice (the whole
/// absolute root has to recur inside the relative portion) but a prefix strip
/// costs nothing and removes it.
///
/// In this module the returned value becomes the **CloudKit record name**, so it
/// is an identity key: changing how an in-tree file's path is derived would
/// orphan every existing record and re-upload the library. Anything deriving a
/// relative path should call this rather than write the expression again.
public enum CanonicalRelativePath {

    /// Canonical on-disk path: resolves the `/var`→`/private/var` (and `/tmp`)
    /// symlinks and removes `.`/`..`, so two URLs naming the same file compare
    /// equal no matter which API produced them.
    public static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// `root`-relative path of `url`, or `nil` when `url` is not strictly inside
    /// `root`.
    ///
    /// Returns nil — never a mangled or partial string — for a file outside the
    /// root, a file that IS the root, and a sibling whose name merely starts
    /// with the root's (`/a/User` vs `/a/User2/x`), which is what the trailing
    /// separator in the prefix check is for.
    public static func relativePath(of url: URL, under root: URL) -> String? {
        let rootPath = canonicalPath(root)
        let filePath = canonicalPath(url)
        guard filePath.hasPrefix(rootPath + "/") else { return nil }
        let relative = String(filePath.dropFirst(rootPath.count + 1))
        return relative.isEmpty ? nil : relative
    }
}
