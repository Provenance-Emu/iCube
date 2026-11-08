// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The ports iCube's upload server (HTTP and WebDAV on one listener) may bind.
///
/// iFly and Provenance can run on the same device, and whoever binds a port first
/// owns it. So every app has its own home port, and no fallback list may land on
/// another app's home port (Joe's port map, 2026-11-08):
///
/// | App | Home | Fallback |
/// |---|---|---|
/// | Provenance upload / WebDAV | 80 / 81 on device, 8080 / 8081 on sim and Mac | 8180–8189 |
/// | Provenance library sharing | 8484 and up | through 8515 |
/// | iFly (HTTP + WebDAV) | 8090 | 8092–8099 |
/// | iCube (`ROMUploadServer`) | 8091 | 8190–8199 |
///
/// 8091 is above 1024, so the same list works on device, in the simulator and on a Mac.
enum ICubeServerPorts {
    static let home = 8091
    static let fallback = 8190...8199

    /// Ports tried in order.
    static let candidates = [home] + Array(fallback)

    /// Every app's home ports. None of iCube's fallbacks may be one of these.
    static let ecosystemHomePorts: Set<Int> = Set([80, 81, 8080, 8081, 8090, 8091]).union(8484...8515)
}
