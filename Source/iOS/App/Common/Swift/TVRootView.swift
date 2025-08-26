import SwiftUI
import PVWebServer

struct TVRootView: View {
    var body: some View {
        TVLibraryView()
            .background(Color.black)
        .onAppear {
          PVWebServer.shared.startServers()
        }
    }
}
