import SwiftUI

struct TVCheatListView: View {
    let item: TVGameItem
    enum Tab: Hashable { case gecko, ar }
    @State private var tab: Tab = .gecko
    @State private var gecko: [TVGeckoCodeInfo] = []
    @State private var ar: [TVActionReplayCodeInfo] = []
    @Environment(\.dismiss) private var dismissEnv

    @State private var cheatsEnabledGlobal: Bool = false
    @State private var showEnableCheatsPrompt: Bool = false
    @State private var pendingIsGecko: Bool? = nil
    @State private var pendingIndex: Int? = nil

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
                    Section {
                        Toggle(L("Enable Cheats"), isOn: Binding(get: { cheatsEnabledGlobal }, set: { newValue in
                            DOLConfigBridge.setMainEnableCheats(newValue)
                            cheatsEnabledGlobal = newValue
                        }))
                    }
                    if tab == .gecko {
                        ForEach(gecko.indices, id: \.self) { i in
                            HStack {
                                Text(gecko[i].name)
                                Spacer()
                                Toggle("", isOn: Binding(get: { gecko[i].enabled }, set: { newValue in
                                    if newValue && !cheatsEnabledGlobal {
                                        pendingIsGecko = true
                                        pendingIndex = i
                                        showEnableCheatsPrompt = true
                                    } else {
                                        gecko[i].enabled = newValue
                                        _ = TVCheatsBridge.setGeckoCodeEnabled(newValue, at: i, forGameId: item.gameID, revision: item.revision)
                                        reload()
                                    }
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
                                    if newValue && !cheatsEnabledGlobal {
                                        pendingIsGecko = false
                                        pendingIndex = i
                                        showEnableCheatsPrompt = true
                                    } else {
                                        ar[i].enabled = newValue
                                        _ = TVCheatsBridge.setActionReplayCodeEnabled(newValue, at: i, forGameId: item.gameID, revision: item.revision)
                                        reload()
                                    }
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
            .onAppear {
                cheatsEnabledGlobal = DOLConfigBridge.mainEnableCheats()
                reload()
            }
        }
        .alert(L("Enable Cheats?"), isPresented: $showEnableCheatsPrompt) {
            Button(L("Turn On Cheats")) {
                DOLConfigBridge.setMainEnableCheats(true)
                cheatsEnabledGlobal = true
                if let idx = pendingIndex, let isGecko = pendingIsGecko {
                    if isGecko {
                        gecko[idx].enabled = true
                        _ = TVCheatsBridge.setGeckoCodeEnabled(true, at: idx, forGameId: item.gameID, revision: item.revision)
                    } else {
                        ar[idx].enabled = true
                        _ = TVCheatsBridge.setActionReplayCodeEnabled(true, at: idx, forGameId: item.gameID, revision: item.revision)
                    }
                    pendingIndex = nil
                    pendingIsGecko = nil
                    reload()
                }
            }
            Button(L("Cancel"), role: .cancel) {
                pendingIndex = nil
                pendingIsGecko = nil
            }
        } message: {
            Text(L("Cheats can affect performance and stability. Enable global cheats to apply this code?"))
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
