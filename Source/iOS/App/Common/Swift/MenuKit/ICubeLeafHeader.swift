// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The in-body title of a tvOS leaf (spec §4.2): display-face title, tag-role subtitle. The only
/// thing that draws a title on tvOS; `.navigationTitle` is not used there.
struct ICubeLeafHeader: View {
  let title: String
  let subtitle: String?

  var body: some View {
    VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xxs.rawValue) {
      Text(title)
        .icubeText(.title)
        .textCase(.uppercase)
        .foregroundStyle(ICubeDesign.titleGradient)
      if let subtitle {
        Text(subtitle)
          .icubeText(.tag)
          .foregroundStyle(ICubeDesign.color(.textSecondary))
      }
    }
    .padding(.bottom, ICubeDesign.Spacing.s.rawValue)
  }

  /// A root leaf is subtitled "Settings"; a pushed sub-leaf carries its parent's title.
  static func subtitle(parentTitle: String?) -> String {
    parentTitle ?? L("Settings")
  }
}

extension EnvironmentValues {
  /// Set on a pushed sub-leaf by `MenuScreen`: the title of the leaf that pushed it.
  @Entry var icubeLeafParentTitle: String? = nil
}

/// Spec §3 section header at pause scale: an accent bar and an uppercase `nav` label. The bar takes the running
/// game's platform accent when the pause menu set one.
struct ICubeAccentHeader: View {
  let text: String
  @Environment(\.icubePlatformAccent) private var platformAccent

  private static let barWidth: CGFloat = 6
  private static let barHeight: CGFloat = 24

  var body: some View {
    HStack(spacing: ICubeDesign.Spacing.xs.rawValue) {
      Capsule()
        .fill(platformAccent ?? ICubeDesign.color(.accent))
        .frame(width: Self.barWidth, height: Self.barHeight)
      Text(text)
        .icubeText(.nav)
        .foregroundStyle(ICubeDesign.color(.textSecondary))
    }
  }
}
