// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The plaintext-transport disclosure, shown on every continuity surface.
///
/// A single view rather than a string repeated at call sites, so the wording
/// cannot be softened in one screen and not another — and so it is obvious in
/// review when a new continuity screen forgets it.
///
/// Wrapped in a row-shaped container (not a `.footer`) because on tvOS a
/// section footer is easy to miss entirely, and "your saves cross the network
/// unencrypted" is not a footnote.
struct ContinuitySecurityNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.open")
                .foregroundColor(.orange)
                .font(.system(size: 18, weight: .semibold))
                .accessibilityHidden(true)
            Text(ContinuityManager.transportSecurityNotice)
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
