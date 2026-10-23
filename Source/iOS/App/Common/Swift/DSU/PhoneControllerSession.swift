// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SwiftUI

/// The one-tap "use this iPhone as a Wii Remote for the Apple TV" session.
///
/// It is the phone's DSU controller screen with a fixed setup: the Wii Remote layout, gyro
/// pointing, the controller identity in the Bonjour record (so a TV that browses sees a pad
/// offering itself), and approval required. Nothing connects silently: the TV asks first, and the
/// phone answers only the TV the user approves on its own prompt.
///
/// `begin()` changes some of the user's DSU settings for the length of the session; `end()` puts
/// them back, which is what makes a one-tap session leave no trace.
@MainActor
enum PhoneControllerSession {
  struct Configuration: Equatable {
    let layout: String
    let pointerMode: PointerMode
    let approvalRequired: Bool
    let advert: DSUAdvert
  }

  /// Whether the controller screen is up for this session. The library presents it.
  final class Presentation: ObservableObject {
    static let shared = Presentation()
    @Published fileprivate(set) var isPresented = false
  }

  /// What the user had before the session, put back by `end()`.
  private struct Saved {
    let approvalRequired: Bool
    let restrictedClient: String?
    let layout: String?
    var pointerMode: PointerMode?
  }

  private static var saved: Saved?
  /// The identity published for this session, so `end()` can republish it without the controller role.
  private static var advertised: DSUAdvert?
  /// The TV this session newly allowed. A TV the user had already always-allowed is not listed.
  private static var allowedBySession: String?

  static var isActive: Bool { Presentation.shared.isPresented }

  static func configuration(pid: String, name: String) -> Configuration {
    Configuration(
      layout: DSUControllerLayout.wiiRemote.rawValue,
      pointerMode: .gyro,
      approvalRequired: true,
      advert: DSUAdvert(pid: pid, name: name, deviceType: ContinuityManager.deviceTypeCode(), isController: true))
  }

  /// Starts the session: applies the setup, starts the DSU server and presents the controller screen.
  static func begin() {
    guard !isActive else { return }
    let config = configuration(pid: ContinuityManager.shared.identity.id, name: ICubeDeviceName.current())
    apply(config)
    saved?.pointerMode = PointerModeController.shared.mode
    PointerModeController.shared.set(config.pointerMode)
    startDSUServerIfNeeded()
    Presentation.shared.isPresented = true
  }

  /// Leaves the session: the TV stops seeing a controller and the user's settings come back.
  static func end() {
    if let advertised {
      DSUServerBridge.setIdentity(DSUAdvert(pid: advertised.pid, name: advertised.name,
                                            deviceType: advertised.deviceType, isController: false).txtRecord())
    }
    advertised = nil
    if let allowed = allowedBySession { DSUServerBridge.setClient(allowed, allowed: false) }
    allowedBySession = nil
    if let saved {
      DSUServerBridge.setApprovalRequired(saved.approvalRequired)
      DSUServerBridge.setRestrictToClient(saved.restrictedClient)
      if let layout = saved.layout {
        UserDefaults.standard.set(layout, forKey: DSUControllerLayout.storageKey)
      } else {
        UserDefaults.standard.removeObject(forKey: DSUControllerLayout.storageKey)
      }
      if let mode = saved.pointerMode { PointerModeController.shared.set(mode) }
    }
    saved = nil
    Presentation.shared.isPresented = false
  }

  /// Applies the setup to the DSU server's settings, remembering what to put back.
  static func apply(_ config: Configuration) {
    if saved == nil {
      saved = Saved(
        approvalRequired: DSUServerBridge.approvalRequired(),
        restrictedClient: DSUServerBridge.restrictedClient(),
        layout: UserDefaults.standard.string(forKey: DSUControllerLayout.storageKey),
        pointerMode: nil)
    }
    UserDefaults.standard.set(config.layout, forKey: DSUControllerLayout.storageKey)
    DSUServerBridge.setApprovalRequired(config.approvalRequired)
    DSUServerBridge.setIdentity(config.advert.txtRecord())
    advertised = config.advert
  }

  /// The user approved the TV at `address` on the phone's prompt: it may take input, and this
  /// session sends to it alone.
  static func approve(address: String) {
    let ip = bareIP(address)
    if !DSUServerBridge.isClientAllowed(ip) { allowedBySession = ip }
    DSUServerBridge.setClient(ip, allowed: true)
    DSUServerBridge.setRestrictToClient(ip)
  }

  static func block(address: String) {
    DSUServerBridge.setClient(bareIP(address), allowed: false)
  }

  private static func bareIP(_ address: String) -> String {
    address.split(separator: ":", maxSplits: 1).first.map(String.init) ?? address
  }
}

/// The controller screen with the TV's approval prompt on top. The library's own approval banner
/// sits under the full-screen controller, so the session asks here.
struct PhoneControllerSessionView: View {
  @State private var pendingAddress: String?

  var body: some View {
    DSUControllerView(onClose: { PhoneControllerSession.end() })
      .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DSUNewClientApproval"))) { note in
        pendingAddress = note.userInfo?["address"] as? String
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
