// Common/Swift/TVSaveSlotsPane.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// tvOS pause → Save States: the quick slots as cards showing each state's thumbnail and age, on the same tile
/// surface and platform accent as the pause grid. An empty slot saves on select; a filled slot, or any slot held
/// down, opens a manage panel (Load, Overwrite, Use as Quick Slot, Delete). Built for tvOS; the slot mapping and
/// focus parsing are platform-neutral so the iOS test target covers them.
struct TVSaveSlotsPane: View {
  enum Focus: Hashable {
    case slot(Int), viewAll
  }

  let game: TVGameItem
  @Binding var selectedSlot: Int
  var initialFocus: Focus?
  let onViewAll: () -> Void

  @StateObject private var states = SaveStatesViewModel()
  @FocusState private var focus: Focus?
  @State private var lastFocus: Focus?
  @State private var managedSlot: Int?
  /// The long-press that opened the panel also ends in a select; this swallows that one select.
  @State private var longPressFired = false
  @Environment(\.icubePlatformAccent) private var platformAccent

  private static let columns = 5
  /// Wii frames are 16:9; GameCube thumbnails are letterboxed into the same card so the grid stays even.
  private static let thumbnailAspect: CGFloat = 16.0 / 9.0
  private static let longPressDuration = 0.5
  private static let ageFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter
  }()

  /// `-ICubePauseFocus` values for this pane: `slot-N` (the UI's 1-based numbers) or `view-all`.
  static func debugFocus(_ value: String?) -> Focus? {
    switch value {
    case "view-all": return .viewAll
    case let value? where value.hasPrefix("slot-"):
      guard let n = Int(value.dropFirst("slot-".count)), PauseMenuView.saveSlots.contains(n) else { return nil }
      return .slot(n)
    default: return nil
    }
  }

  /// The newest numbered state per slot (a slot can hold a legacy file and a sidecar-backed one); the auto-state
  /// is not a slot.
  static func latestBySlot(_ states: [SaveStateInfo]) -> [Int: SaveStateInfo] {
    var bySlot: [Int: SaveStateInfo] = [:]
    for state in states where !state.isAuto {
      guard let slot = state.slot else { continue }
      if let current = bySlot[slot], date(of: current) >= date(of: state) { continue }
      bySlot[slot] = state
    }
    return bySlot
  }

  private static func date(of state: SaveStateInfo) -> Date { state.modifiedAt ?? state.createdAt ?? .distantPast }

  private var accent: Color { platformAccent ?? ICubeDesign.color(.accent) }

  var body: some View {
    let bySlot = Self.latestBySlot(states.states)
    return ZStack {
      VStack(alignment: .leading, spacing: ICubeDesign.Spacing.l.rawValue) {
        ICubeAccentHeader(text: L("Save States"))
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: ICubeDesign.Spacing.l.rawValue), count: Self.columns),
                  spacing: ICubeDesign.Spacing.l.rawValue) {
          ForEach(PauseMenuView.saveSlots, id: \.self) { slot in
            slotCard(slot, state: bySlot[slot])
          }
        }
        Button(action: onViewAll) {
          Label(L("View All States"), systemImage: "square.grid.2x2")
            .icubeText(.body)
            .foregroundStyle(ICubeDesign.color(.textPrimary))
        }
        .buttonStyle(ICubeRowButtonStyle())
        .focused($focus, equals: .viewAll)
        Spacer(minLength: 0)
        InfoShelf(text: shelfText(bySlot), value: nil, title: shelfTitle, icon: "square.stack.3d.up")
      }
      .disabled(managedSlot != nil)
      if let slot = managedSlot {
        ICubeConfirmPanel(title: String(format: L("Slot %d"), slot), message: manageMessage(bySlot[slot]),
                          model: manageModel(slot: slot, state: bySlot[slot]), isTV: true, onBack: { managedSlot = nil })
      }
    }
    .task(id: game.gameID) { await states.load(gameID: game.gameID) }
    .onAppear {
      DispatchQueue.main.async { focus = initialFocus ?? .slot(selectedSlot) }
    }
    .onChange(of: focus) { _, newFocus in
      if let newFocus { lastFocus = newFocus }
    }
  }

  // MARK: Slot card

  private func slotCard(_ slot: Int, state: SaveStateInfo?) -> some View {
    Button { activate(slot: slot, state: state) } label: {
      VStack(alignment: .leading, spacing: ICubeDesign.Spacing.s.rawValue) {
        thumbnail(state)
        HStack(spacing: ICubeDesign.Spacing.xs.rawValue) {
          Text(String(format: L("Slot %d"), slot))
            .icubeText(.nav)
            .foregroundStyle(ICubeDesign.color(.textPrimary))
            .lineLimit(1)
          Spacer(minLength: 0)
          if selectedSlot == slot {
            Text(L("Quick"))
              .icubeText(.tag)
              .foregroundStyle(accent)
              .padding(.horizontal, ICubeDesign.Spacing.xs.rawValue)
              .padding(.vertical, ICubeDesign.Spacing.xxs.rawValue)
              .background(Capsule().fill(accent.opacity(ICubeDesign.IconBadge.tintOpacity)))
          }
        }
        Text(state.map(age) ?? L("Empty"))
          .icubeText(.detail)
          .foregroundStyle(ICubeDesign.color(.textSecondary))
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
    }
    .buttonStyle(ICubeTileButtonStyle(minHeight: 0))
    .focused($focus, equals: .slot(slot))
    .simultaneousGesture(LongPressGesture(minimumDuration: Self.longPressDuration).onEnded { _ in
      longPressFired = true
      managedSlot = slot
    })
  }

  @ViewBuilder
  private func thumbnail(_ state: SaveStateInfo?) -> some View {
    let shape = RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue, style: .continuous)
    ZStack {
      shape.fill(ICubeDesign.color(.rowSurface))
      if let state, let image = states.thumbnails[state.id] {
        Image(uiImage: image).resizable().scaledToFit()
      } else {
        Image(systemName: state == nil ? "plus" : "photo")
          .font(ICubeDesign.TileBadge.glyphFont(prominent: false))
          .foregroundStyle(state == nil ? accent : ICubeDesign.color(.textTertiary))
      }
    }
    .aspectRatio(Self.thumbnailAspect, contentMode: .fit)
    .frame(maxWidth: .infinity)
    .clipShape(shape)
  }

  private func age(_ state: SaveStateInfo) -> String {
    Self.ageFormatter.localizedString(for: Self.date(of: state), relativeTo: Date())
  }

  // MARK: Actions

  private func activate(slot: Int, state: SaveStateInfo?) {
    if longPressFired {
      longPressFired = false
      return
    }
    if state == nil {
      save(slot)
    } else {
      managedSlot = slot
    }
  }

  private func save(_ slot: Int) {
    managedSlot = nil
    if SaveStateService.saveSlot(slot) {
      EmulationToast.post(String(format: L("Saved to Slot %d"), slot))
    } else {
      EmulationToast.post(L("Save failed"))
    }
    Task { await states.load(gameID: game.gameID) }
  }

  private func load(_ slot: Int) {
    managedSlot = nil
    TVEmulationBridge.loadState(fromSlot: slot)
    EmulationToast.post(String(format: L("Loaded Slot %d"), slot))
  }

  private func delete(_ state: SaveStateInfo) {
    managedSlot = nil
    states.delete(state: state, inGameID: game.gameID)
    EmulationToast.post(L("Deleted"))
  }

  // MARK: Manage panel

  private func manageMessage(_ state: SaveStateInfo?) -> String {
    guard let state else { return L("This slot is empty.") }
    return String(format: L("Saved %@."), age(state))
  }

  /// Cancel first, as in the Exit confirm: a second impatient press must not load over the running game.
  private func manageModel(slot: Int, state: SaveStateInfo?) -> MenuModel {
    var items = [MenuItem(id: "slot-cancel", title: L("Cancel"), icon: "xmark", role: .action { managedSlot = nil })]
    if state != nil {
      items.append(MenuItem(id: "slot-load", title: L("Load"), icon: "square.and.arrow.up", role: .action { load(slot) }))
    }
    items.append(MenuItem(id: "slot-save", title: state == nil ? L("Save Here") : L("Overwrite"), icon: "square.and.arrow.down",
                          role: .action { save(slot) }))
    if selectedSlot != slot {
      items.append(MenuItem(id: "slot-quick", title: L("Use as Quick Slot"), icon: "bolt", role: .action {
        selectedSlot = slot
        managedSlot = nil
      }))
    }
    if let state {
      items.append(MenuItem(id: "slot-delete", title: L("Delete"), icon: "trash", tint: .red, role: .destructive { delete(state) }))
    }
    return MenuModel(sections: [MenuSection(id: "slot-manage", items: items)])
  }

  // MARK: Help shelf

  private var shelfSlot: Int? {
    if case .slot(let slot) = focus ?? lastFocus { return slot }
    return nil
  }

  private var shelfTitle: String? {
    shelfSlot.map { String(format: L("Slot %d"), $0) } ?? L("View All States")
  }

  private func shelfText(_ bySlot: [Int: SaveStateInfo]) -> String {
    guard let slot = shelfSlot else { return L("Every state for this game, including the auto-save.") }
    guard let state = bySlot[slot] else { return L("Empty. Press to save here; hold for more.") }
    return String(format: L("Saved %@. Press to load, overwrite or delete."), age(state))
  }
}
