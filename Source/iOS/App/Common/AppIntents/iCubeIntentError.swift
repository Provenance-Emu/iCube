// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import AppIntents

/// User-facing failure reasons for the launch intents, surfaced by Siri/Shortcuts when there's
/// nothing to launch.
enum iCubeIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noRecentGame
    case noGames

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noRecentGame: return "You haven't played any games yet."
        case .noGames: return "Your iCube library is empty."
        }
    }
}
