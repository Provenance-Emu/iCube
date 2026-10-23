import PVWebServer
import SwiftUI

/// The remote sources the library browses (WebDAV servers), in the iCube design language: the room, card rows with
/// an icon badge and an online chip, and an Add card that is the primary action when there are none yet (the
/// welcome's "Add Remote Source" lands here on an empty list).
///
/// iOS keeps a `List` so a row still swipes to delete. tvOS draws the leaf header and the cards in a ScrollView,
/// presented full screen from the library; Menu closes it, and a long press on a source offers Delete.
struct SourcesView: View {
  @ObservedObject private var store = RemoteSourcesStore.shared
  @State private var showAddWebDAV = false
  @State private var editingSource: WebDAVSource?

  #if os(tvOS)
  private enum Focus: Hashable { case source(String), add }
  @FocusState private var focus: Focus?
  private static let contentWidth: CGFloat = 1100
  #else
  private static let contentWidth: CGFloat = 640
  #endif

  private var sources: [WebDAVSource] { store.sources.compactMap { $0 as? WebDAVSource } }

  var body: some View {
    content
      .sheet(isPresented: $showAddWebDAV) {
        AddWebDAVSourceView(store: store)
      }
      .sheet(item: $editingSource) { source in
        EditWebDAVSourceView(store: store, source: source)
      }
  }

  #if os(tvOS)
  private var content: some View {
    ZStack {
      // A full-screen cover is transparent until something opaque fills it.
      Color(uiColor: ICubeDesign.roomStops[0]).ignoresSafeArea()
      ICubeRoom(style: .gradient)
      ScrollView {
        VStack(alignment: .leading, spacing: ICubeDesign.Spacing.l.rawValue) {
          ICubeLeafHeader(title: L("Sources"), subtitle: L("Library"))
          if sources.isEmpty {
            SourcesEmptyState()
          } else {
            ICubeAccentHeader(text: L("WebDAV"))
            ForEach(sources) { source in
              SourceCard(source: source) { editingSource = source }
                .focused($focus, equals: .source(source.id))
                .contextMenu {
                  Button(L("Delete Source"), role: .destructive) { store.remove(id: source.id) }
                }
            }
          }
          addCard
            .focused($focus, equals: .add)
        }
        .focusSection()
        .frame(maxWidth: Self.contentWidth)
        .frame(maxWidth: .infinity)
        .padding(.vertical, ICubeDesign.Spacing.l.rawValue)
      }
      // The focused card's lift and glow draw past the scroll view's edge.
      .scrollClipDisabled()
    }
    .defaultFocus($focus, sources.first.map { .source($0.id) } ?? .add)
  }
  #else
  private var content: some View {
    NavigationStack {
      List {
        Group {
          if sources.isEmpty {
            SourcesEmptyState()
              .padding(.vertical, ICubeDesign.Spacing.l.rawValue)
          } else {
            ICubeAccentHeader(text: L("WebDAV"))
              .padding(.top, ICubeDesign.Spacing.s.rawValue)
            ForEach(sources) { source in
              SourceCard(source: source) { editingSource = source }
            }
            .onDelete { offsets in
              for id in offsets.map({ sources[$0].id }) { store.remove(id: id) }
            }
          }
          addCard
        }
        .frame(maxWidth: Self.contentWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: ICubeDesign.Spacing.xs.rawValue, leading: ICubeDesign.Spacing.m.rawValue,
                                  bottom: ICubeDesign.Spacing.xs.rawValue, trailing: ICubeDesign.Spacing.m.rawValue))
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .background { ICubeRoom(style: .gradient) }
      .navigationTitle(L("Sources"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button { showAddWebDAV = true } label: { Image(systemName: "plus") }
            .accessibilityLabel(L("Add WebDAV Source"))
        }
      }
    }
    .tint(ICubeDesign.color(.accent))
  }
  #endif

  private var addCard: some View {
    SourcesActionCard(title: L("Add WebDAV Source"),
                      detail: L("Connect to a server on your network, such as a NAS or another iCube."),
                      systemImage: "plus", isPrimary: sources.isEmpty) { showAddWebDAV = true }
  }
}

// MARK: - Rows

private enum SourcesBadge {
  #if os(tvOS)
  static let size = ICubeDesign.TileBadge.size
  static let glyphFont = ICubeDesign.TileBadge.glyphFont(prominent: false)
  #else
  static let size = ICubeDesign.IconBadge.size
  static let glyphFont = ICubeDesign.standard.font(.body).weight(.semibold)
  #endif

  /// The row icon badge: tinted at 15 %, or filled with the accent for the primary action.
  static func view(systemImage: String, filled: Bool = false) -> some View {
    let accent = ICubeDesign.color(.accent)
    return RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue, style: .continuous)
      .fill(filled ? accent : accent.opacity(ICubeDesign.IconBadge.tintOpacity))
      .frame(width: size, height: size)
      .overlay {
        Image(systemName: systemImage)
          .font(glyphFont)
          .foregroundStyle(filled ? Color.white : accent)
      }
      .accessibilityHidden(true)
  }
}

/// The trailing chevron every card row ends with.
private struct SourcesChevron: View {
  var body: some View {
    Image(systemName: "chevron.right")
      .icubeText(.detail)
      .fontWeight(.semibold)
      .foregroundStyle(ICubeDesign.color(.textTertiary))
      .accessibilityHidden(true)
  }
}

/// A configured WebDAV server: name, address, start folder and whether it answered its last check. Opens Edit.
private struct SourceCard: View {
  let source: WebDAVSource
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: ICubeDesign.Spacing.s.rawValue) {
        SourcesBadge.view(systemImage: "server.rack")
        VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xxs.rawValue) {
          Text(source.name)
            .icubeText(.body)
            .fontWeight(.semibold)
            .foregroundStyle(ICubeDesign.color(.textPrimary))
            .lineLimit(1)
          Text(source.baseURL.absoluteString)
            .icubeText(.detail)
            .foregroundStyle(ICubeDesign.color(.textSecondary))
            .lineLimit(1)
            .truncationMode(.middle)
          if let startPath = source.startPathComponent, !startPath.isEmpty {
            Text(String(format: L("Start folder: %@"), startPath))
              .icubeText(.detail)
              .foregroundStyle(ICubeDesign.color(.textTertiary))
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        Spacer(minLength: 0)
        SourceStatusChip(isOnline: source.isOnline)
        SourcesChevron()
      }
      .padding(ICubeDesign.Spacing.m.rawValue)
      .frame(maxWidth: .infinity, alignment: .leading)
      .icubeCardSurface(cornerRadius: ICubeDesign.Card.rowCornerRadius)
      .contentShape(RoundedRectangle(cornerRadius: ICubeDesign.Card.rowCornerRadius, style: .continuous))
    }
    .buttonStyle(ICubeCardButtonStyle())
  }
}

/// "Online" with a green dot, or "Offline" in red.
private struct SourceStatusChip: View {
  let isOnline: Bool

  #if os(tvOS)
  private static let dot: CGFloat = 12
  #else
  private static let dot: CGFloat = 8
  #endif

  var body: some View {
    let tint = isOnline
      ? Color.green // design-lint: allow source status dot; no status colour token yet
      : ICubeDesign.color(.destructive)
    HStack(spacing: ICubeDesign.Spacing.xxs.rawValue) {
      Circle()
        .fill(tint)
        .frame(width: Self.dot, height: Self.dot)
      Text(isOnline ? L("Online") : L("Offline"))
        .icubeText(.tag)
        .foregroundStyle(ICubeDesign.color(.textSecondary))
    }
    .padding(.horizontal, ICubeDesign.Spacing.xs.rawValue)
    .padding(.vertical, ICubeDesign.Spacing.xxs.rawValue)
    .background(Capsule().fill(ICubeDesign.color(.rowSurface)))
    .fixedSize()
    .accessibilityElement(children: .combine)
  }
}

/// A card that runs an action: the Add card. Primary (filled badge) when the list is empty.
private struct SourcesActionCard: View {
  let title: String
  let detail: String
  let systemImage: String
  let isPrimary: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: ICubeDesign.Spacing.s.rawValue) {
        SourcesBadge.view(systemImage: systemImage, filled: isPrimary)
        VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xxs.rawValue) {
          Text(title)
            .icubeText(.body)
            .fontWeight(.semibold)
            .foregroundStyle(ICubeDesign.color(.textPrimary))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
          Text(detail)
            .icubeText(.detail)
            .foregroundStyle(ICubeDesign.color(.textSecondary))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
        SourcesChevron()
      }
      .padding(ICubeDesign.Spacing.m.rawValue)
      .frame(maxWidth: .infinity, alignment: .leading)
      .icubeCardSurface(cornerRadius: ICubeDesign.Card.rowCornerRadius)
      .contentShape(RoundedRectangle(cornerRadius: ICubeDesign.Card.rowCornerRadius, style: .continuous))
    }
    .buttonStyle(ICubeCardButtonStyle())
  }
}

/// No sources yet: what a source is, above the Add card.
private struct SourcesEmptyState: View {
  var body: some View {
    VStack(spacing: ICubeDesign.Spacing.s.rawValue) {
      SourcesBadge.view(systemImage: "externaldrive.connected.to.line.below")
      Text(L("No Remote Sources"))
        .icubeText(.section)
        .foregroundStyle(ICubeDesign.color(.textPrimary))
        .multilineTextAlignment(.center)
      Text(L("Add a WebDAV server on your network to browse and play the games stored on it."))
        .icubeText(.body)
        .foregroundStyle(ICubeDesign.color(.textSecondary))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
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
  @State private var enablePreCaching: Bool = true

  // Bonjour discovery
  @State private var discovered: [DiscoveredService] = []
  @State private var browser = NetServiceBrowser()
  @State private var browsing = false
  @State private var browserDelegate: BonjourDelegate?
  @State private var activeServices: [String: NetService] = [:]
  @State private var resolveDelegates: [String: BonjourResolveDelegate] = [:]

  private struct DiscoveredService: Identifiable { let id = UUID()
    let name: String
    let host: String
    let port: Int
    let txt: [String: String]
  }

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
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
          TextField("URL (e.g., http://192.168.1.29:8080)", text: $url)
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
          TextField("Start Path (optional) (`Software` for other iCube instances)", text: $startPath)
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
        }
        Section("Authentication") {
          TextField("Username (optional)", text: $username)
            .textContentType(.username)
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
          SecureField("Password (optional)", text: $password)
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
            .textContentType(.password)
        }
        Section("Options") {
          Toggle("Recursive", isOn: $recursive)
          Toggle("Automatic Pre-cache", isOn: $enablePreCaching)
          #if os(tvOS)
          TVIntStepper(value: $intervalMinutes, range: 1 ... 60, step: 1)
          Text("Refresh every \(intervalMinutes) min")
          #else
          Stepper(value: $interval, in: 60 ... 3600, step: 60) { Text("Refresh every \(Int(interval / 60)) min") }
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
      else { discovered.removeAll { $0.name == service.name }
        activeServices.removeValue(forKey: service.name)
        resolveDelegates.removeValue(forKey: service.name)
      }
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
  private let onResolved: (String?, Int, [String: String]) -> Void
  init(_ onResolved: @escaping (String?, Int, [String: String]) -> Void) { self.onResolved = onResolved }
  func netServiceDidResolveAddress(_ sender: NetService) {
    let host = sender.hostName // keep full domain, e.g. myhost.local.
    let port = sender.port
    var txt: [String: String] = [:]
    if let data = sender.txtRecordData() {
      let dict = NetService.dictionary(fromTXTRecord: data)
      for (k, v) in dict { if let s = String(data: v, encoding: .utf8) { txt[k] = s } }
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
          TextField("Start Path (optional) (`Software` for other iCube instances)", text: $startPath)
        }
        Section("Authentication") {
          TextField("Username (optional)", text: $username)
          SecureField("Password (optional)", text: $password)
        }
        Section("Options") {
          Toggle("Recursive", isOn: $recursive)
          Toggle("Automatic Pre-cache", isOn: $enablePreCaching)
          #if os(tvOS)
          TVIntStepper(value: $intervalMinutes, range: 1 ... 60, step: 1)
          Text("Refresh every \(intervalMinutes) min")
          #else
          Stepper(value: $interval, in: 60 ... 3600, step: 60) { Text("Refresh every \(Int(interval / 60)) min") }
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
