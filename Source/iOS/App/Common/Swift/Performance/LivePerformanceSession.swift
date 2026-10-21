// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
#if os(tvOS)
import Combine
import GameController
import UIKit

/// Reads only the leased physical remote. It never installs controller handlers or takes TV focus.
@MainActor
final class LivePerformanceSession: ObservableObject {
  static let shared = LivePerformanceSession()
  @Published private(set) var isPresented = false
  @Published private(set) var rows: [MenuItem] = []
  @Published private(set) var navigation = RemotePerformanceNavigation()
  private let ownership = LivePerformanceOwnership()
  private let controls: PerformanceControlsController
  private var owner: UUID?
  private var gameSession: () -> String? = { nil }
  private var canOpen: () -> Bool = { false }
  private var onPause: () -> Void = {}
  private var onControllerUnavailable: () -> Void = {}
  private var remote: GCController?
  private var lease: DOLControllerInputLease?
  private let pending = LivePerformanceReleaseFence<GCController>()
  private var input = LivePerformanceRemoteInput()
  private var openingNeutral = false
  private var timer: Timer?
  private var observers: [NSObjectProtocol] = []
  private var stateObserver: AnyCancellable?

  init(controls: PerformanceControlsController = .live()) {
    self.controls = controls
    stateObserver = controls.$state.sink { [weak self] _ in
      // @Published sends before assignment. Rebuild after the new snapshot is installed.
      Task { @MainActor [weak self] in if self?.isPresented == true { self?.rebuild() } }
    }
    observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
      object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.close() } })
  }

  func attach(owner: UUID, gameSession: @escaping () -> String?, canOpen: @escaping () -> Bool,
              onPause: @escaping () -> Void, onControllerUnavailable: @escaping () -> Void) {
    if self.owner != owner { close() }
    self.owner = owner
    self.gameSession = gameSession
    self.canOpen = canOpen
    self.onPause = onPause
    self.onControllerUnavailable = onControllerUnavailable
  }

  func detach(owner: UUID) {
    guard self.owner == owner else { return }
    close()
    self.owner = nil
    gameSession = { nil }; canOpen = { false }; onPause = {}; onControllerUnavailable = {}
  }

  /// Caller routes a coalesced short Menu press; this class deliberately never polls Menu.
  @discardableResult func toggleFromRemote() -> Bool {
    if isPresented { return handleBack() }
    guard owner != nil, canOpen(), let session = gameSession(),
          let candidate = GCController.controllers().first(where: Self.isRemote),
          Self.hasGameplayController(), UIApplication.shared.applicationState == .active else { return false }
    guard ownership.open(session: session) else { return false }
    remote = candidate
    lease = DOLControllerInputLease(controller: candidate)
    input = LivePerformanceRemoteInput()
    openingNeutral = true
    controls.refresh()
    navigation = RemotePerformanceNavigation()
    rebuild()
    isPresented = true
    startPolling()
    return true
  }

  @discardableResult func handleBack() -> Bool {
    guard isPresented else { return false }
    if navigation.choiceIndex != nil { navigation.cancelChoices() }
    else { close() }
    return true
  }

  /// Used after an external Pause route has already claimed pending ownership.
  func closeForPause() { close() }

  #if DEBUG
  /// Read-only rendering fixture; it neither opens a controller lease nor starts input polling.
  func prepareRenderingPreview() {
    guard owner == nil, remote == nil else { return }
    controls.refresh()
    navigation = RemotePerformanceNavigation()
    rebuild()
    isPresented = true
  }
  #endif

  static func isRemote(_ controller: GCController) -> Bool {
    controller.microGamepad != nil && controller.extendedGamepad == nil
  }

  static func hasGameplayController() -> Bool {
    GCController.controllers().contains { $0.extendedGamepad != nil ||
      ($0.microGamepad == nil && !$0.physicalInputProfile.buttons.isEmpty) }
  }

  private func startPolling() {
    guard timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.poll() }
    }
  }

  private func poll() {
    let connected = GCController.controllers()
    pending.reap(connected: connected)
    guard isPresented else {
      if pending.isEmpty { timer?.invalidate(); timer = nil }
      return
    }
    ownership.reconcile(session: gameSession())
    guard ownership.isPresented, UIApplication.shared.applicationState == .active else { close(); return }
    // The host must adopt its disconnect pause synchronously before the overlay relinquishes ownership.
    guard Self.hasGameplayController() else {
      ownership.transitionToPause(claim: onControllerUnavailable)
      close()
      return
    }
    guard canOpen() else { close(); return }
    guard let remote, connected.contains(where: { $0 === remote }) else {
      lease?.forceReleaseForDisconnect(); lease = nil; close(); return
    }
    guard let micro = remote.microGamepad else { close(); return }
    if openingNeutral {
      let buttonsNeutral = remote.physicalInputProfile.buttons.values.allSatisfy { !$0.isPressed && $0.value < 0.05 }
      let axesNeutral = remote.physicalInputProfile.axes.values.allSatisfy { abs($0.value) < 0.2 }
      guard buttonsNeutral && axesNeutral else { return }
      openingNeutral = false
    }
    let actions = input.poll(horizontal: micro.dpad.xAxis.value, vertical: micro.dpad.yAxis.value,
                             select: micro.buttonA.isPressed, now: ProcessInfo.processInfo.systemUptime)
    for action in actions {
      guard isPresented else { break }
      switch action {
      case .up: navigation.move(-1)
      case .down: navigation.move(1)
      case .left: adjust(-1)
      case .right: adjust(1)
      case .select: select()
      }
    }
  }

  private func close() {
    controls.stopRefreshing()
    ownership.close()
    isPresented = false
    navigation.cancelChoices()
    if let remote, let lease {
      pending.retain(controller: remote, request: { lease.requestRelease() },
        poll: { lease.pollRelease() }, disconnect: { lease.forceReleaseForDisconnect() })
      startPolling()
    }
    remote = nil; lease = nil
  }

  private func rebuild() {
    rows = PerformanceControlsModelBuilder.build(state: controls.state, apply: { [weak self] in self?.controls.apply($0) }).allItems
    rows.append(MenuItem(id: "live-performance-pause", title: L("Pause Menu"), icon: "pause.fill", role: .action { [weak self] in
      guard let self else { return }
      self.ownership.transitionToPause(claim: self.onPause)
      self.close()
    }))
    navigation.reconcile(rows.map { .init(id: $0.id, enabled: $0.isEnabled) })
  }

  private func adjust(_ direction: Int) {
    guard navigation.choiceIndex == nil,
          let item = rows.first(where: { $0.id == navigation.selectedID && $0.isEnabled }),
          case .stepper(let stepper) = item.role else { return }
    stepper.value.wrappedValue = stepper.stepped(stepper.value.wrappedValue, by: direction)
    rebuild()
  }

  private func select() {
    guard let item = rows.first(where: { $0.id == navigation.selectedID && $0.isEnabled }) else { return }
    if let choices = item.role.steppable {
      if let index = navigation.choiceIndex, choices.options.indices.contains(index) {
        choices.selection.wrappedValue = choices.options[index].1
        navigation.cancelChoices()
        rebuild()
      } else {
        navigation.openChoices(for: item.id, count: choices.options.count,
          selected: choices.options.firstIndex(where: { $0.1 == choices.selection.wrappedValue }) ?? 0)
      }
    } else {
      _ = item.activateInPlace()
      if isPresented { rebuild() }
    }
  }
}
#endif
