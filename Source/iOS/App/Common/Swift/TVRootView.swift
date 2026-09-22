import SwiftUI

struct TVRootView: View {
  var body: some View {
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
  }
}
