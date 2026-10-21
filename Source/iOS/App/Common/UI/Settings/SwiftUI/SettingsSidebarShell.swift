// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// What Menu does with focus in the sidebar. The pane can still show a page pushed from its leaf: focus
/// lands in the sidebar when that page has nothing focusable yet (Help while it loads) or after Left from
/// it. Leaving Settings then closed it from two levels deep; Back pops that page instead.
enum SettingsSidebarBack: Equatable {
  case popPane
  case focusSidebar
  case leaveSettings
  /// The release of the press that opened Settings (`BackCoalescer`).
  case ignore

  /// - Parameters:
  ///   - paneDepth: pages pushed on top of the pane's leaf.
  ///   - honorsPress: whether `BackCoalescer` lets this press close Settings.
  static func action(paneDepth: Int, honorsPress: Bool, sidebarFocused: Bool = true) -> SettingsSidebarBack {
    if paneDepth > 0 { return .popPane }
    if !sidebarFocused { return .focusSidebar }
    return honorsPress ? .leaveSettings : .ignore
  }
}

/// tvOS and iPad (regular width): a sidebar of leaf pages grouped under section headers, and the selected
/// leaf in the pane. The sidebar is its own focus section; right enters the pane. Back (Menu / B) from a
/// leaf returns to the sidebar; Menu at the sidebar pops a page still pushed in the pane, and otherwise
/// leaves Settings (through `BackCoalescer`, so the press that opened Settings cannot close it again).
struct SettingsSidebarShell: View {
  let sections: [SettingsRootSection]
  let searchIndex: SettingsSearchIndex?
  @Binding var jumpToLeafID: String?
  /// iPad in the pause menu's sheet: the Close button `SettingsRootView` was given.
  var onClose: (() -> Void)? = nil
  /// A deep link's row: while one is pending, focus goes to that row in the pane instead of the sidebar entry.
  @Environment(\.settingsRowTarget) private var rowTarget

  @State private var selectedID: String?
  @FocusState private var sidebarFocus: String?
  #if !os(tvOS)
  @Environment(\.icube) private var theme
  @ScaledMetric(relativeTo: .body) private var padSidebarWidth = Layout.sidebarWidthPad
  @ScaledMetric(relativeTo: .body) private var padIconWidth = Layout.iconWidth
  #endif
  #if os(tvOS)
  @State private var openedAt = Date()
  /// True while focus is on a pane row that left/right adjust (`settingsPaneHoldsLeft`): the sidebar is
  /// then not focusable, so left steps the value instead of leaving the row.
  @State private var paneHoldsLeft = false
  @State private var sidebarFocusTransferPending = false
  @State private var paneNavigation = SettingsPaneNavigation()
  @Environment(\.dismiss) private var dismiss
  #else
  @State private var searchText = ""
  #endif

  private enum Layout {
    /// Fits the longest uppercase nav label ("PERFORMANCE TUNING") on one line; longer ones wrap.
    static let sidebarWidthTV: CGFloat = 440
    /// At the default text size; scales with Dynamic Type, capped at `sidebarMaxFractionPad` of the screen.
    static let sidebarWidthPad: CGFloat = 280
    /// Leaves the pane most of the width in split view and at accessibility text sizes; labels wrap instead.
    static let sidebarMaxFractionPad: CGFloat = 0.38
    static let iconWidth: CGFloat = 28
    static let rowRadius: CGFloat = 10
    static let selectedOpacity = 0.25
    static let headerTopPadding: CGFloat = 18
    static let rowStackSpacing: CGFloat = 6
    static let rowContentSpacing: CGFloat = 12
    static let rowHorizontalPadding: CGFloat = 12
    static let rowVerticalPadding: CGFloat = 10
    static let listHorizontalPadding: CGFloat = 12
    static let listVerticalPadding: CGFloat = 24
  }

  private var entries: [SettingsLeafEntry] { sections.flatMap(\.entries) }
  private var selected: SettingsLeafEntry? { entries.first { $0.id == selectedID } }

  var body: some View {
    HStack(spacing: 0) {
      sidebar
        #if os(tvOS)
        .frame(width: Layout.sidebarWidthTV)
        .disabled(paneHoldsLeft)
        .focusSection()
        // Left from the pane lands on the page it shows, not on whichever entry is level with the row.
        .defaultFocus($sidebarFocus, selectedID, priority: .userInitiated)
        .onExitCommand(perform: leaveSettings)
        #else
        .containerRelativeFrame(.horizontal) { length, _ in min(padSidebarWidth, length * Layout.sidebarMaxFractionPad) }
        #endif
      #if os(tvOS)
      Rectangle().fill(ICubeDesign.color(.hairline)).frame(width: ICubeDesign.Line.hairline.rawValue)
      #else
      Divider()
      #endif
      NavigationStack {
        if let selected {
          selected.makeView().id(selected.id)
            // Only the pane's root leaf: a sub-leaf pushed from it is a different view, so Menu pops it natively.
            #if os(tvOS)
            .onExitCommand(perform: backToSidebar)
            .background { SettingsPaneNavigationReader(navigation: paneNavigation) }
            #endif
        } else {
          #if os(tvOS)
          Text(L("Choose a page"))
            .icubeText(.nav)
            .foregroundStyle(ICubeDesign.color(.textSecondary))
          #else
          Text(L("Choose a page")).foregroundStyle(.secondary)
          #endif
        }
      }
      #if os(tvOS)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background { ICubeRoom(style: .gradient) }
      #endif
      // A leaf in the pane is the root of this stack: its Back must return to the sidebar, not dismiss Settings.
      #if os(tvOS)
      .environment(\.settingsPaneBack, backToSidebar)
      .environment(\.settingsPaneHoldsLeft, { paneHoldsLeft = $0 })
      .focusSection()
      #else
      .environment(\.settingsPaneBack, { sidebarFocus = selectedID })
      #endif
    }
    .defaultFocus($sidebarFocus, selectedID ?? sections.first?.entries.first?.id)
    .onAppear {
      #if os(tvOS)
      openedAt = Date()
      #endif
      if selectedID == nil { selectedID = sections.first?.entries.first?.id }
      consumeJump()
    }
    .onChange(of: jumpToLeafID) { _, _ in consumeJump() }
  }

  /// A deep link (DSU → "controllers") or a debug preview lands on one leaf.
  private func consumeJump() {
    guard let id = jumpToLeafID, entries.contains(where: { $0.id == id }) else { jumpToLeafID = nil; return }
    selectedID = id
    if rowTarget?.isPending != true { sidebarFocus = id }
    jumpToLeafID = nil
  }

  #if os(tvOS)
  /// Menu with focus in the sidebar: pop a page still pushed in the pane, else leave Settings unless it is
  /// the release of the press that opened it.
  private func leaveSettings() {
    guard !sidebarFocusTransferPending else { return }
    switch SettingsSidebarBack.action(paneDepth: paneNavigation.depth,
                                      honorsPress: BackCoalescer.shouldHonor(openedAt: openedAt, now: Date()),
                                      sidebarFocused: sidebarFocus != nil) {
    case .popPane: paneNavigation.pop()
    case .focusSidebar: backToSidebar()
    case .leaveSettings: dismiss()
    case .ignore: break
    }
  }

  /// Menu in the pane: a hand-built leaf's exit command, or a migrated leaf's `settingsPaneBack`.
  /// Back from an adjustable row first gives the sidebar its focus back; the focus move waits a
  /// runloop turn, until the sidebar is focusable again.
  private func backToSidebar() {
    guard !sidebarFocusTransferPending else { return }
    sidebarFocusTransferPending = true
    paneHoldsLeft = false
    // All rows use the same deferred transfer. A duplicate callback during this
    // command must not see the new sidebar focus and dismiss the whole Settings cover.
    DispatchQueue.main.async {
      sidebarFocus = selectedID
      sidebarFocusTransferPending = false
    }
  }
  #endif

  @ViewBuilder
  private var sidebar: some View {
    #if os(iOS)
    NavigationStack {
      Group {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
          sidebarList
        } else {
          SettingsSearchResults(hits: searchIndex?.hits(query: searchText) ?? [], entries: entries) { entry in
            selectedID = entry.id
            searchText = ""
          }
        }
      }
      .navigationTitle(L("Settings"))
      .searchable(text: $searchText, prompt: L("Search Settings"))
      .toolbar {
        if let onClose {
          ToolbarItem(placement: .navigationBarTrailing) { Button(L("Close"), action: onClose) }
        }
      }
    }
    #else
    sidebarList
    #endif
  }

  private var sidebarList: some View {
    #if os(tvOS)
    tvSidebarList
    #else
    padSidebarList
    #endif
  }

  #if os(tvOS)
  /// Token sidebar: accent section headers, nav labels, selected fill, focus ring. Not the stock list.
  private var tvSidebarList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xs.rawValue) {
        ForEach(sections) { section in
          HStack(spacing: ICubeDesign.Spacing.xs.rawValue) {
            Capsule()
              .fill(ICubeDesign.color(.accent))
              .frame(width: ICubeDesign.Line.focus.rawValue, height: ICubeDesign.Spacing.l.rawValue)
            Text(section.header)
              .icubeText(.section)
              .foregroundStyle(ICubeDesign.color(.textPrimary))
          }
          .padding(.top, ICubeDesign.Spacing.m.rawValue)
          ForEach(section.entries) { entry in
            let isSelected = selectedID == entry.id
            Button { selectedID = entry.id } label: {
              HStack(spacing: ICubeDesign.Spacing.s.rawValue) {
                Image(systemName: entry.icon)
                  .font(ICubeDesign.symbolFont(.rail))
                  .frame(width: ICubeDesign.Symbol.railColumn)
                Text(entry.title)
                  .icubeText(.nav)
                  .multilineTextAlignment(.leading)
                  .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
              }
              .foregroundStyle(isSelected ? ICubeDesign.color(.accent) : ICubeDesign.color(.textPrimary))
            }
            .buttonStyle(ICubeRowButtonStyle(isSelected: isSelected))
            .focused($sidebarFocus, equals: entry.id)
            .accessibilityIdentifier("settings.category.\(entry.id)")
          }
        }
      }
      .padding(ICubeDesign.Spacing.l.rawValue)
    }
    .icubePanel()
  }
  #endif

  #if !os(tvOS)
  /// iPad touch sidebar. Unchanged from the stock row treatment.
  private var padSidebarList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Layout.rowStackSpacing) {
        ForEach(sections) { section in
          Text(section.header)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, Layout.headerTopPadding)
            .padding(.horizontal, Layout.rowHorizontalPadding)
          ForEach(section.entries) { entry in
            Button { selectedID = entry.id } label: {
              HStack(spacing: Layout.rowContentSpacing) {
                Image(systemName: entry.icon).frame(width: padIconWidth)
                Text(entry.title)
                  .multilineTextAlignment(.leading)
                  .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
              }
              .padding(.horizontal, Layout.rowHorizontalPadding)
              .padding(.vertical, Layout.rowVerticalPadding)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(
                RoundedRectangle(cornerRadius: Layout.rowRadius, style: .continuous)
                  .fill(selectedID == entry.id ? theme.tileAccent.opacity(Layout.selectedOpacity) : .clear))
            }
            .buttonStyle(FocusButtonStyle())
            .focused($sidebarFocus, equals: entry.id)
            .accessibilityIdentifier("settings.category.\(entry.id)")
          }
        }
      }
      .padding(.horizontal, Layout.listHorizontalPadding)
      .padding(.vertical, Layout.listVerticalPadding)
    }
  }
  #endif
}

#if os(tvOS)
/// The pane's navigation controller, reached from its root leaf. SwiftUI exposes neither the depth nor a pop
/// for pages pushed with `NavigationLink(destination:)` or `navigationDestination(item:)`, and the sidebar
/// is outside the stack, so it cannot use their `dismiss`. A UIKit pop is the one the back button does.
final class SettingsPaneNavigation {
  fileprivate weak var controller: UINavigationController?

  var depth: Int { max((controller?.viewControllers.count ?? 1) - 1, 0) }

  func pop() { controller?.popViewController(animated: true) }
}

/// Records the navigation controller while the root leaf is on screen. It has to be found then: SwiftUI
/// tears this view down once a pushed page covers the leaf.
private struct SettingsPaneNavigationReader: UIViewRepresentable {
  let navigation: SettingsPaneNavigation

  final class Anchor: UIView {
    var navigation: SettingsPaneNavigation?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      guard window != nil,
            let controller = sequence(first: self as UIResponder, next: { $0.next })
              .lazy.compactMap({ $0 as? UINavigationController }).first else { return }
      navigation?.controller = controller
    }
  }

  func makeUIView(context: Context) -> Anchor {
    let view = Anchor()
    view.isUserInteractionEnabled = false
    view.navigation = navigation
    return view
  }

  func updateUIView(_ view: Anchor, context: Context) {
    view.navigation = navigation
  }
}
#endif
