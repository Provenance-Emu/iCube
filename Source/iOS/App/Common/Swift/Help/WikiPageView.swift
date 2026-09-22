// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import PVHelp
#if canImport(SafariServices)
import SafariServices
#endif

/// Renders a single wiki page (cache-first, bundled-offline-fallback via
/// `WikiContentProvider` — see that type for the fallback order). Works fully offline once
/// the app has shipped once, because the three starter pages are bundled with the app, not
/// only cached from a live fetch.
struct WikiPageView: View {
  let path: String
  let title: String

  @StateObject private var viewModel = WikiHelpViewModel()

  var body: some View {
    Group {
      if let page = viewModel.currentPage {
        ScrollView {
          MarkdownContentView(markdown: page.content)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        loadingView
      }
    }
    .navigationTitle(title)
    .accessibilityLabel(title)
#if os(tvOS)
    .focusSection()
#endif
#if os(iOS)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        viewOnWebButton
      }
    }
#endif
    .task {
      await viewModel.loadPage(path: path, title: title)
    }
  }

  private var loadingView: some View {
    VStack(spacing: 16) {
      ProgressView()
      Text(L("Loading page..."))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

#if os(iOS)
  @State private var showSafari = false

  private var viewOnWebButton: some View {
    Button {
      showSafari = true
    } label: {
      Label(L("View on Web"), systemImage: "safari")
    }
    .accessibilityLabel(L("View on Web"))
    .sheet(isPresented: $showSafari) {
      SafariView(url: WikiConstants.webURL(for: path))
    }
  }
#endif
}
