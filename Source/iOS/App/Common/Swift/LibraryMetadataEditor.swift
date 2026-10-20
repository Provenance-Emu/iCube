// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UniformTypeIdentifiers

/// Edits are a draft until Save; cancellation never changes the stored record.
struct LibraryMetadataEditor: View {
  let item: TVGameItem
  @Environment(\.dismiss) private var dismiss
  @State private var loadGeneration = 0
  @State private var identity: LibraryMetadataStore.Identity?
  @State private var baseline = LibraryMetadataStore.Draft()
  @State private var title = ""
  @State private var tags = ""
  @State private var cover: Data?
  @State private var coverPreview: UIImage?
  @State private var coverURL = ""
  @State private var busy = false
  @State private var saving = false
  @State private var error: String?
  @State private var showImageImporter = false
  @State private var coverTask: Task<Void, Never>?
  @State private var presentation = UUID()

  var body: some View {
    NavigationStack {
      Form {
        Section(header: Text(L("Title"))) {
          TextField(item.title, text: $title)
          Text(L("Leave blank to use the original title."))
          if LibraryMetadataService.discIdentity(for: item) != nil {
            Text(L("Edits apply to copies with the same game ID, disc and revision."))
          } else {
            Text(L("Edits apply to identical files, including renamed copies."))
          }
        }
        .disabled(busy || identity == nil)
        Section(header: Text(L("Classification Tags"))) {
          TextField(L("Tags separated by commas"), text: $tags)
          Text(L("Separate tags with commas. Tags are searchable in the library."))
        }
        .disabled(busy || identity == nil)
        Section(header: Text(L("Cover Artwork"))) {
          Image(uiImage: coverPreview ?? item.originalCoverImage)
            .resizable().scaledToFit()
            .frame(maxHeight: ICubeDesign.LibraryArtwork.editorPreviewHeight)
            .accessibilityLabel(L("Cover preview"))
            #if os(tvOS)
            .focusable()
            #endif
          #if os(iOS)
          Button(L("Choose Cover Image")) { showImageImporter = true }
          #endif
          TextField(L("Cover image URL"), text: $coverURL)
          Button(L("Load Cover from URL")) { loadCoverURL() }
            .disabled(coverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Button(L("Use Original Cover")) { cover = nil }
          Text(L("Cover images are copied into your library edits; the source URL is not saved or synced."))
        }
        .disabled(busy || identity == nil)
        if let error {
          Section {
            Text(error).foregroundStyle(.red)
            if identity == nil { Button(L("Retry")) { loadGeneration += 1 }.disabled(busy) }
          }
        }
        if busy { Section { ProgressView() } }
        Section {
          Button(L("Save")) { save() }.disabled(identity == nil || busy)
          Button(L("Cancel"), role: .cancel) { cancelAndDismiss() }.disabled(saving)
        }
      }
      .disabled(saving)
      .navigationTitle(L("Edit Library Details"))
    }
    .task(id: loadGeneration) { await load() }
    .onChange(of: cover) { _, data in coverPreview = data.flatMap(LibraryMetadataService.coverImage) }
    .onDisappear {
      presentation = UUID()
      coverTask?.cancel()
    }
    #if os(tvOS)
    .onExitCommand { if !saving { cancelAndDismiss() } }
    #endif
    #if os(iOS)
    .interactiveDismissDisabled(saving)
    .fileImporter(isPresented: $showImageImporter, allowedContentTypes: [.image]) { result in
      switch result {
      case .success(let url): loadCoverFile(url)
      case .failure(let failure): error = failure.localizedDescription
      }
    }
    #endif
  }

  @MainActor
  private func load() async {
    let token = presentation
    busy = true
    error = nil
    do {
      let id = try await LibraryMetadataService.resolveIdentity(for: item)
      let draft = try await Task.detached(priority: .utility) {
        try LibraryMetadataService.store().draft(for: id)
      }.value
      guard token == presentation, !Task.isCancelled else { return }
      identity = id; baseline = draft; title = draft.title ?? ""
      tags = draft.tags.joined(separator: ", "); cover = draft.coverData
    } catch {
      guard token == presentation else { return }
      self.error = error.localizedDescription
    }
    if token == presentation { busy = false }
  }

  @MainActor
  private func save() {
    guard let identity, !busy else { return }
    let draft = LibraryMetadataStore.Draft(title: title, coverData: cover,
      tags: tags.components(separatedBy: CharacterSet(charactersIn: ",\n")))
    let baseline = baseline
    saving = true; busy = true; error = nil
    Task {
      do {
        _ = try await Task.detached(priority: .utility) {
          try LibraryMetadataService.store().commit(draft, baseline: baseline, for: identity)
        }.value
        LibraryMetadataService.didChange()
        dismiss()
      } catch {
        self.error = error.localizedDescription
        saving = false; busy = false
      }
    }
  }

  @MainActor
  private func loadCoverURL() {
    guard let url = URL(string: coverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
          ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
      error = L("Enter an HTTP or HTTPS image URL.")
      return
    }
    beginCoverLoad {
      let (stream, response) = try await URLSession.shared.bytes(from: url)
      guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
        throw URLError(.badServerResponse)
      }
      let maximum = 12 * 1024 * 1024
      guard response.expectedContentLength <= maximum else { throw CocoaError(.fileReadTooLarge) }
      var bytes = Data()
      for try await byte in stream {
        try Task.checkCancellation()
        guard bytes.count < maximum else { throw CocoaError(.fileReadTooLarge) }
        bytes.append(byte)
      }
      return bytes
    }
  }

  @MainActor
  private func loadCoverFile(_ url: URL) {
    beginCoverLoad {
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      return try await Task.detached(priority: .utility) { try Self.readCover(url) }.value
    }
  }

  @MainActor
  private func beginCoverLoad(_ operation: @escaping @Sendable () async throws -> Data) {
    coverTask?.cancel()
    let token = UUID()
    presentation = token
    busy = true; error = nil
    coverTask = Task {
      do {
        let bytes = try await operation()
        let image = try await Task.detached(priority: .utility) { try LibraryMetadataService.prepareCover(bytes) }.value
        guard token == presentation, !Task.isCancelled else { return }
        cover = image
      } catch {
        guard token == presentation, !Task.isCancelled else { return }
        self.error = error.localizedDescription
      }
      if token == presentation { busy = false }
    }
  }

  nonisolated private static func readCover(_ url: URL) throws -> Data {
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    guard let size = values.fileSize, size <= 12 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let bytes = try file.read(upToCount: 12 * 1024 * 1024 + 1) ?? Data()
    guard bytes.count <= 12 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
    return bytes
  }

  private func cancelAndDismiss() {
    presentation = UUID(); coverTask?.cancel(); dismiss()
  }
}
