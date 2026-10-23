// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SwiftUI

/// The one-tap "use this iPhone as a Wii Remote for the Apple TV" session.
///
/// It is the phone's DSU controller screen with a fixed setup: the Wii Remote layout, gyro
/// pointing, the controller identity in the Bonjour record (so a TV that browses sees a pad
/// offering itself), and approval required. Nothing connects silently: the TV asks first, and the
/// phone answers only the TV the user approves on its own prompt, for this session only.
///
/// `begin()` only asks for the controller screen. The setup is applied once that screen has
/// appeared (`didAppear()`), so a presentation SwiftUI refuses leaves nothing changed. While the
/// session runs, the user's own settings are kept in a persisted snapshot, so a killed app is put
/// right at the next launch (`restoreStaleSnapshot`); `end()` restores them straight away.
@MainActor
enum PhoneControllerSession {
  struct Configuration: Equatable {
    let layout: String
    let pointerMode: PointerMode
    let approvalRequired: Bool
    let advert: DSUAdvert
  }

  /// Where the pointer mode is read and written; the live one is `PointerModeController`.
  struct PointerModeAccess {
    let read: @MainActor () -> PointerMode
    let write: @MainActor (PointerMode) -> Void

    static let live = PointerModeAccess(
      read: { PointerModeController.shared.mode },
      write: { PointerModeController.shared.set($0) })
  }

  /// The user's settings from before the session. Persisted for as long as the session runs.
  struct Snapshot: Codable, Equatable {
    static let defaultsKey = "phone_controller_session_snapshot"

    let approvalRequired: Bool
    let layout: String?
    let pointerMode: Int?

    static func load(from defaults: UserDefaults) -> Snapshot? {
      defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
    }

    func save(to defaults: UserDefaults) {
      if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    static func clear(from defaults: UserDefaults) {
      defaults.removeObject(forKey: defaultsKey)
    }

    /// Puts the settings back.
    @MainActor
    func restore(defaults: UserDefaults, pointerMode access: PointerModeAccess) {
      DSUServerBridge.setApprovalRequired(approvalRequired)
      if let layout {
        defaults.set(layout, forKey: DSUControllerLayout.storageKey)
      } else {
        defaults.removeObject(forKey: DSUControllerLayout.storageKey)
      }
      if let raw = pointerMode, let mode = PointerMode(rawValue: raw) { access.write(mode) }
    }
  }

  /// Where the session stands, for the library that hosts the controller screen.
  final class Presentation: ObservableObject {
    static let shared = Presentation()
    /// Tests build their own, which no library observes, so nothing presents.
    init() {}
    /// `begin()` asked for the controller screen; it may not have appeared.
    @Published fileprivate(set) var isRequested = false
    /// The controller screen appeared and the setup is applied.
    @Published fileprivate(set) var isActive = false
  }

  /// How long a requested controller screen has to appear before the request is dropped.
  static var presentationTimeout: Duration = .seconds(3)

  /// The restriction the user had before the session. In memory only: it is never persisted.
  private struct PriorRestriction { let client: String? }
  private static var priorRestriction: PriorRestriction?
  /// The identity published for this session, so `end()` can republish it without the controller role.
  private static var advertised: DSUAdvert?
  /// The TV the user approved on the phone's prompt; the session sends to it alone.
  private static var approvedTV: String?

  static var isActive: Bool { Presentation.shared.isActive }

  static func configuration(pid: String, name: String) -> Configuration {
    Configuration(
      layout: DSUControllerLayout.wiiRemote.rawValue,
      pointerMode: .gyro,
      approvalRequired: true,
      advert: DSUAdvert(pid: pid, name: name, deviceType: ContinuityManager.deviceTypeCode(), isController: true))
  }

  /// Asks the library to present the controller screen. If it never appears (another sheet or
  /// cover is up) the request is dropped after `presentationTimeout`, with nothing changed, and
  /// a later `begin()` can try again.
  static func begin(presentation: Presentation = .shared) {
    guard !presentation.isRequested, !presentation.isActive else { return }
    presentation.isRequested = true
    let timeout = presentationTimeout
    Task { @MainActor in
      try? await Task.sleep(for: timeout)
      if !presentation.isActive { presentation.isRequested = false }
    }
  }

  /// The controller screen appeared: applies the setup and starts the DSU server.
  static func didAppear() {
    guard Presentation.shared.isRequested, !isActive else { return }
    apply(configuration(pid: ContinuityManager.shared.identity.id, name: ICubeDeviceName.current()))
    startDSUServerIfNeeded()
    Presentation.shared.isActive = true
  }

  /// Leaves the session: the TV stops seeing a controller, the session's approvals are forgotten and
  /// the user's settings come back.
  static func end(defaults: UserDefaults = .standard, pointerMode: PointerModeAccess = .live) {
    if let advertised {
      DSUServerBridge.setIdentity(DSUAdvert(pid: advertised.pid, name: advertised.name,
                                            deviceType: advertised.deviceType, isController: false).txtRecord())
    }
    advertised = nil
    DSUServerBridge.setSessionApprovalMode(false)
    approvedTV = nil
    if let snapshot = Snapshot.load(from: defaults) {
      snapshot.restore(defaults: defaults, pointerMode: pointerMode)
      Snapshot.clear(from: defaults)
    }
    if let prior = priorRestriction { DSUServerBridge.setRestrictToClient(prior.client) }
    priorRestriction = nil
    Presentation.shared.isActive = false
    Presentation.shared.isRequested = false
  }

  /// At launch: a session the app was killed in the middle of left its settings changed. Puts them back.
  @discardableResult
  static func restoreStaleSnapshot(defaults: UserDefaults = .standard, pointerMode: PointerModeAccess = .live) -> Bool {
    guard let snapshot = Snapshot.load(from: defaults) else { return false }
    snapshot.restore(defaults: defaults, pointerMode: pointerMode)
    Snapshot.clear(from: defaults)
    return true
  }

  /// Applies the setup, keeping the user's settings in the snapshot first (an existing snapshot is
  /// the user's real settings and is kept as it is).
  static func apply(_ config: Configuration, defaults: UserDefaults = .standard, pointerMode: PointerModeAccess = .live) {
    if Snapshot.load(from: defaults) == nil {
      Snapshot(approvalRequired: DSUServerBridge.approvalRequired(),
               layout: defaults.string(forKey: DSUControllerLayout.storageKey),
               pointerMode: pointerMode.read().rawValue).save(to: defaults)
    }
    if priorRestriction == nil { priorRestriction = PriorRestriction(client: DSUServerBridge.restrictedClient()) }
    defaults.set(config.layout, forKey: DSUControllerLayout.storageKey)
    pointerMode.write(config.pointerMode)
    DSUServerBridge.setApprovalRequired(config.approvalRequired)
    DSUServerBridge.setSessionApprovalMode(true)
    DSUServerBridge.setRestrictToClient(nil)
    DSUServerBridge.setIdentity(config.advert.txtRecord())
    advertised = config.advert
  }

  /// The user approved the TV at `address` on the phone's prompt: it may take input for this
  /// session (in memory only), and the session sends to it alone.
  static func approve(address: String) {
    let ip = bareIP(address)
    DSUServerBridge.setSessionClient(ip, allowed: true)
    approvedTV = ip
    DSUServerBridge.setRestrictToClient(ip)
  }

  static func block(address: String) {
    let ip = bareIP(address)
    DSUServerBridge.setSessionClient(ip, allowed: false)
    if approvedTV == ip { approvedTV = nil }
  }

  /// The controller screen re-applies the user's stored target whenever it appears (also on the
  /// way back from its Sticks screen); the session sends to the approved TV alone, so put it back.
  static func reassertRestriction() {
    guard let ip = approvedTV, DSUServerBridge.restrictedClient() != ip else { return }
    DSUServerBridge.setRestrictToClient(ip)
  }

  private static func bareIP(_ address: String) -> String {
    address.split(separator: ":", maxSplits: 1).first.map(String.init) ?? address
  }
}

/// Puts a stale session snapshot right at launch (see `PhoneControllerSession.restoreStaleSnapshot`).
@MainActor
final class PhoneControllerSessionRecoveryService: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    PhoneControllerSession.restoreStaleSnapshot()
    return true
  }
}

/// The controller screen with the TV's approval prompt on top. The library's own approval banner
/// sits under the full-screen controller, so the session asks here. The controller screen is
/// built only after the session setup is applied, so it starts in the Wii Remote layout.
struct PhoneControllerSessionView: View {
  private static let restrictionCheckInterval: TimeInterval = 1

  @State private var pendingAddress: String?
  @State private var ready = false

  var body: some View {
    Group {
      if ready {
        DSUControllerView(onClose: { PhoneControllerSession.end() })
      } else {
        Color.black.ignoresSafeArea()
      }
    }
    .onAppear {
      guard !ready else { return }
      PhoneControllerSession.didAppear()
      ready = PhoneControllerSession.isActive
    }
    .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DSUNewClientApproval"))) { note in
      guard ready else { return }
      pendingAddress = note.userInfo?["address"] as? String
    }
    .onReceive(Timer.publish(every: Self.restrictionCheckInterval, on: .main, in: .common).autoconnect()) { _ in
      PhoneControllerSession.reassertRestriction()
    }
    .alert(
      L("Receiver requests input"),
      isPresented: Binding(get: { pendingAddress != nil }, set: { if !$0 { pendingAddress = nil } }),
      presenting: pendingAddress
    ) { address in
      Button(L("Allow")) { PhoneControllerSession.approve(address: address) }
      Button(L("Block"), role: .destructive) { PhoneControllerSession.block(address: address) }
    } message: { address in
      Text(address)
    }
  }
}
#endif
