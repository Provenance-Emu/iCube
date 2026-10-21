// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
#if os(tvOS)
import SwiftUI

/// A manually highlighted HUD: no Button, focusable view, focus section or gesture receiver.
/// The emulation event controller retains its focus trap and the gameplay pad keeps playing.
struct TVLivePerformanceOverlay: View {
  @ObservedObject var session: LivePerformanceSession

  var body: some View {
    if session.isPresented {
      VStack {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Label(L("Live Performance"), systemImage: "speedometer").font(.system(size: 28, weight: .semibold))
            Spacer()
            Text(L("Game continues")).font(.system(size: 18)).foregroundStyle(.white.opacity(0.7))
          }
          if let item = selectedItem, let choices = item.role.steppable, let selected = session.navigation.choiceIndex {
            Text(item.title).font(.system(size: 24, weight: .medium))
            ForEach(choiceWindow(count: choices.options.count, selected: selected), id: \.self) { index in
              HStack {
                Text(choices.options[index].0)
                Spacer()
                if choices.options[index].1 == choices.selection.wrappedValue { Image(systemName: "checkmark") }
              }
              .font(.system(size: 24))
              .padding(.horizontal, 14).padding(.vertical, 9)
              .background(index == selected ? Color.white.opacity(0.22) : Color.clear,
                          in: RoundedRectangle(cornerRadius: 8))
            }
          } else {
            ForEach(rowWindow) { item in
              VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                  Text(item.title).lineLimit(1)
                  Spacer()
                  if let badge = item.badge { Text(badge).font(.system(size: 18, weight: .medium)).foregroundStyle(.white.opacity(0.7)) }
                  if let value = item.currentValueTitle { Text(value).fontWeight(.medium) }
                  if item.adjustsWithLeftRight { Image(systemName: "arrow.left.and.right").font(.system(size: 17)) }
                  else if item.role.steppable != nil { Image(systemName: "chevron.right").font(.system(size: 17)) }
                }
                .font(.system(size: 24))
                .opacity(item.isEnabled ? 1 : 0.6)
                if !item.isEnabled, let reason = item.disabledReason {
                  Text(reason).font(.system(size: 17)).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                }
              }
              .padding(.horizontal, 14).padding(.vertical, 9)
              .background(item.id == session.navigation.selectedID ? Color.white.opacity(0.22) : Color.clear,
                          in: RoundedRectangle(cornerRadius: 8))
            }
          }
          if let item = selectedItem, let explanation = item.isEnabled ? item.description : item.disabledReason {
            Text(explanation).font(.system(size: 18)).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
          }
          HStack {
            Text(L("Remote: Move · Select · Back"))
            Spacer()
            Text(L("Controller: Play"))
          }.font(.system(size: 17)).foregroundStyle(.white.opacity(0.65))
        }
        .padding(24)
        .foregroundStyle(.white)
        .frame(width: 820)
        .background(Color.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        .padding(.top, 36)
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .allowsHitTesting(false)
      .accessibilityElement(children: .combine)
    }
  }

  private var selectedItem: MenuItem? { session.rows.first { $0.id == session.navigation.selectedID } }
  private var rowWindow: [MenuItem] {
    let selected = session.rows.firstIndex { $0.id == session.navigation.selectedID } ?? 0
    return choiceWindow(count: session.rows.count, selected: selected).map { session.rows[$0] }
  }
  private func choiceWindow(count: Int, selected: Int) -> Range<Int> {
    let start = max(0, min(selected - 2, count - 6))
    return start..<min(count, start + 6)
  }
}
#endif
