import SwiftUI

struct SourcesView: View {
    @ObservedObject private var store = RemoteSourcesStore.shared
    @State private var showAddWebDAV = false
    @State private var editingSource: WebDAVSource?

    var body: some View {
        NavigationStack {
            List {
                Section("WebDAV") {
                    ForEach(Array(store.sources.enumerated()), id: \.1.id) { _, s in
                        Button(action: {
                            if let webdavSource = s as? WebDAVSource {
                                editingSource = webdavSource
                            }
                        }) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text((s as? WebDAVSource)?.name ?? "Remote")
                                        .foregroundColor(.primary)
                                    if let url = (s as? WebDAVSource)?.baseURL.absoluteString {
                                        Text(url)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let sp = (s as? WebDAVSource)?.startPathComponent, !sp.isEmpty {
                                        Text("Start: \(sp)")
                                            .font(.footnote)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                                Circle().fill(((s as? WebDAVSource)?.isOnline ?? false) ? .green : .red).frame(width: 10, height: 10)
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .onDelete { idx in
                        for i in idx {
                            if let id = (store.sources[i] as? WebDAVSource)?.id { store.remove(id: id) }
                        }
                    }
                }
            }
            .navigationTitle("Sources")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAddWebDAV = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAddWebDAV) {
                AddWebDAVSourceView(store: store)
            }
            .sheet(item: $editingSource) { source in
                EditWebDAVSourceView(store: store, source: source)
            }
        }
    }
}

private struct AddWebDAVSourceView: View {
    @ObservedObject var store: RemoteSourcesStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var url: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var startPath: String = ""
    @State private var recursive: Bool = true
    @State private var interval: Double = 900
    @State private var intervalMinutes: Int = 15
    @State private var enablePreCaching: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: $name)
                    TextField("URL (e.g., http://192.168.1.29:8080)", text: $url)
                    TextField("Start Path (optional)", text: $startPath)
                }
                Section("Authentication") {
                    TextField("Username (optional)", text: $username)
                    SecureField("Password (optional)", text: $password)
                }
                Section("Options") {
                    Toggle("Recursive", isOn: $recursive)
                    Toggle("Enable Pre-caching", isOn: $enablePreCaching)
                    #if os(tvOS)
                    TVIntStepper(value: $intervalMinutes, range: 1...60, step: 1)
                    Text("Refresh every \(intervalMinutes) min")
                    #else
                    Stepper(value: $interval, in: 60...3600, step: 60) { Text("Refresh every \(Int(interval/60)) min") }
                    #endif
                }

                if enablePreCaching {
                    Section("Pre-caching") {
                        Text("When enabled, games can be downloaded to local storage for faster access and offline play.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Add WebDAV")
            .toolbar(content: {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            })
        }
    }

    private var canSave: Bool {
        !name.isEmpty && isValidWebDAVURL(url)
    }

    private func isValidWebDAVURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "webdav", "webdavs"].contains(scheme)
    }

    private func save() {
        guard let u = URL(string: url) else { return }
        let usr = username.isEmpty ? nil : username
        let pwd = password.isEmpty ? nil : password
        #if os(tvOS)
        let finalInterval = Double(intervalMinutes * 60)
        #else
        let finalInterval = interval
        #endif
        store.addWebDAV(name: name, url: u, username: usr, password: pwd, recursive: recursive, interval: finalInterval, startPath: startPath, enablePreCaching: enablePreCaching)
        dismiss()
    }
}

private struct EditWebDAVSourceView: View {
    @ObservedObject var store: RemoteSourcesStore
    let source: WebDAVSource
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var url: String
    @State private var username: String
    @State private var password: String
    @State private var startPath: String
    @State private var recursive: Bool
    @State private var interval: Double
    @State private var intervalMinutes: Int
    @State private var enablePreCaching: Bool

    init(store: RemoteSourcesStore, source: WebDAVSource) {
        self.store = store
        self.source = source
        self._name = State(initialValue: source.name)
        self._url = State(initialValue: source.baseURL.absoluteString)
        self._username = State(initialValue: source.userName ?? "")
        self._password = State(initialValue: KeychainService.getPassword(for: source.id) ?? "")
        self._startPath = State(initialValue: source.startPathComponent ?? "")
        self._recursive = State(initialValue: source.isRecursive)
        self._interval = State(initialValue: source.refreshInterval)
        self._intervalMinutes = State(initialValue: Int(source.refreshInterval / 60))
        self._enablePreCaching = State(initialValue: source.preCachingEnabled)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: $name)
                    TextField("URL (e.g., http://192.168.1.29:8080)", text: $url)
                    TextField("Start Path (optional)", text: $startPath)
                }
                Section("Authentication") {
                    TextField("Username (optional)", text: $username)
                    SecureField("Password (optional)", text: $password)
                }
                Section("Options") {
                    Toggle("Recursive", isOn: $recursive)
                    Toggle("Enable Pre-caching", isOn: $enablePreCaching)
                    #if os(tvOS)
                    TVIntStepper(value: $intervalMinutes, range: 1...60, step: 1)
                    Text("Refresh every \(intervalMinutes) min")
                    #else
                    Stepper(value: $interval, in: 60...3600, step: 60) { Text("Refresh every \(Int(interval/60)) min") }
                    #endif
                }

                if enablePreCaching {
                    Section("Pre-caching") {
                        Text("When enabled, games can be downloaded to local storage for faster access and offline play.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if source.isPreCachingEnabled {
                    Section("Cache Management") {
                        HStack {
                            Text("Cache Size")
                            Spacer()
                            Text(formatBytes(source.getCacheSize()))
                                .foregroundStyle(.secondary)
                        }

                        Button("Clear Cache", role: .destructive) {
                            Task {
                                try? await source.clearCache()
                            }
                        }
                    }
                }

                Section {
                    Button("Delete Source", role: .destructive) {
                        store.remove(id: source.id)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Edit WebDAV")
            .toolbar(content: {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            })
        }
    }

    private var canSave: Bool {
        !name.isEmpty && isValidWebDAVURL(url)
    }

    private func isValidWebDAVURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "webdav", "webdavs"].contains(scheme)
    }

    private func save() {
        guard let u = URL(string: url) else { return }

        // Remove the old source
        store.remove(id: source.id)

        // Add the updated source
        let usr = username.isEmpty ? nil : username
        let pwd = password.isEmpty ? nil : password
        #if os(tvOS)
        let finalInterval = Double(intervalMinutes * 60)
        #else
        let finalInterval = interval
        #endif
        store.addWebDAV(name: name, url: u, username: usr, password: pwd, recursive: recursive, interval: finalInterval, startPath: startPath, enablePreCaching: enablePreCaching)
        dismiss()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
