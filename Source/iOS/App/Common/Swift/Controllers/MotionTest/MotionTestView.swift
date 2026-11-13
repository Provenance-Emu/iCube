// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Motion Test, pushed from the Controllers hub's Motion section: `MotionTestModelBuilder`'s model
/// in a `MenuScreen`, fed by a `MotionTestSampler` that runs only while the screen is visible.
@MainActor
struct MotionTestView: View {
  @State private var sampler = MotionTestSampler()
  @Environment(\.dismiss) private var dismiss
  @Environment(\.icubeLeafParentTitle) private var parentTitle

  static var title: String { L("Motion Test") }

  var body: some View {
    MenuScreen(
      model: MotionTestModelBuilder.make(state: sampler.state, platform: .current),
      style: .list,
      onBack: { dismiss() },
      tvHeader: SettingsLeafScreen.header(title: Self.title, parentTitle: parentTitle),
      tvInset: .xxl
    )
    #if os(iOS)
    .navigationTitle(Self.title)
    #endif
    .onAppear { sampler.start() }
    .onDisappear { sampler.stop() }
  }
}
