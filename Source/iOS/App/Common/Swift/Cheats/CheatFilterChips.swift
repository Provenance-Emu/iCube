// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

#if os(iOS)
/// iOS host chrome above the cheats list: a horizontally scrolling row of capsule
/// chips, one per `CheatFilter.available(in:)`, each with its count. The same
/// pattern as the library's platform pills (`libraryPlatformFilterPill`) and
/// iFly's `FilterChip` row. tvOS gets a cycle row in the model instead.
struct CheatFilterChips: View {
  let cheats: [CheatItem]
  @Binding var selection: CheatFilter

  private var filters: [CheatFilter] { CheatFilter.available(in: cheats) }

  var body: some View {
    if CheatFilter.isWorthShowing(filters) {
      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: ICubeDesign.Spacing.xxs.rawValue) {
            ForEach(filters, id: \.id) { filter in
              chip(filter).id(filter.id)
            }
          }
          .padding(.horizontal, ICubeDesign.Spacing.xs.rawValue)
          .padding(.vertical, ICubeDesign.Spacing.xxs.rawValue)
          // The one blur layer (spec §2.6): the chip bar is a panel over the list.
          .background { Capsule(style: .continuous).fill(.ultraThinMaterial) }
          .clipShape(Capsule(style: .continuous))
          .padding(.horizontal, ICubeDesign.Spacing.m.rawValue)
          .padding(.vertical, ICubeDesign.Spacing.xs.rawValue)
        }
        .onAppear { proxy.scrollTo(selection.id, anchor: .center) }
      }
      .onChange(of: filters.map(\.id)) { _, ids in
        // The selected category can vanish when its last cheat is deleted or the
        // search narrows the list; fall back rather than show an empty, unchangeable list.
        if !ids.contains(selection.id) { selection = .all }
      }
    }
  }

  private func chip(_ filter: CheatFilter) -> some View {
    let count = filter.count(in: cheats)
    let isSelected = selection == filter
    return Button {
      selection = filter
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    } label: {
      HStack(spacing: ICubeDesign.Spacing.xxs.rawValue) {
        if let icon = filter.icon {
          Image(systemName: icon).icubeText(.tag)
        }
        Text(filter.title)
          .icubeText(.detail)
          .fontWeight(isSelected ? .semibold : .regular)
          .lineLimit(1)
        Text("\(count)")
          .icubeText(.tag)
          .foregroundStyle(ICubeDesign.color(.textSecondary))
      }
      .foregroundStyle(isSelected ? ICubeDesign.color(.accent) : ICubeDesign.color(.textPrimary))
      .padding(.horizontal, ICubeDesign.Spacing.s.rawValue)
      .padding(.vertical, ICubeDesign.Spacing.xxs.rawValue)
      .fixedSize(horizontal: true, vertical: false)
      .background {
        // Selection is shown by fill, never by a stroke (spec §2.4).
        if isSelected {
          Capsule(style: .continuous).fill(ICubeDesign.color(.selectedFill))
        }
      }
      .contentShape(Capsule(style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(filter.title), \(count)")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
#endif
