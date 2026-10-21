// Common/Swift/TVSaveSlotsPane.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

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
  var operations: QuickSavePickerOperations = .live
  var readSessionIdentifier: () -> UInt64 = { TVEmulationBridge.currentSessionIdentifier() }
  var sessionIsCurrent: (String, UInt64) -> Bool = {
    TVEmulationBridge.currentGameID() == $0 && TVEmulationBridge.currentSessionIdentifier() == $1
  }

  @State private var scan = QuickSavePickerScan()
  @State private var thumbnails: [URL: UIImage] = [:]
  @State private var openingSession: QuickSaveSurfaceSession?
  @State private var busy = false
  @FocusState private var focus: Focus?
  @State private var lastFocus: Focus?
  @State private var managedSlot: Int?
  @State private var managedSaveRequest: QuickSaveSlotSaveRequest?
  @State private var managedRequiresOverwrite = false
  @State private var actionTask: Task<Void, Never>?
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
    let bySlot = Self.latestBySlot(scan.states)
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
            .icubeText(.nav)
            .foregroundStyle(ICubeDesign.color(.textPrimary))
            .padding(.horizontal, ICubeDesign.Spacing.l.rawValue)
            .padding(.vertical, ICubeDesign.Spacing.m.rawValue)
            .frame(maxWidth: .infinity, alignment: .leading)
            .icubeCardSurface(cornerRadius: ICubeDesign.Card.rowCornerRadius)
        }
        .buttonStyle(ICubeCardButtonStyle())
        .focused($focus, equals: .viewAll)
        Spacer(minLength: 0)
        InfoShelf(text: shelfText(bySlot), value: nil, title: shelfTitle, icon: "square.stack.3d.up")
      }
      .disabled(managedSlot != nil || busy)
      if let slot = managedSlot {
        ICubeConfirmPanel(title: String(format: L("Slot %d"), slot), message: manageMessage(bySlot[slot]),
                          model: manageModel(slot: slot, state: bySlot[slot]), isTV: true, onBack: { closeManage() })
      }
    }
    .task(id: game.gameID) { await reload() }
    .onDisappear {
      actionTask?.cancel()
      actionTask = nil
      openingSession = nil
      closeManage()
    }
    .onAppear {
      openingSession = QuickSaveSurfaceSession(gameID: game.gameID, identifier: readSessionIdentifier())
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
        Text(state.map { $0.isCompatible ? age($0) : L("Incompatible") } ?? L("Empty"))
          .icubeText(.detail)
          .foregroundStyle(ICubeDesign.color(.textSecondary))
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
      .padding(ICubeDesign.Spacing.m.rawValue)
      .icubeCardSurface()
    }
    // iFly's card focus (lift, glows, accent border), as on the pause grid.
    .buttonStyle(ICubeCardButtonStyle())
    .focused($focus, equals: .slot(slot))
    .disabled(!scan.hasCompletedScan || busy)
    .simultaneousGesture(LongPressGesture(minimumDuration: Self.longPressDuration).onEnded { _ in
      longPressFired = true
      openManage(slot)
    })
  }

  @ViewBuilder
  private func thumbnail(_ state: SaveStateInfo?) -> some View {
    let shape = RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue, style: .continuous)
    ZStack {
      shape.fill(ICubeDesign.color(.rowSurface))
      if let state, let image = thumbnails[state.path] {
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
    guard !busy else { return }
    if state != nil { openManage(slot); return }
    switch saveDecision(slot) {
    case .save(let request): save(request, confirmed: false)
    case .confirm(let request): openManage(slot, request: request)
    case .unavailable: break
    }
  }

  private func saveDecision(_ slot: Int) -> QuickSaveSlotSaveDecision {
    guard let openingSession, isCurrent(openingSession) else { return .unavailable }
    let destination = operations.slotDestination(slot)
    return scan.prepareSave(slot: slot, session: openingSession, destination: destination,
      occupancy: destination.map(operations.occupancy) ?? .unknown)
  }

  private func openManage(_ slot: Int, request: QuickSaveSlotSaveRequest? = nil) {
    guard !busy, scan.hasCompletedScan else { return }
    if let request { managedSaveRequest = request; managedRequiresOverwrite = true }
    else {
      switch saveDecision(slot) {
      case .confirm(let request): managedSaveRequest = request; managedRequiresOverwrite = true
      case .save(let request): managedSaveRequest = request; managedRequiresOverwrite = false
      case .unavailable: managedSaveRequest = nil; managedRequiresOverwrite = false
      }
    }
    managedSlot = slot
  }

  private func closeManage() {
    managedSlot = nil
    managedSaveRequest = nil
    managedRequiresOverwrite = false
  }

  private func save(_ request: QuickSaveSlotSaveRequest, confirmed: Bool) {
    guard !busy else { return }
    closeManage()
    busy = true
    actionTask = Task { @MainActor in
      defer { busy = false; actionTask = nil }
      guard let outcome = await scan.save(request, confirmed: confirmed, isCurrent: isCurrent,
        destination: operations.slotDestination, occupancy: operations.occupancy,
        operation: { await operations.saveSlot(.init(request: $0, allowsOverwrite: confirmed)) }), !Task.isCancelled else { return }
      report(outcome, session: request.session)
      if outcome.isSuccess { await reload() }
    }
  }

  private func load(_ state: SaveStateInfo?) {
    guard !busy, let openingSession else { return }
    closeManage()
    busy = true
    actionTask = Task { @MainActor in
      defer { busy = false; actionTask = nil }
      guard let outcome = await QuickSaveSurfaceActions.load(state, session: openingSession,
        isCurrent: isCurrent, operation: { await operations.load($0, openingSession) }), !Task.isCancelled else { return }
      report(outcome, session: openingSession)
    }
  }

  private func isCurrent(_ session: QuickSaveSurfaceSession) -> Bool {
    openingSession == session && sessionIsCurrent(session.gameID, session.identifier)
  }

  private func report(_ outcome: QuickSaveActions.Outcome, session: QuickSaveSurfaceSession) {
    if isCurrent(session), !outcome.message.isEmpty { EmulationToast.post(outcome.message) }
  }

  private func reload() async {
    let provider = FilesystemSaveStateProvider()
    await scan.reload {
      QuickSavePickerModel.visibleStates(await provider.states(for: game.gameID), modded: ModdedBoot.isCurrentBootModded)
    }
    guard !Task.isCancelled else { return }
    for state in scan.states {
      if let image = await provider.thumbnail(for: state) { thumbnails[state.path] = image }
    }
  }

  private func delete(_ state: SaveStateInfo) {
    guard let openingSession, isCurrent(openingSession), !busy else { return }
    closeManage()
    do {
      try FilesystemSaveStateProvider().delete(state: state)
      EmulationToast.post(L("Deleted"))
      actionTask = Task { await reload() }
    } catch {
      // Leave the entry visible when deletion failed.
    }
  }

  // MARK: Manage panel

  private func manageMessage(_ state: SaveStateInfo?) -> String {
    guard let state else {
      return managedRequiresOverwrite ? L("This replaces the state in the selected classic slot.") : L("This slot is empty.")
    }
    return String(format: L("Saved %@."), age(state))
  }

  /// The primary pane uses the same compatible-state gate as the picker, including callback activation.
  static func loadItem(state: SaveStateInfo?, busy: Bool, onLoad: @escaping (SaveStateInfo) -> Void) -> MenuItem {
    MenuItem(id: "slot-load", title: L("Load"), icon: "square.and.arrow.up", role: .action {
      guard let state, QuickSavePickerModel.canLoad(state, busy: busy) else { return }
      onLoad(state)
    }, isEnabled: QuickSavePickerModel.canLoad(state, busy: busy))
  }

  /// Captures the request and the choice actually presented before closing the manage panel clears them.
  static func saveItem(request: QuickSaveSlotSaveRequest?, requiresOverwrite: Bool, busy: Bool,
                       onSave: @escaping (QuickSaveSlotSaveRequest, Bool) -> Void) -> MenuItem {
    MenuItem(id: "slot-save", title: requiresOverwrite ? L("Overwrite") : L("Save Here"), icon: "square.and.arrow.down",
      role: .action {
        guard let request else { return }
        onSave(request, requiresOverwrite)
      }, isEnabled: !busy && request != nil)
  }

  /// Cancel first, as in the Exit confirm: a second impatient press must not load over the running game.
  private func manageModel(slot: Int, state: SaveStateInfo?) -> MenuModel {
    var items = [MenuItem(id: "slot-cancel", title: L("Cancel"), icon: "xmark", role: .action { closeManage() })]
    items.append(Self.loadItem(state: state, busy: busy, onLoad: { load($0) }))
    items.append(Self.saveItem(request: managedSaveRequest, requiresOverwrite: managedRequiresOverwrite,
                               busy: busy, onSave: { save($0, confirmed: $1) }))
    if selectedSlot != slot {
      items.append(MenuItem(id: "slot-quick", title: L("Use as Quick Slot"), icon: "bolt", role: .action {
        selectedSlot = slot
        closeManage()
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
