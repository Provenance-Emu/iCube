// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// "Use Joe's iPhone as a controller?" for a phone that offers itself over DSU. Allow connects it;
/// Not Now (or Back) leaves it out for this launch. Over a running game the game stays paused while it is up.
/// On tvOS the panel takes focus when it appears (`tvClaimsFocus`); a cover already up keeps its own.
private struct PhoneControllerPromptModifier: ViewModifier {
  @ObservedObject private var service = PhoneControllerService.shared

  private static func title(_ name: String) -> String {
    String(format: L("Use %@ as a controller?"), name)
  }

  private static var message: String {
    L("It will play as the next free player. Your iPhone asks you to confirm too.")
  }

  func body(content: Content) -> some View {
    #if os(tvOS)
    ZStack {
      // Not `.disabled`: that reaches into every cover the content presents (Settings, the pause menu)
      // and would leave one that is up while a phone asks with no working control.
      content
      if let prompt = service.pendingPrompt {
        ICubeConfirmPanel(title: Self.title(prompt.name), message: Self.message,
                          model: Self.model(pid: prompt.pid, service: service), isTV: true,
                          onBack: { service.respond(pid: prompt.pid, allow: false) })
          .pauseClaim("phone-controller-prompt")
          .id(prompt.pid)
      }
    }
    #else
    content.alert(
      service.pendingPrompt.map { Self.title($0.name) } ?? "",
      isPresented: Binding(
        get: { service.pendingPrompt != nil },
        // Dismissal without an answer is Not Now: nothing connects silently.
        set: { if !$0, let pid = service.pendingPrompt?.pid { service.respond(pid: pid, allow: false) } }
      ),
      presenting: service.pendingPrompt?.pid
    ) { pid in
      Button(L("Allow")) { service.respond(pid: pid, allow: true) }
      Button(L("Not Now"), role: .cancel) { service.respond(pid: pid, allow: false) }
    } message: { _ in
      Text(Self.message)
    }
    #endif
  }

  #if os(tvOS)
  /// Not Now first, so a stray press never lets a device in.
  private static func model(pid: String, service: PhoneControllerService) -> MenuModel {
    MenuModel(sections: [MenuSection(id: "phone-controller", items: [
      MenuItem(id: "phone-controller-not-now", title: L("Not Now"), icon: "xmark",
               role: .action { service.respond(pid: pid, allow: false) }),
      MenuItem(id: "phone-controller-allow", title: L("Allow"), icon: "checkmark",
               role: .action { service.respond(pid: pid, allow: true) }),
    ])])
  }
  #endif
}

extension View {
  /// Attach once at the app root: a phone can offer itself in the library or during a game.
  func phoneControllerPrompt() -> some View {
    modifier(PhoneControllerPromptModifier())
  }
}
