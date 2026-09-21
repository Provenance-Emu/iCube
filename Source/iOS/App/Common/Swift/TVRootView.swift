import SwiftUI

struct TVRootView: View {
  var body: some View {
    TVLibraryView()
      .tint(Color("DolphinTint"))
      .background(Color.black)
      // WS-3: the upload/WebDAV server's lifecycle is now owned by
      // WebServerLifecycleService (started at scene become-active, see
      // ServiceManager), not by this view appearing.
  }
}
