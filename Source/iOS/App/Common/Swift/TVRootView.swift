import SwiftUI

struct TVRootView: View {
  var body: some View {
    #if DEBUG
    // `-ICubePausePreview` opens the pause menu on a stand-in game, `-ICubeSettingsPreview <leafID>` opens one
    // settings leaf, `-ICubeAddGamesPreview` the Add Games screen, for simulator screenshots (Scripts/tvos_screens.sh).
    let args = ProcessInfo.processInfo.arguments
    if args.contains("-ICubeLivePerformancePreview") {
      #if os(tvOS)
      LivePerformanceAuditPreview()
      #else
      library
      #endif
    } else if args.contains("-ICubePlayControlsPreview") {
      PlayControlsAuditPreview()
    } else if args.contains("-ICubePausePreview") {
      PauseMenuView(selectedSlot: .constant(1), onClose: {}, platform: Self.previewPlatform,
                    game: PauseMenuView.previewGame())
        .debugPane(Self.argument(after: "-ICubePausePane", in: args))
        .debugFocus(Self.argument(after: "-ICubePauseFocus", in: args))
        .debugLongPress(Self.argument(after: "-ICubePauseLongPress", in: args))
    } else if let leaf = Self.argument(after: "-ICubeSettingsPreview", in: args) {
      // `-ICubeSettingsRow <rowID>` also lands on one row, as a pause tile's long-press does.
      SettingsRootView(initialLeafID: leaf, initialRowID: Self.argument(after: "-ICubeSettingsRow", in: args))
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
  private static var previewPlatform: PlatformKind {
    #if os(tvOS)
    .tvos
    #else
    .ios
    #endif
  }

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
      // UNSOLICITED. Pairing can also arrive while a library-only host is
      // showing this screen. Attached only to sharing screens, a peer's
      // request while the owner is in the library would go unseen, the
      // server's approval race would time out after two minutes, and the peer
      // would be told the copy was declined by somebody who never saw a
      // prompt. Since `.askPerGame` is the default grant, that would be the
      // default experience.
      .continuityPairingPrompt()
      .continuityLibraryPullPrompt()
      // Same reasoning as the library-pull prompt above: a `requestGame` ask
      // from a peer ecosystem app (e.g. Provenance) arrives UNSOLICITED, so
      // this belongs at the root rather than on any one screen.
      .ecosystemShareApprovalPrompt()
      .gameTagMessages()
  }
}

#if DEBUG && os(tvOS)
/// Visual acceptance only. This fixture supplies no ROM, state I/O, controller or emulator runtime.
@MainActor
private struct LivePerformanceAuditPreview: View {
  @StateObject private var session: LivePerformanceSession

  init() {
    var state = PerformanceControlsState()
    state.maxResolutionScale = 6
    state.hud.fps = true
    state.hud.speed = true
    _session = StateObject(wrappedValue: LivePerformanceSession(
      controls: PerformanceControlsController(read: { state }, apply: { _ in })))
  }

  var body: some View {
    ZStack(alignment: .bottom) {
      LinearGradient(colors: [.indigo.opacity(0.6), .black, .teal.opacity(0.4)],
                     startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
      TVLivePerformanceOverlay(session: session)
      Text("Rendering preview — no game or controller running")
        .icubeText(.body).foregroundStyle(.white.opacity(0.7)).padding(30)
        .accessibilityIdentifier("live-performance.rendering-preview")
    }
    .onAppear { session.prepareRenderingPreview() }
    .onDisappear { session.closeForPause() }
  }
}
#endif
