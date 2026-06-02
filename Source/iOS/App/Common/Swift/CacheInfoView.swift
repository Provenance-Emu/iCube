// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

// MARK: - Unified Game Card

// Both iOS and tvOS now use the same clean implementation in GameGridItem

/// View showing cache information for a remote game
struct CacheInfoView: View {
  let item: TVGameItem
  let showSubtitles: Bool
  @Environment(\.dismiss) private var dismiss
  @State private var cacheInfo: CacheInfo?
  @State private var isLoading = true
  @State private var errorMessage: String?
  @State private var isWorking = false
  @State private var redownloadProgress: Double = 0
  @State private var showCopiedToast: Bool = false
  @State private var shareURL: URL?
  @State private var toastText: String?
  @State private var showAlert = false
  @State private var alertTitle = ""
  @State private var alertMessage = ""

  private struct CacheInfo {
    let localPath: String
    let fileSize: Int64
    let cachedDate: Date
    let originalURL: String
    let etag: String?
    let lastModified: Date?
  }

  var body: some View {
    NavigationView {
      GeometryReader { proxy in
        let w = max(320.0, min(proxy.size.width - 32.0, 680.0))
        ZStack {
          /// Blurred artwork background for visual depth
          Image(uiImage: item.coverImage)
            .resizable()
            .scaledToFill()
            .blur(radius: 20)
            .opacity(0.35)
            .ignoresSafeArea()

          if isLoading {
            DolphinLoadingView(message: "Loading cache information...")
              .padding(24)
              .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
              .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 6)
          } else if let errorMessage = errorMessage {
            DolphinErrorView(
              title: "Cache Error",
              message: errorMessage
            )
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 6)
          } else if let info = cacheInfo {
            ScrollView {
              VStack(alignment: .leading, spacing: 16) {
                /// Header card with cover and basic details
                HStack(alignment: .top, spacing: 16) {
                  Image(uiImage: item.coverImage)
                    .resizable()
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .frame(width: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 6)
                  VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                      .font(.title3).fontWeight(.semibold)
                      .lineLimit(2)
                    if showSubtitles {
                      Text(item.gameID)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    }
                    HStack(spacing: 6) {
                      Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                      Text("Cached \(DateFormatter.localizedString(from: info.cachedDate, dateStyle: .medium, timeStyle: .short))")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    }
                  }
                  Spacer(minLength: 0)
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))

                /// Details card
                VStack(spacing: 10) {
                  KVRow(icon: "externaldrive", label: "Original URL", value: info.originalURL)
                  KVRow(icon: "internaldrive", label: "Local Path", value: info.localPath, monospaced: true)
                  KVRow(icon: "externaldrive.badge.person.crop", label: "ETag", value: info.etag ?? "-")
                  KVRow(icon: "clock", label: "Last Modified", value: info.lastModified.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "-")
                  KVRow(icon: "archivebox", label: "File Size", value: TVLibraryView.formatStorageSpace(info.fileSize))
                }
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))

                // Actions grid (fits better than toolbar on small widths)
                let gridCols: [GridItem] = {
                  if proxy.size.width < 370 { return [GridItem(.flexible(), spacing: 12)] }
                  if proxy.size.width < 700 { return [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)] }
                  return [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
                }()
                if let info = cacheInfo {
                  LazyVGrid(columns: gridCols, spacing: 12) {
                    Button(role: .destructive) { performRemove() } label: {
                      HStack { Image(systemName: "trash")
                        Text(L("Remove"))
                      }
                      .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(isWorking)

                    Button { performRedownload() } label: {
                      if isWorking && redownloadProgress > 0 {
                        DolphinProgressView(
                          progress: redownloadProgress,
                          width: 120,
                          showPercentage: true,
                          direction: .leftToRight
                        )
                        .frame(maxWidth: .infinity)
                      } else {
                        HStack { Image(systemName: "arrow.down.circle")
                          Text(L("Re-download"))
                        }
                        .frame(maxWidth: .infinity)
                      }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isWorking)

                    Button { copyToPasteboard(info.originalURL) } label: {
                      HStack { Image(systemName: "doc.on.doc")
                        Text(L("Copy URL"))
                      }
                      .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button { copyToPasteboard(info.localPath) } label: {
                      HStack { Image(systemName: "folder")
                        Text(L("Copy Path"))
                      }
                      .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    #if os(iOS)
                    if FileManager.default.fileExists(atPath: info.localPath) {
                      Button { shareFile(path: info.localPath) } label: {
                        HStack { Image(systemName: "square.and.arrow.up")
                          Text(L("Share"))
                        }
                        .frame(maxWidth: .infinity)
                      }
                      .buttonStyle(.bordered)
                    }
                    #endif
                  }
                  .padding(.top, 8)
                }
              }
              .frame(maxWidth: w)
              .padding(.horizontal, 16)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.vertical, 16)
            }
          } else {
            VStack(spacing: 12) {
              Image(systemName: "questionmark.circle")
                .font(.system(size: 44, weight: .semibold))
                .foregroundColor(.secondary)
              Text("No cache information available")
                .foregroundColor(.secondary)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 6)
          }
        }
      }
      .navigationTitle("Cache Info")
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("Done") { dismiss() }
        }
      }
      .onAppear {
        loadCacheInfo()
      }
      #if os(iOS)
      .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
        Group {
          if let url = shareURL {
            ShareSheet(activityItems: [url])
              .ignoresSafeArea()
          } else {
            EmptyView()
          }
        }
      }
      #endif
      .overlay(
        Group {
          if let toast = toastText {
            VStack {
              Spacer()
              Text(toast)
                .font(.footnote)
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.7), in: Capsule())
                .padding(.bottom, 20)
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: toastText)
          }
        }
      )
      .alert(alertTitle, isPresented: $showAlert) {
        Button(L("OK"), role: .cancel) {}
      } message: {
        Text(alertMessage)
      }
    }
  }

  private func loadCacheInfo() {
    // Find the WebDAV source for this item
    guard let url = URL(string: item.filePath) else {
      errorMessage = "Invalid file path"
      isLoading = false
      return
    }

    if let source = getMatchingWebDAVSource(for: url) {
      let remoteItem = RemoteLibraryItem(url: url, name: item.title, size: Int64(item.fileSize))
      // Check if cached and get info
      Task {
        let info = await getCacheInfo(from: source, for: remoteItem)
        await MainActor.run {
          self.cacheInfo = info
          self.isLoading = false
          self.errorMessage = info == nil ? "This game is not currently cached" : nil
        }
      }
    } else {
      errorMessage = "No WebDAV source found for this game"
      isLoading = false
      cacheInfo = nil
    }
  }

  private func getCacheInfo(from source: WebDAVSource, for item: RemoteLibraryItem) async -> CacheInfo? {
    // Get actual cache information from the WebDAV source
    guard let cachedFileInfo = source.getCacheInfo(for: item) else {
      return nil
    }

    return CacheInfo(
      localPath: cachedFileInfo.localPath,
      fileSize: cachedFileInfo.fileSize,
      cachedDate: cachedFileInfo.cachedDate,
      originalURL: cachedFileInfo.originalURL,
      etag: cachedFileInfo.etag,
      lastModified: cachedFileInfo.lastModified
    )
  }

  private func performRemove() {
    guard let url = URL(string: item.filePath), let source = getMatchingWebDAVSource(for: url) else { return }
    let remoteItem = RemoteLibraryItem(url: url, name: item.title, size: Int64(item.fileSize))
    isWorking = true
    Task {
      do {
        try await source.removeCachedItem(remoteItem)
        await MainActor.run {
          isWorking = false
          // Optimistically clear current info
          self.cacheInfo = nil
          self.errorMessage = "This game is not currently cached"
          loadCacheInfo()
          NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Removed from cache")])
          toastText = L("Removed from cache")
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { toastText = nil }
          alertTitle = L("Removed")
          alertMessage = L("The cached file was removed.")
          showAlert = true
        }
      } catch {
        await MainActor.run { isWorking = false }
      }
    }
  }

  private func performRedownload() {
    guard let url = URL(string: item.filePath), let source = getMatchingWebDAVSource(for: url) else { return }
    let remoteItem = RemoteLibraryItem(url: url, name: item.title, size: Int64(item.fileSize))
    isWorking = true
    redownloadProgress = 0
    Task {
      do {
        _ = try await source.forcePreCacheItem(remoteItem) { progress in
          DispatchQueue.main.async { self.redownloadProgress = progress }
        }
        await MainActor.run {
          isWorking = false
          loadCacheInfo()
          NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Downloaded to cache")])
          toastText = L("Downloaded to cache")
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { toastText = nil }
          alertTitle = L("Downloaded")
          alertMessage = L("The file has been downloaded to cache.")
          showAlert = true
        }
      } catch {
        await MainActor.run { isWorking = false }
      }
    }
  }

  private func copyToPasteboard(_ text: String) {
    #if os(iOS)
    UIPasteboard.general.string = text
    showCopiedToast = true
    toastText = L("Copied")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { showCopiedToast = false
      toastText = nil
    }
    alertTitle = L("Copied")
    alertMessage = text
    showAlert = true
    #endif
  }

  #if os(iOS)
  private func shareFile(path: String) {
    let url = URL(fileURLWithPath: path)
    shareURL = url
  }
  #endif
}

/// Labeled row with SF Symbol and value, used in cache details card
private struct KVRow: View {
  let icon: String
  let label: String
  let value: String
  var monospaced: Bool = false

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .frame(width: 18)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(label)
          .font(.caption)
          .foregroundColor(.secondary)
          .textCase(.uppercase)
        #if os(tvOS)
        if monospaced {
          Text(value).font(.callout).monospaced().lineLimit(nil)
        } else {
          Text(value).font(.callout).lineLimit(nil)
        }
        #else
        if monospaced {
          Text(value).font(.callout).textSelection(.enabled).monospaced().lineLimit(nil)
        } else {
          Text(value).font(.callout).textSelection(.enabled).lineLimit(nil)
        }
        #endif
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
