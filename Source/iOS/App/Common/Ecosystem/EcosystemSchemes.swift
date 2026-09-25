// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// URL scheme strings for the cross-app "ecosystem" protocol (Provenance's
/// LudiHub-style integration, already spoken by iFly). One definition each,
/// per the repo's no-magic-strings convention — every other Ecosystem file
/// references these instead of a literal.
enum EcosystemSchemes {
    /// This app's own scheme (host side of callbacks: `<cb>://dolphinios?...`).
    /// Also the scheme `dolphinios://gameInfo`, `open`, `play` and
    /// `requestGame` arrive on.
    static let ownScheme = "dolphinios"

    /// Provenance's base scheme — the default fetch-callback target
    /// (`provenance://dolphinios?fetch=…`).
    static let provenanceScheme = "provenance"

    /// Capability marker scheme. A Provenance build that understands the
    /// `?fetch=` API registers THIS scheme in addition to `provenance://`. iCube
    /// probes the marker (not the base scheme) to tell an up-to-date Provenance
    /// from an old build that registers `provenance://` but silently ignores
    /// `?fetch=` — so the "Send to Provenance" affordance stays hidden rather
    /// than no-opping when tapped. iCube declares this in
    /// LSApplicationQueriesSchemes; Provenance declares it in its
    /// CFBundleURLTypes.
    static let provenanceEcosystemScheme = "provenance-ecosystem"
}
