// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
#if os(iOS)
import AppIntents
import UIKit

/// "Use as Wii Remote". Opens iCube and starts the one-tap controller session through the
/// same `dolphinios://dsu/controller` route the library button's URL form uses, so Shortcuts,
/// Spotlight and the Action button all land in one place.
struct UseAsWiiRemoteIntent: AppIntent {
    // App Store processing rejects intent metadata that names Apple products or the Apple
    // trademark (ITMS-90626 on "iPhone" and "Apple"), so the strings say "phone" and "TV".
    static var title: LocalizedStringResource = "Use as Wii Remote"
    static var description = IntentDescription("Turns this phone into a Wii Remote for iCube on your TV.")
    static var openAppWhenRun: Bool = true

    static let controllerURL = URL(string: "dolphinios://dsu/controller")!

    @MainActor
    func perform() async throws -> some IntentResult {
        await UIApplication.shared.open(Self.controllerURL)
        return .result()
    }
}
#endif
