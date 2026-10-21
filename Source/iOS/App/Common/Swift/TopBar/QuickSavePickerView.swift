// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

/// These closures use the reviewed serialized facade. The picker owns no save-file write or retention code.
struct QuickSavePickerOperations {
  var save: @MainActor (QuickSaveMode, Int) async -> QuickSaveActions.Outcome
  var load: @MainActor (SaveStateInfo, QuickSaveSurfaceSession) async -> QuickSaveActions.Outcome
  var setKept: @MainActor (SaveStateInfo, Bool, QuickSaveSurfaceSession) async -> QuickSaveActions.Outcome

  var slotDestination: @MainActor (Int) -> URL? = { slot in
    TVEmulationBridge.stateFilePath(forSlot: slot).map { URL(fileURLWithPath: $0) }
  }
  var saveSlot: @MainActor (ClassicSlotSaveConsent) async -> QuickSaveActions.Outcome = { await QuickSaveActions.saveSlot($0) }
  var occupancy: (URL) -> QuickSaveDestinationOccupancy = { QuickSaveDestinationOccupancy.read($0) }

  static let live = QuickSavePickerOperations(
    save: { await QuickSaveActions.save(mode: $0, slot: $1) },
    load: { await QuickSaveActions.loadSelected($0, expectedSession: $1) },
    setKept: { await QuickSaveActions.setKept($1, for: $0, expectedSession: $2) })
}

struct QuickSavePickerView: View {
  let gameID: String
  @Binding var mode: QuickSaveMode
  @Binding var selectedSlot: Int
  let onDismiss: () -> Void
  var operations: QuickSavePickerOperations = .live
  var provider: SaveStateProviding = FilesystemSaveStateProvider()
  var isModded: () -> Bool = { ModdedBoot.isCurrentBootModded }
  var readSessionIdentifier: () -> UInt64 = { TVEmulationBridge.currentSessionIdentifier() }
  var sessionIsCurrent: (String, UInt64) -> Bool = {
    TVEmulationBridge.currentGameID() == $0 && TVEmulationBridge.currentSessionIdentifier() == $1
  }

  /// Reports actual footer layout directly; hosted checks must not depend on preference propagation.
  var onFooterFrameChange: (CGRect) -> Void = { _ in }

  /// Direct geometry samples for rendered acceptance checks inside the navigation boundary.
  var onContentFrameChange: (String, CGRect) -> Void = { _, _ in }

  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var scan = QuickSavePickerScan()
  @State private var thumbnails: [URL: UIImage] = [:]
  @State private var selection = QuickSavePickerSelection()
  @State private var busy = false
  @State private var openingSessionIdentifier: UInt64?
  @State private var overwriteRequest: QuickSaveSlotSaveRequest?
  @State private var surfaceIsActive = false

  private var states: [SaveStateInfo] { scan.states }

  private var effectiveMode: QuickSaveMode { isModded() ? .slots : mode }
  private var manualStates: [SaveStateInfo] { QuickSavePickerModel.manualStates(states) }
  private var selectedState: SaveStateInfo? {
    if effectiveMode == .slots { return QuickSavePickerModel.slotState(selectedSlot, states: states) }
    return states.first { $0.path == selection.historyPath }
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: ICubeDesign.Spacing.s.rawValue) {
        ScrollView {
          VStack(alignment: .leading, spacing: usesCompactCards ? ICubeDesign.Spacing.xs.rawValue : ICubeDesign.Spacing.m.rawValue) {
            modeButtons
            if isModded() {
              Text(L("Modded games use classic slots. Automatic resume and quick-save history are unavailable."))
                .icubeText(.detail)
                .foregroundStyle(ICubeDesign.color(.textSecondary))
            }
            if effectiveMode == .history {
              historyContents
              historyRetention
            } else {
              if !usesCompactCards { Text(L("Choose a slot")).icubeText(.nav) }
              LazyVGrid(columns: cardColumns, spacing: ICubeDesign.Spacing.s.rawValue) {
                ForEach(QuickSavePickerModel.slots, id: \.self) { slot in
                  stateCard(QuickSavePickerModel.slotState(slot, states: states), slot: slot)
                }
              }
            }
          }
          .padding(.vertical, usesCompactCards ? .zero : ICubeDesign.Spacing.xxs.rawValue)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(contentFrameObserver("viewport"))
        footer
          .background(GeometryReader { geometry in
            let frame = geometry.frame(in: .global)
            Color.clear
              .onAppear { onFooterFrameChange(frame) }
              .onChange(of: frame) { _, frame in onFooterFrameChange(frame) }
          })
      }
      .padding(ICubeDesign.Spacing.m.rawValue)
      .background(ICubeRoom(style: .gradient))
      #if os(tvOS)
      .navigationTitle(L("Save States")) // design-lint: allow Preserve existing tvOS navigation title; iOS uses its principal heading.
      #else
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .principal) {
          Text(L("Save States")).icubeText(.nav).accessibilityIdentifier("quick-save-picker.header")
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(L("Done"), action: onDismiss).frame(minHeight: TopBarLayout.minimumTarget).disabled(busy)
            .accessibilityIdentifier("quick-save-picker.done")
        }
      }
      .confirmationDialog(L("Replace occupied save state?"), isPresented: Binding(
        get: { overwriteRequest != nil }, set: { if !$0 { overwriteRequest = nil } }), titleVisibility: .visible) {
          if let request = overwriteRequest {
            Button(String(format: L("Save to slot %d"), request.slot), role: .destructive) {
              overwriteRequest = nil
              performSave(mode: .slots, slot: request.slot, request: request, confirmed: true)
            }
          }
          Button(L("Cancel"), role: .cancel) { overwriteRequest = nil }
      } message: {
        Text(L("This replaces the state in the selected classic slot."))
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("quick-save-picker")
    .onAppear {
      surfaceIsActive = true
      if openingSessionIdentifier == nil { openingSessionIdentifier = readSessionIdentifier() }
      if !QuickSavePickerModel.slots.contains(selectedSlot) { selectedSlot = 1 }
    }
    .onDisappear { surfaceIsActive = false; overwriteRequest = nil }
    .interactiveDismissDisabled(busy)
    .task(id: gameID) { await reload() }
    .onChange(of: mode) { _, _ in selection.reconcile(states: states) }
    #if os(tvOS)
    .onExitCommand { if !busy { onDismiss() } }
    #endif
  }

  private var usesCompactCards: Bool {
    #if os(iOS)
    return UIDevice.current.userInterfaceIdiom == .phone && verticalSizeClass == .compact
    #else
    return false
    #endif
  }

  private var cardColumns: [GridItem] {
    #if os(tvOS)
    let minimumWidth: CGFloat = 320
    #else
    let minimumWidth: CGFloat = 144
    #endif
    return usesCompactCards || dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())]
      : [GridItem(.adaptive(minimum: minimumWidth), spacing: ICubeDesign.Spacing.s.rawValue)]
  }

  private var modeButtons: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: ICubeDesign.Spacing.xs.rawValue) { modeChoices }
      VStack(spacing: ICubeDesign.Spacing.xs.rawValue) { modeChoices }
    }
  }

  @ViewBuilder
  private var modeChoices: some View {
    modeButton(L("Quick-save history"), value: .history)
    modeButton(L("Classic slots"), value: .slots)
  }

  private func modeButton(_ title: String, value: QuickSaveMode) -> some View {
    Button { mode = value } label: {
      Text(title).icubeText(.body)
        .padding(.horizontal, ICubeDesign.Spacing.s.rawValue)
        .frame(minHeight: TopBarLayout.minimumTarget)
        .frame(maxWidth: .infinity)
        .foregroundStyle(ICubeDesign.color(.textPrimary))
        .background(ICubeDesign.color(effectiveMode == value ? .selectedFill : .rowSurface),
                    in: RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue))
    }
    .buttonStyle(.plain)
    .disabled(isModded() && value == .history || busy)
    .accessibilityAddTraits(effectiveMode == value ? .isSelected : [])
    .accessibilityIdentifier("quick-save-picker.mode.\(value.rawValue)")
  }

  private var historyContents: some View {
    VStack(alignment: .leading, spacing: ICubeDesign.Spacing.s.rawValue) {
      if !usesCompactCards { Text(L("Newest first")).icubeText(.nav) }
      if manualStates.isEmpty {
        Label(L("No manual save states yet"), systemImage: "clock.arrow.circlepath")
          .icubeText(.body)
          .padding(.vertical, ICubeDesign.Spacing.m.rawValue)
      } else {
        LazyVGrid(columns: cardColumns, spacing: ICubeDesign.Spacing.s.rawValue) {
          ForEach(manualStates, id: \.path) { state in stateCard(state) }
        }
      }
      if let automatic = states.first(where: { $0.isAuto }) {
        Divider()
        Text(L("Automatic resume")).icubeText(.nav)
        LazyVGrid(columns: cardColumns, spacing: ICubeDesign.Spacing.s.rawValue) { stateCard(automatic) }
      }
    }
  }

  private func stateCard(_ state: SaveStateInfo?, slot: Int? = nil) -> some View {
    let selected = effectiveMode == .slots ? selectedSlot == slot : state?.path == selection.historyPath
    return Button {
      if let slot { selectedSlot = slot }
      if let state { selection.select(state) }
    } label: {
      Group {
        if usesCompactCards {
          HStack(alignment: .center, spacing: ICubeDesign.Spacing.s.rawValue) {
            cardThumbnail(state, slot: slot)
              .frame(width: ICubeDesign.Spacing.xxl.rawValue)
            cardMetadata(state, slot: slot, compact: true)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        } else {
          VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xs.rawValue) {
            cardThumbnail(state, slot: slot)
            cardMetadata(state, slot: slot, compact: false)
              .padding([.horizontal, .bottom], ICubeDesign.Spacing.s.rawValue)
          }
        }
      }
      .foregroundStyle(ICubeDesign.color(.textPrimary))
      .background(ICubeDesign.color(selected ? .selectedFill : .rowSurface))
      .clipShape(RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue))
      .overlay(alignment: .topTrailing) {
        if selected {
          Image(systemName: "checkmark.circle.fill")
            .font(ICubeDesign.symbolFont(.rail))
            .foregroundStyle(ICubeDesign.color(.accent))
            .padding(ICubeDesign.Spacing.xs.rawValue)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(ICubeRowButtonStyle())
    .disabled(busy)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityHint(L("Selects this state. Use Load selected to load it."))
    .accessibilityIdentifier("quick-save-picker.card.\(cardIdentifier(state, slot: slot))")
  }

  private func cardIdentifier(_ state: SaveStateInfo?, slot: Int?) -> String {
    slot.map { "slot-\($0)" } ?? state?.path.lastPathComponent ?? "empty"
  }

  private func contentFrameObserver(_ identifier: String) -> some View {
    GeometryReader { geometry in
      let frame = geometry.frame(in: .global)
      Color.clear
        .onAppear { onContentFrameChange(identifier, frame) }
        .onChange(of: frame) { _, frame in onContentFrameChange(identifier, frame) }
    }
  }

  private func cardThumbnail(_ state: SaveStateInfo?, slot: Int?) -> some View {
    ZStack {
      ICubeDesign.color(.rowSurface)
      if let state, let image = thumbnails[state.path] {
        Image(uiImage: image).resizable().scaledToFit()
      } else {
        VStack(spacing: ICubeDesign.Spacing.xxs.rawValue) {
          Image(systemName: state == nil ? "plus" : "photo").font(ICubeDesign.symbolFont(.rail))
          Text(state == nil ? L("Empty") : L("No preview")).icubeText(.detail)
        }
      }
    }
    .aspectRatio(16.0 / 9.0, contentMode: .fit)
    .clipped()
    .background(contentFrameObserver("\(cardIdentifier(state, slot: slot)).thumbnail"))
  }

  private func cardOccupancy(_ state: SaveStateInfo?, slot: Int?) -> some View {
    Text(state == nil ? L("Empty · ready to save") : L("Occupied")).icubeText(.detail)
      .background(contentFrameObserver("\(cardIdentifier(state, slot: slot)).occupancy"))
  }

  private func cardTitleText(_ state: SaveStateInfo?, slot: Int?) -> some View {
    Text(cardTitle(state, slot: slot)).icubeText(.body).fontWeight(.semibold)
      .background(contentFrameObserver("\(cardIdentifier(state, slot: slot)).title"))
  }

  @ViewBuilder
  private func cardTimestamp(_ state: SaveStateInfo, slot: Int?) -> some View {
    if let date = state.modifiedAt ?? state.createdAt {
      Text(date.formatted(date: .abbreviated, time: .shortened)).icubeText(.detail)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(date.formatted(date: .complete, time: .shortened))
        .background(contentFrameObserver("\(cardIdentifier(state, slot: slot)).timestamp"))
    } else { Text(L("Date unavailable")).icubeText(.detail) }
  }

  @ViewBuilder
  private func cardStatusBadges(_ state: SaveStateInfo) -> some View {
    if state.path == manualStates.first?.path { Text(L("Latest manual")).icubeText(.tag) }
    if !state.isCompatible { Text(L("Incompatible")).icubeText(.detail).foregroundStyle(ICubeDesign.color(.destructive)) }
  }

  private func cardMetadata(_ state: SaveStateInfo?, slot: Int?, compact: Bool) -> some View {
    VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xxs.rawValue) {
      if compact && !dynamicTypeSize.isAccessibilitySize {
        HStack(alignment: .firstTextBaseline, spacing: ICubeDesign.Spacing.xs.rawValue) {
          cardTitleText(state, slot: slot)
          Spacer(minLength: ICubeDesign.Spacing.xs.rawValue)
          if let state { cardTimestamp(state, slot: slot) }
        }
        HStack(alignment: .firstTextBaseline, spacing: ICubeDesign.Spacing.xs.rawValue) {
          cardOccupancy(state, slot: slot)
          if let state { cardStatusBadges(state) }
        }
      } else {
        cardTitleText(state, slot: slot)
        cardOccupancy(state, slot: slot)
        if let state {
          cardStatusBadges(state)
          cardTimestamp(state, slot: slot)
        }
      }
    }
  }

  private func cardTitle(_ state: SaveStateInfo?, slot: Int?) -> String {
    if let slot { return String(format: L("Slot %d"), slot) }
    if state?.isAuto == true { return L("Automatic resume") }
    return state?.displayName ?? L("Save State")
  }

  private var historyRetention: some View {
    VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xs.rawValue) {
        Text(L("10 recent quick saves. Kept saves, classic slots and automatic resume stay separate."))
          .icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary))
        if let state = selectedState, state.isQuickSave {
          Button(state.isKept ? L("Kept — remove keep") : L("Keep this save")) {
            guard !busy else { return }
            busy = true
            Task { @MainActor in
              defer { busy = false }
              guard matchesCurrentSession(), let openingSessionIdentifier else { return }
              let session = QuickSaveSurfaceSession(gameID: gameID, identifier: openingSessionIdentifier)
              let outcome = await operations.setKept(state, !state.isKept, session)
              report(outcome)
              if outcome.isSuccess { await reload() }
            }
          }
          .buttonStyle(ICubeRowButtonStyle())
          .frame(minHeight: TopBarLayout.minimumTarget)
          .disabled(busy)
        }
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xs.rawValue) {
      Divider()
      if dynamicTypeSize.isAccessibilitySize {
        VStack(spacing: ICubeDesign.Spacing.xs.rawValue) { footerActions }
      } else {
        HStack(spacing: ICubeDesign.Spacing.xs.rawValue) { footerActions }
      }
    }
  }

  @ViewBuilder
  private var footerActions: some View {
    Button(effectiveMode == .history ? L("Save new state") : String(format: L("Save to slot %d"), selectedSlot)) {
      if effectiveMode == .slots { requestClassicSave(selectedSlot) }
      else { performSave(mode: .history, slot: selectedSlot) }
    }
    .buttonStyle(ICubeRowButtonStyle())
    .frame(minHeight: TopBarLayout.minimumTarget)
    .disabled(busy || (effectiveMode == .slots && !scan.hasCompletedScan))
    .accessibilityIdentifier("quick-save-picker.save")
    Button(L("Load selected")) {
      guard let state = selectedState else { return }
      guard !busy else { return }
      busy = true
      Task { @MainActor in
        defer { busy = false }
        guard matchesCurrentSession(), let openingSessionIdentifier else { return }
        let session = QuickSaveSurfaceSession(gameID: gameID, identifier: openingSessionIdentifier)
        guard let outcome = await QuickSaveSurfaceActions.load(state, session: session,
          isCurrent: { $0.gameID == gameID && sessionIsCurrent($0.gameID, $0.identifier) && surfaceIsActive },
          operation: { await operations.load($0, session) }) else { return }
        report(outcome)
        if outcome.isSuccess && matchesCurrentSession() { onDismiss() }
      }
    }
    .buttonStyle(ICubeRowButtonStyle())
    .frame(minHeight: TopBarLayout.minimumTarget)
    .disabled(!QuickSavePickerModel.canLoad(selectedState, busy: busy))
    .accessibilityIdentifier("quick-save-picker.load")
  }

  private func requestClassicSave(_ slot: Int) {
    guard !busy, matchesCurrentSession(), let openingSessionIdentifier else { return }
    let session = QuickSaveSurfaceSession(gameID: gameID, identifier: openingSessionIdentifier)
    let destination = operations.slotDestination(slot)
    switch scan.prepareSave(slot: slot, session: session, destination: destination,
                            occupancy: destination.map(operations.occupancy) ?? .unknown) {
    case .unavailable: report(.unavailable)
    case .confirm(let request): overwriteRequest = request
    case .save(let request): performSave(mode: .slots, slot: slot, request: request)
    }
  }

  private func performSave(mode: QuickSaveMode, slot: Int,
                           request: QuickSaveSlotSaveRequest? = nil, confirmed: Bool = false) {
    guard !busy else { return }
    busy = true
    Task { @MainActor in
      defer { busy = false }
      guard matchesCurrentSession() else { return }
      let outcome: QuickSaveActions.Outcome
      if mode == .slots {
        guard let request, let result = await scan.save(request, confirmed: confirmed,
          isCurrent: { $0.gameID == gameID && $0.identifier == openingSessionIdentifier && matchesCurrentSession() },
          destination: operations.slotDestination, occupancy: operations.occupancy,
          operation: { await operations.saveSlot(.init(request: $0, allowsOverwrite: confirmed)) }) else { return }
        outcome = result
      } else {
        outcome = await operations.save(mode, slot)
      }
      report(outcome)
      if outcome.isSuccess && matchesCurrentSession() { await reload() }
    }
  }

  private func matchesCurrentSession() -> Bool {
    guard surfaceIsActive, let openingSessionIdentifier else { return false }
    return sessionIsCurrent(gameID, openingSessionIdentifier)
  }

  @MainActor
  private func report(_ outcome: QuickSaveActions.Outcome) {
    if matchesCurrentSession(), !outcome.message.isEmpty { EmulationToast.post(outcome.message) }
  }

  @MainActor
  private func reload() async {
    await scan.reload {
      QuickSavePickerModel.visibleStates(await provider.states(for: gameID), modded: isModded())
    }
    guard !Task.isCancelled else { return }
    selection.reconcile(states: states)
    for state in states {
      if let image = await provider.thumbnail(for: state) { thumbnails[state.path] = image }
    }
  }
}

