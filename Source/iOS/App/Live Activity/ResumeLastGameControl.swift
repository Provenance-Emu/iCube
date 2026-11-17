// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import AppIntents
import SwiftUI
import WidgetKit

/// Control Center / Lock Screen button that opens iCube and resumes the last game played. iOS 18
/// only; the rest of this extension supports iOS 17. The game is picked when the button is
/// tapped (`ResumeLastGameIntent`), so the control needs no timeline and no refresh.
@available(iOS 18.0, *)
struct ResumeLastGameControl: ControlWidget {
    static let kind = "com.joemattiello.icube.ResumeLastGameControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: ResumeLastGameIntent()) {
                Label("Resume Last Game", systemImage: "gamecontroller.fill")
            }
        }
        .displayName("Resume Last Game")
        .description("Opens iCube and resumes the game you played most recently.")
    }
}
