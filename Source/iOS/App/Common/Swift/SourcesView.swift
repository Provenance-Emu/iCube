import SwiftUI
import PVWebServer

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

    // Bonjour discovery
    @State private var discovered: [DiscoveredService] = []
    @State private var browser = NetServiceBrowser()
    @State private var browsing = false
    @State private var browserDelegate: BonjourDelegate?
    @State private var activeServices: [String: NetService] = [:]
    @State private var resolveDelegates: [String: BonjourResolveDelegate] = [:]

    private struct DiscoveredService: Identifiable { let id = UUID(); let name: String; let host: String; let port: Int; let txt: [String:String] }

    var body: some View {
        NavigationStack {
            Form {
                if !discovered.isEmpty {
                    Section("Discovered WebDAV Servers") {
                        ForEach(discovered) { s in
                            Button(action: { quickAdd(s) }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(s.name.isEmpty ? "WebDAV" : s.name)
                                        Text("http://\(s.host):\(s.port)\(s.txt["path"] ?? "/")")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(L("Add")).font(.caption)
                                }
                            }
                        }
                    }
                }
                Section("Details") {
                    TextField("Name", text: $name)
                    TextField("URL (e.g., http://192.168.1.29:8080)", text: $url)
                    TextField("Start Path (optional) (`Software` for other DolphiniOS instances)", text: $startPath)
                }
                Section("Authentication") {
                    TextField("Username (optional)", text: $username)
                    SecureField("Password (optional)", text: $password)
                }
                Section("Options") {
                    Toggle("Recursive", isOn: $recursive)
                    Toggle("Automatic Pre-cache", isOn: $enablePreCaching)
                    #if os(tvOS)
                    TVIntStepper(value: $intervalMinutes, range: 1...60, step: 1)
                    Text("Refresh every \(intervalMinutes) min")
                    #else
                    Stepper(value: $interval, in: 60...3600, step: 60) { Text("Refresh every \(Int(interval/60)) min") }
                    #endif
                }

                if enablePreCaching {
                    Section("Automatic Pre-cache") {
                        Text("When enabled, newly browsed games will begin downloading to local storage in the background for faster access and offline play.")
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
            .onAppear { startBonjour() }
            .onDisappear { stopBonjour() }
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

    private func quickAdd(_ s: DiscoveredService) {
        let path = s.txt["path"] ?? "/"
        let urlString = "http://\(s.host):\(s.port)\(path)"
        name = s.name.isEmpty ? "WebDAV" : s.name
        url = urlString
        if let u = s.txt["u"], !u.isEmpty { username = u }
        if let p = s.txt["p"], !p.isEmpty { password = p }
    }

    private func startBonjour() {
        guard !browsing else { return }
        browsing = true
        discovered.removeAll()
        activeServices.removeAll()
        resolveDelegates.removeAll()
        browser.stop()
        browser = NetServiceBrowser()
        let delegate = BonjourDelegate { service, added in
            if added { resolve(service) }
            else { discovered.removeAll { $0.name == service.name }; activeServices.removeValue(forKey: service.name); resolveDelegates.removeValue(forKey: service.name) }
        }
        browserDelegate = delegate
        browser.delegate = delegate
        browser.schedule(in: .main, forMode: .common)
        // Use default domain if available; empty string searches in default domains
        browser.searchForServices(ofType: "_webdav._tcp.", inDomain: "")
    }

    private func stopBonjour() {
        browser.stop()
        browsing = false
        browser.delegate = nil
        browserDelegate = nil
        activeServices.removeAll()
        resolveDelegates.removeAll()
    }

    private func resolve(_ service: NetService) {
        activeServices[service.name] = service
        let resolver = BonjourResolveDelegate { host, port, txt in
            let name = service.name
            guard let host else { return }
            let record = DiscoveredService(name: name, host: host, port: port, txt: txt)
            // Filter out our own instance and already-added sources
            func norm(_ s: String?) -> String? {
              guard let s else { return nil }
              return s.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            }
            let myHost = norm(PVWebServer.shared.ipAddress)
            let myBonjourHost = norm(PVWebServer.shared.bonjourSeverURL?.host)
            let myHosts: Set<String> = Set([myHost, myBonjourHost].compactMap { $0 })
            let isOwn = myHosts.contains(norm(host) ?? "")
            let alreadyAdded = store.sources.contains { src in
              guard let w = src as? WebDAVSource else { return false }
              return (norm(w.baseURL.host) == norm(host)) && ((w.baseURL.port ?? 0) == port)
            }
            if !isOwn && !alreadyAdded && !discovered.contains(where: { $0.host == host && $0.port == port }) {
                discovered.append(record)
            }
        }
        resolveDelegates[service.name] = resolver
        service.delegate = resolver
        service.resolve(withTimeout: 5)
    }
}

// MARK: - Bonjour helpers
private final class BonjourDelegate: NSObject, NetServiceBrowserDelegate {
    private let onChange: (NetService, Bool) -> Void
    init(_ onChange: @escaping (NetService, Bool) -> Void) { self.onChange = onChange }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) { onChange(service, true) }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) { onChange(service, false) }
}

private final class BonjourResolveDelegate: NSObject, NetServiceDelegate {
    private let onResolved: (String?, Int, [String:String]) -> Void
    init(_ onResolved: @escaping (String?, Int, [String:String]) -> Void) { self.onResolved = onResolved }
    func netServiceDidResolveAddress(_ sender: NetService) {
        let host = sender.hostName // keep full domain, e.g. myhost.local.
        let port = sender.port
        var txt: [String:String] = [:]
        if let data = sender.txtRecordData() {
            let dict = NetService.dictionary(fromTXTRecord: data)
            for (k,v) in dict { if let s = String(data: v, encoding: .utf8) { txt[k] = s } }
        }
        onResolved(host, port, txt)
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
                    TextField("Start Path (optional) (`Software` for other DolphiniOS instances)", text: $startPath)
                }
                Section("Authentication") {
                    TextField("Username (optional)", text: $username)
                    SecureField("Password (optional)", text: $password)
                }
                Section("Options") {
                    Toggle("Recursive", isOn: $recursive)
                    Toggle("Automatic Pre-cache", isOn: $enablePreCaching)
                    #if os(tvOS)
                    TVIntStepper(value: $intervalMinutes, range: 1...60, step: 1)
                    Text("Refresh every \(intervalMinutes) min")
                    #else
                    Stepper(value: $interval, in: 60...3600, step: 60) { Text("Refresh every \(Int(interval/60)) min") }
                    #endif
                }

                if enablePreCaching {
                    Section("Automatic Pre-cache") {
                        Text("When enabled, newly browsed games will begin downloading to local storage in the background for faster access and offline play.")
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
