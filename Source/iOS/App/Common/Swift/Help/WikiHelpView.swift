// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import PVHelp

/// Top-level in-app documentation browser. Its table of contents IS the wiki's own
/// `SUMMARY.md` (see `WikiContentProvider.loadNavigationTree()`), so this view never needs to
/// change when pages are added or reorganized — only the content source does.
///
/// This is iCube's real Help surface on both iOS and tvOS (replacing the tvOS
/// `HelpPlaceholderView` TODO stub and the iOS "open a website" button). It is intentionally
/// separate from the per-setting `HelpButton`/`HelpSheetButton` tooltip mechanism elsewhere in
/// `SettingsRootView.swift`: that one shows a short inline explanation for a single control
/// (its text lives in Core.strings, localized per-string); this one is the full guide/FAQ
/// browser (its content lives in Markdown, fetched/cached/bundled). They coexist on purpose —
/// merging them would mean moving every `helpKey` string out of Core.strings into Markdown,
/// which is out of scope here and would touch localization infrastructure this task must not.
struct WikiHelpView: View {
  @StateObject private var viewModel = WikiHelpViewModel()

  var body: some View {
    Group {
      if viewModel.isLoadingTree {
        loadingView
      } else if let tree = viewModel.navigationTree, !tree.sections.isEmpty {
        navigationList(tree: tree)
      } else {
        emptyView
      }
    }
    .navigationTitle(L("Help"))
#if os(tvOS)
    .focusSection()
#endif
    .task {
      await viewModel.loadNavigationTree()
    }
  }

  private var loadingView: some View {
    VStack(spacing: 16) {
      ProgressView()
      Text(L("Loading Help..."))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyView: some View {
    VStack(spacing: 16) {
      Image(systemName: "questionmark.circle")
        .font(.largeTitle)
        .foregroundStyle(.secondary)
      Text(L("Help content isn't available right now."))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button(L("Retry")) {
        Task { await viewModel.loadNavigationTree() }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  private func navigationList(tree: WikiNavigationTree) -> some View {
    List {
      ForEach(tree.sections) { section in
        if section.title.isEmpty {
          ForEach(section.items) { item in
            navItemRow(item)
          }
        } else {
          Section(header: Text(section.title)) {
            ForEach(section.items) { item in
              navItemRow(item)
            }
          }
        }
      }
    }
#if os(tvOS)
    .listStyle(.grouped)
#endif
  }

  @ViewBuilder
  private func navItemRow(_ item: WikiNavItem) -> some View {
    NavigationLink(destination: WikiPageView(path: item.path, title: item.title)) {
      Label(item.title, systemImage: icon(forPath: item.path))
        .accessibilityLabel(item.title)
    }
    if !item.children.isEmpty {
      ForEach(item.children) { child in
        NavigationLink(destination: WikiPageView(path: child.path, title: child.title)) {
          Label(child.title, systemImage: icon(forPath: child.path))
            .padding(.leading, 16)
            .accessibilityLabel(child.title)
        }
      }
    }
  }

  private func icon(forPath path: String) -> String {
    if path.contains("jit") { return "cpu" }
    if path.contains("web-import") { return "wifi" }
    if path.contains("bios") { return "opticaldiscdrive" }
    if path.contains("save-state") { return "externaldrive" }
    if path == "README.md" { return "house" }
    return "doc.text"
  }
}
