// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// One line for the tvOS mod screens: iCube's folder there is Caches, which the system can empty when space
/// runs low, taking installed packs, saved mods and patched copies with it. Adds nothing to a list elsewhere.
struct TVStorageNoteSection: View {
  var body: some View {
    #if os(tvOS)
    Section {
      Text(L("Apple TV can clear Riivolution packs, saved mods and patched copies when it runs low on space."))
        .icubeText(.detail)
        .foregroundStyle(ICubeDesign.color(.textSecondary))
    }
    #else
    EmptyView()
    #endif
  }
}
