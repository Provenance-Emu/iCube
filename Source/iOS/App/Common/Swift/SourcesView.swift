import SwiftUI

struct SourcesView: View {
    @StateObject private var store = RemoteSourcesStore()
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                Section("WebDAV") {
                    ForEach(Array(store.sources.enumerated()), id: \.1.id) { _, s in
                        HStack {
                            VStack(alignment: .leading) {
                                Text((s as? WebDAVSource)?.name ?? "Remote")
                                Text((s as? WebDAVSource)?.baseURL.absoluteString ?? "").font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Circle().fill(((s as? WebDAVSource)?.isOnline ?? false) ? .green : .red).frame(width: 10, height: 10)
                        }
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
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAdd) { AddWebDAVSourceView(store: store) }
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
    @State private var recursive: Bool = true
    @State private var interval: Double = 900

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: $name)
                    TextField("URL (http/https/webdav/webdavs)", text: $url)
                }
                Section("Authentication") {
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password)
                }
                Section("Options") {
                    Toggle("Recursive", isOn: $recursive)
                    Stepper(value: $interval, in: 60...3600, step: 60) { Text("Refresh every \(Int(interval/60)) min") }
                }
            }
            .navigationTitle("Add WebDAV")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool { !name.isEmpty && URL(string: url) != nil }

    private func save() {
        guard let u = URL(string: url) else { return }
        let usr = username.isEmpty ? nil : username
        let pwd = password.isEmpty ? nil : password
        store.addWebDAV(name: name, url: u, username: usr, password: pwd, recursive: recursive, interval: interval)
        dismiss()
    }
}
