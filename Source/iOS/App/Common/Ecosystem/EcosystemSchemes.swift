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

    /// Provenance's scheme: the gameInfo callback target
    /// (`provenance://dolphinios?games=…`) and the install probe behind
    /// "Send to Provenance".
    static let provenanceScheme = "provenance"
    /// iFly's scheme, probed by the Connected Apps settings leaf.
    static let iflyScheme = "ifly"
}
