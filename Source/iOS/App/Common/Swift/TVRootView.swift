import SwiftUI

struct TVRootView: View {
  var body: some View {
    #if DEBUG
    // `-ICubePausePreview` opens the pause menu on a stand-in game, `-ICubeSettingsPreview <leafID>` opens one
    // settings leaf, `-ICubeAddGamesPreview` the Add Games screen, for simulator screenshots (Scripts/tvos_screens.sh).
    let args = ProcessInfo.processInfo.arguments
    if args.contains("-ICubePausePreview") {
      PauseMenuView(selectedSlot: .constant(1), onClose: {}, onShowSettings: {}, platform: .tvos,
                    game: PauseMenuView.previewGame())
        .debugPane(Self.argument(after: "-ICubePausePane", in: args))
        .debugFocus(Self.argument(after: "-ICubePauseFocus", in: args))
    } else if let leaf = Self.argument(after: "-ICubeSettingsPreview", in: args) {
      SettingsRootView(initialLeafID: leaf)
    } else if args.contains("-ICubeAddGamesPreview") {
      addGamesPreview
    } else {
      library
    }
    #else
    library
    #endif
  }

  #if DEBUG
  static func argument(after flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
  }
  #endif

  #if DEBUG
  @ViewBuilder private var addGamesPreview: some View {
    #if os(tvOS)
    AddGamesView()
    #else
    library
    #endif
  }
  #endif

  private var library: some View {
    TVLibraryView()
      .tint(Color("DolphinTint"))
      .background(Color.black)
      // WS-3: the upload/WebDAV server's lifecycle is now owned by
      // WebServerLifecycleService (started at scene become-active, see
      // ServiceManager), not by this view appearing.
      //
      // WS-4: the "a device wants to copy a game" prompt lives at the app
      // root, not on the nearby-sharing screens. A library pull arrives
      // UNSOLICITED — unlike a pairing prompt, which answers a flow the owner
      // is already looking at. Attached only to those screens, a peer's
      // request while the owner is in the library would go unseen, the
      // server's approval race would time out after two minutes, and the peer
      // would be told the copy was declined by somebody who never saw a
      // prompt. Since `.askPerGame` is the default grant, that would be the
      // default experience.
      .continuityLibraryPullPrompt()
      // Same reasoning as the library-pull prompt above: a `requestGame` ask
      // from a peer ecosystem app (e.g. Provenance) arrives UNSOLICITED, so
      // this belongs at the root rather than on any one screen.
      .ecosystemShareApprovalPrompt()
      .gameTagMessages()
  }
}
