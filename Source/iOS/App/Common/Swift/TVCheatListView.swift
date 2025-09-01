import SwiftUI

struct TVCheatListView: View {
    let item: TVGameItem
    enum Tab: Hashable { case gecko, ar }
    @State private var tab: Tab = .gecko
    @State private var gecko: [TVGeckoCodeInfo] = []
    @State private var ar: [TVActionReplayCodeInfo] = []
    @Environment(\.dismiss) private var dismissEnv

    var body: some View {
        NavigationStack {
            VStack {
                Picker("Type", selection: $tab) {
                    Text(L("Gecko")).tag(Tab.gecko)
                    Text("Action Replay").tag(Tab.ar)
                }
                .pickerStyle(.segmented)
                .padding()

                List {
                    if tab == .gecko {
                        ForEach(gecko.indices, id: \.self) { i in
                            HStack {
                                Text(gecko[i].name)
                                Spacer()
                                Toggle("", isOn: Binding(get: { gecko[i].enabled }, set: { newValue in
                                    gecko[i].enabled = newValue
                                    _ = TVCheatsBridge.setGeckoCodeEnabled(newValue, at: i, forGameId: item.gameID, revision: item.revision)
                                    reload()
                                }))
                                .labelsHidden()
                            }
                        }
                    } else {
                        ForEach(ar.indices, id: \.self) { i in
                            HStack {
                                Text(ar[i].name)
                                Spacer()
                                Toggle("", isOn: Binding(get: { ar[i].enabled }, set: { newValue in
                                    ar[i].enabled = newValue
                                    _ = TVCheatsBridge.setActionReplayCodeEnabled(newValue, at: i, forGameId: item.gameID, revision: item.revision)
                                    reload()
                                }))
                                .labelsHidden()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Cheats")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismissEnv() } }
            }
            .onAppear(perform: reload)
        }
    }

    private func dismiss() {
        #if os(tvOS)
        UIApplication.shared.keyWindow?.rootViewController?.dismiss(animated: true)
        #endif
    }

    private func reload() {
        gecko = TVCheatsBridge.geckoCodes(forGameId: item.gameID, revision: item.revision)
        ar = TVCheatsBridge.actionReplayCodes(forGameId: item.gameID, revision: item.revision)
    }
}
