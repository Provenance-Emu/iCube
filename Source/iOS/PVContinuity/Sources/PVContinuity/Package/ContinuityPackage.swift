// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

/// The `.icubepkg` offline package format: a ZIP holding `manifest.json` (the
/// same versioned `ContinuityManifest` the network handoff serves) plus every
/// payload file at its manifest-relative path.
///
/// This is the AirDrop-shaped sibling of the LAN handoff: same manifest, same
/// checksums, same allow-list semantics (only manifest-listed paths are
/// extracted, so a crafted archive cannot traverse out of the User directory),
/// but no discovery, no pairing and no transport.
///
/// ## Status: constants only
///
/// The reader and writer are deliberately **not** vendored here. They need a
/// ZIP implementation (iFly's take ZIPFoundation as a package dependency), and
/// this is a leaf package that today has none. iCube's app target already
/// links `Zip` and `SWCompression`, so the archive half belongs on the app
/// side — or behind a protocol this package declares — rather than dragging a
/// third dependency into a package whose entire value is that it is pure logic
/// and testable without one.
///
/// These constants live here now because the identifiers are shared with the
/// Info.plist `UTExportedTypeDeclarations` entry and must not be spelled twice.
public enum ContinuityPackage {
    public static let fileExtension = "icubepkg"
    /// Exported UTI. Must match the app's `UTExportedTypeDeclarations`.
    public static let typeIdentifier = "com.joemattiello.icube.package"
    public static let mimeType = "application/x-icube-package"
    public static let manifestEntryName = "manifest.json"
}
