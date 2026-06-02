import PVWebServer
import SwiftUI

struct TVRootView: View {
  var body: some View {
    TVLibraryView()
      .tint(Color("DolphinTint"))
      .background(Color.black)
      .onAppear {
        PVWebServer.shared.startServers()
      }
  }
}
