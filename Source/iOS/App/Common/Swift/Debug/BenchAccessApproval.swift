// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Who may drive the bench over the network.
//
// The bench is loopback-only on DEBUG builds and needs none of this. On a
// Release build the user switched it on deliberately, which earns LAN
// reachability — but the API boots games, writes settings and loads save
// states, so the first request from a new address asks on-device before
// anything runs. "Always Allow" remembers that address; nothing else is stored.
//
// Deliberately NOT a held-open request: an HTTP connection parked while a human
// finds their phone just times out somewhere unhelpful. The first request is
// refused with 403 and a reason, the prompt appears, and the client retries.

import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class BenchAccessApproval {
  static let shared = BenchAccessApproval()

  /// Remembered "Always Allow" addresses.
  private static let allowedDefaultsKey = "ICubeBenchAllowedClients"
  /// Cleared on every launch: an "Allow Once" lasts for this app session.
  private var sessionAllowed: Set<String> = []
  /// Addresses with a prompt already on screen, so a retrying client does not
  /// stack alerts.
  private var pending: Set<String> = []

  private init() {}

  private var remembered: Set<String> {
    get { Set(UserDefaults.standard.stringArray(forKey: Self.allowedDefaultsKey) ?? []) }
    set { UserDefaults.standard.set(Array(newValue), forKey: Self.allowedDefaultsKey) }
  }

  func isAllowed(_ address: String) -> Bool {
    sessionAllowed.contains(address) || remembered.contains(address)
  }

  /// Show the prompt for `address` unless one is already up for it.
  func requestApproval(for address: String) {
    guard !pending.contains(address), !isAllowed(address) else { return }
    pending.insert(address)
#if canImport(UIKit)
    presentPrompt(for: address)
#else
    pending.remove(address)
#endif
  }

  /// Forget every remembered address. Surfaced in Settings so a mis-tapped
  /// "Always Allow" is recoverable without reinstalling.
  func forgetAll() {
    remembered = []
    sessionAllowed = []
  }

  var rememberedAddresses: [String] { Array(remembered).sorted() }

#if canImport(UIKit)
  private func presentPrompt(for address: String) {
    guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
          let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
    else {
      pending.remove(address)
      return
    }

    let alert = UIAlertController(
      title: L("Allow Debug Access?"),
      message: String(format: L("%1$@ wants to control iCube over Wi-Fi. It can change settings, start games and load save states. Only allow devices you recognise."), address),
      preferredStyle: .alert)

    alert.addAction(UIAlertAction(title: L("Deny"), style: .cancel) { [weak self] _ in
      self?.pending.remove(address)
    })
    alert.addAction(UIAlertAction(title: L("Allow Once"), style: .default) { [weak self] _ in
      guard let self else { return }
      self.sessionAllowed.insert(address)
      self.pending.remove(address)
    })
    alert.addAction(UIAlertAction(title: L("Always Allow"), style: .default) { [weak self] _ in
      guard let self else { return }
      var r = self.remembered
      r.insert(address)
      self.remembered = r
      self.pending.remove(address)
    })

    var presenter = root
    while let presented = presenter.presentedViewController { presenter = presented }
    presenter.present(alert, animated: true)
  }
#endif
}
