// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import GameController
import SwiftUI

/// iOS-only visual treatment for `MenuScreen`. tvOS ignores this and always
/// renders one `List` row per item (design doc §2's tvOS contract) — a
/// compound row is the one thing that reliably breaks tvOS focus, so the
/// tvOS renderer is not parameterized by style at all.
enum MenuStyle {
  /// Pause-menu card grid — the §5 style-preservation token table
  /// (`menuButtonIOS`/`menuRowIOS`). Visual fidelity is unverified against a
  /// device/screenshot compare; see the design doc's Implementation Status.
  case grid
  /// Plain `List` of rows — the shape Settings/Cheats/Controllers already use.
  case list
}

/// D18: one view that renders a `MenuModel`, owning focus and controller
/// navigation. See `docs/superpowers/specs/2026-09-24-data-driven-menus-design.md`.
///
/// - iOS drives a `focusedID` from raw `GCController` **polling** through
///   `MenuFocusRouter` — like `RemapPlayerView`, not a `valueChangedHandler`
///   install. That is a deliberate deviation from the design doc's §2 prose
///   (which describes a `valueChangedHandler`-based router): a handler is a
///   single process-wide slot, and `PauseMenuView.setupPauseControllerNav`
///   already owns it while the pause menu's main pane is up. Polling can
///   never contend for that slot, which is the same reasoning
///   `RemapPlayerView`'s doc comment gives for why IT polls. See the
///   Implementation Status section of the design doc.
/// - tvOS installs zero GameController code and uses only native focus
///   (`@FocusState`, `List`, `.defaultFocus`, `.onExitCommand`).
///
/// Every instance claims its own `ControllerFocusCoordinator` scope for its
/// on-screen lifetime (`.controllerScope(_:)`) so a `MenuScreen` presented
/// over another one silences the covered screen's input even though SwiftUI
/// does not fire `onDisappear` for a merely-covered view (design doc §2/§3).
struct MenuScreen: View {
  let model: MenuModel
  var style: MenuStyle = .list
  /// Fires on B / tvOS `.onExitCommand`. `nil` for a screen with nothing to
  /// pop to. `MenuScreen` never calls `dismiss()` itself — the caller decides
  /// what "back" means (pop a nav pane, dismiss a sheet, flip a host's own
  /// `@State` pane enum, as `PauseMenuView`'s `CheatsMenuView(onBack:)` does).
  var onBack: (() -> Void)?

  /// `.navigationDestination(item:)` requires `Hashable`, not just
  /// `Identifiable` — `MenuModel` itself can't be `Hashable` (it holds
  /// closures/`Binding`s), so identity is keyed on `id` alone.
  private struct PushedMenu: Identifiable, Hashable {
    let id = UUID()
    let model: MenuModel

    static func == (lhs: PushedMenu, rhs: PushedMenu) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
  }

  @State private var pushedChild: PushedMenu?

  #if os(iOS)
  @State private var router = MenuFocusRouter()
  /// `nil` until a controller actually moves focus. Kept `nil` for a
  /// touch-only session so `.listRowBackground`'s focus tint never appears
  /// on a device with no controller connected — matching `PauseMenuView`,
  /// which only draws its ring while `pauseMenuControllerNavActive`.
  @State private var focusedID: String?
  @State private var scopeID = UUID()
  /// The first tick after appearing must `resync`, not `update` — the A that
  /// pushed this screen (from a parent `.navigation` item) is still
  /// physically held, and this screen defaults focus to its first item on
  /// that same tick (unlike `RemapPlayerView`, which starts with no
  /// highlight). See `MenuFocusRouter.resync`'s doc comment.
  @State private var hasSyncedInitialInput = false
  /// Single shared 60 Hz publisher rather than a per-instance `Timer`. This
  /// matters for correctness, not just efficiency: a `Timer(... ) { tick() }`
  /// closure captures `self` — and therefore `model`, a `let` — from
  /// whatever render created it, so it goes stale the instant a later render
  /// passes a different `model` (e.g. Cheats' list arriving after
  /// `loadCheats()` completes post-appear). `.onReceive` re-registers its
  /// action closure on every render, so `tick()` always sees the current one.
  private static let navTick = Timer.publish(every: 1.0 / 60, on: .main, in: .common).autoconnect()
  #else
  @FocusState private var tvFocusedID: String?
  #endif

  var body: some View {
    content
      .navigationDestination(item: $pushedChild) { child in
        MenuScreen(model: child.model, style: style, onBack: { pushedChild = nil })
      }
      #if os(iOS)
      .controllerScope(scopeID)
      .onAppear { hasSyncedInitialInput = false }
      .onReceive(Self.navTick) { _ in tick() }
      .onChange(of: model.focusableIDs) { oldOrder, _ in
        // Only reconciles a focus that already exists — a touch-only session
        // (focusedID still nil) must not be given one just because the model
        // was rebuilt.
        guard focusedID != nil else { return }
        focusedID = MenuFocusRouter.reconcile(focusedID: focusedID, previousOrder: oldOrder, model: model)
      }
      #else
      .onExitCommand { onBack?() }
      #endif
  }

  @ViewBuilder
  private var content: some View {
    #if os(iOS)
    switch style {
    case .grid: gridBody
    case .list: listBody
    }
    #else
    tvListBody
    #endif
  }

  // MARK: Shared row content

  private func rowLabel(title: String, subtitle: String?, icon: String?, tint: Color?, badge: String?) -> some View {
    HStack(spacing: 12) {
      if let icon {
        Image(systemName: icon)
          .foregroundStyle(tint ?? .accentColor)
          .frame(width: 44, height: 44)
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill((tint ?? .accentColor).opacity(0.15))
          )
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        if let subtitle {
          Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer()
      if let badge {
        Text(badge).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func rowLabel(_ item: MenuItem) -> some View {
    rowLabel(title: item.title, subtitle: item.subtitle, icon: item.icon, tint: item.tint, badge: item.badge)
  }

  /// Shared by every renderer: what happens when an item is activated,
  /// whether by a controller `.activate` edge or (on tvOS/for `.navigation`)
  /// a direct tap. `.destination`/`.custom` are escape hatches — the embedded
  /// `AnyView` owns its own gesture handling, so activation is a no-op here
  /// (a `NavigationLink`'s own tap already does the pushing for `.destination`).
  private func performActivate(_ item: MenuItem) {
    guard item.isEnabled else { return }
    switch item.role {
    case .action(let action), .destructive(let action):
      action()
    case .toggle(let binding):
      binding.wrappedValue.toggle()
    case .picker(let options, let selection):
      guard !options.isEmpty else { return }
      let currentIndex = options.firstIndex { $0.1 == selection.wrappedValue } ?? -1
      selection.wrappedValue = options[(currentIndex + 1) % options.count].1
    case .navigation(let makeChild):
      pushedChild = PushedMenu(model: makeChild())
    case .destination, .custom:
      break
    }
  }

  // MARK: iOS — list style

  #if os(iOS)
  private var listBody: some View {
    ScrollViewReader { proxy in
      List {
        ForEach(model.sections) { section in
          listSection(section)
        }
      }
      .onChange(of: focusedID) { _, id in
        if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
      }
    }
  }

  @ViewBuilder
  private func listSection(_ section: MenuSection) -> some View {
    if let header = section.header {
      Section(header: Text(header)) {
        ForEach(section.items) { item in listRow(item) }
      }
    } else {
      Section {
        ForEach(section.items) { item in listRow(item) }
      }
    }
  }

  @ViewBuilder
  private func listRow(_ item: MenuItem) -> some View {
    Group {
      switch item.role {
      case .toggle(let binding):
        Toggle(isOn: binding) { rowLabel(item) }
      case .picker(let options, let selection):
        Picker(selection: Binding(get: { selection.wrappedValue }, set: { selection.wrappedValue = $0 })) {
          ForEach(options, id: \.1) { option in
            Text(option.0).tag(option.1)
          }
        } label: {
          rowLabel(item)
        }
        .pickerStyle(.menu)
      case .destination(let destinationView):
        NavigationLink { destinationView } label: { rowLabel(item) }
      case .custom(let customView):
        customView
      case .navigation, .action, .destructive:
        Button { performActivate(item) } label: { rowLabel(item) }
      }
    }
    .disabled(!item.isEnabled)
    .id(item.id)
    .listRowBackground(focusedID == item.id ? Color.accentColor.opacity(0.22) : nil)
  }

  // MARK: iOS — grid style (pause-menu card look, §5 token table)

  private var gridBody: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        ForEach(model.sections) { section in
          if let header = section.header {
            Text(header).font(.headline).foregroundStyle(.white)
          }
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
            ForEach(section.items) { item in gridCard(item) }
          }
        }
      }
      .padding(16)
    }
  }

  @ViewBuilder
  private func gridCard(_ item: MenuItem) -> some View {
    Button { performActivate(item) } label: {
      rowLabel(
        title: item.title, subtitle: item.subtitle, icon: item.icon, tint: item.tint, badge: item.badge
      )
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(.ultraThinMaterial)
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .stroke(Color.white.opacity(0.08), lineWidth: 1)
          )
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(Color.accentColor, lineWidth: 3)
          .opacity(focusedID == item.id ? 1 : 0)
      )
    }
    .buttonStyle(.plain)
    .disabled(!item.isEnabled)
    .id(item.id)
  }

  // MARK: iOS — controller polling

  private func navGamepad() -> GCExtendedGamepad? {
    GCController.controllers().first { $0.extendedGamepad != nil }?.extendedGamepad
  }

  private func navInput(_ pad: GCExtendedGamepad) -> MenuControllerNav.Input {
    MenuControllerNav.Input(
      up: pad.dpad.up.isPressed,
      down: pad.dpad.down.isPressed,
      stickY: pad.leftThumbstick.yAxis.value,
      a: pad.buttonA.isPressed,
      b: pad.buttonB.isPressed,
      leftShoulder: pad.leftShoulder.isPressed,
      rightShoulder: pad.rightShoulder.isPressed
    )
  }

  private func tick() {
    guard let pad = navGamepad() else { return }
    let input = navInput(pad)
    let time = CACurrentMediaTime()
    guard hasSyncedInitialInput else {
      hasSyncedInitialInput = true
      router.resync(input, at: time)
      // Focus only ever appears once a controller is actually present —
      // never seeded in `.onAppear`, so a touch-only session shows no tint.
      if focusedID == nil { focusedID = model.focusableIDs.first }
      return
    }
    let isActive = ControllerFocusCoordinator.isActiveScope(scopeID)
    let result = router.update(input, at: time, model: model, focusedID: focusedID, isActive: isActive)
    focusedID = result.focusedID
    if let activatedID = result.activatedID, let item = model.item(id: activatedID) {
      performActivate(item)
    }
    if result.didGoBack {
      onBack?()
    }
  }
  #endif

  // MARK: tvOS — native focus only

  #if os(tvOS)
  @ViewBuilder
  private var tvListBody: some View {
    let list = List {
      ForEach(model.sections) { section in
        tvSection(section)
      }
    }
    if let first = model.focusableIDs.first {
      list.defaultFocus($tvFocusedID, first)
    } else {
      list
    }
  }

  @ViewBuilder
  private func tvSection(_ section: MenuSection) -> some View {
    if let header = section.header {
      Section(header: Text(header)) {
        ForEach(section.items) { item in tvRow(item) }
      }
    } else {
      Section {
        ForEach(section.items) { item in tvRow(item) }
      }
    }
  }

  /// One `MenuItem` -> one `List` row with exactly one control, per the
  /// design doc's §2 tvOS contract — except `.picker`, which explodes into
  /// one row per option (checkmark for the selection) because a `Picker`
  /// embedded in a row has no usable tvOS presentation (the same reasoning
  /// `ControllerSetupView.wiiOptionRows`/`tvOptionRow` already documents).
  @ViewBuilder
  private func tvRow(_ item: MenuItem) -> some View {
    switch item.role {
    case .picker(let options, let selection):
      ForEach(options, id: \.1) { option in
        Button {
          selection.wrappedValue = option.1
        } label: {
          HStack {
            rowLabel(title: option.0, subtitle: nil, icon: nil, tint: nil, badge: nil)
            Spacer()
            if option.1 == selection.wrappedValue {
              Image(systemName: "checkmark")
            }
          }
        }
        .disabled(!item.isEnabled)
      }
    case .toggle(let binding):
      Button {
        binding.wrappedValue.toggle()
      } label: {
        HStack {
          rowLabel(item)
          Spacer()
          if binding.wrappedValue {
            Image(systemName: "checkmark")
          }
        }
      }
      .disabled(!item.isEnabled)
    case .destination(let destinationView):
      NavigationLink { destinationView } label: { rowLabel(item) }
        .disabled(!item.isEnabled)
    case .custom(let customView):
      customView
    case .navigation, .action, .destructive:
      Button { performActivate(item) } label: { rowLabel(item) }
        .disabled(!item.isEnabled)
    }
  }
  #endif
}
