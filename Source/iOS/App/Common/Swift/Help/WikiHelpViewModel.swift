// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import PVHelp

@MainActor
final class WikiHelpViewModel: ObservableObject {
  @Published var navigationTree: WikiNavigationTree?
  @Published var currentPage: WikiPage?
  @Published var isLoadingTree = false
  @Published var isLoadingPage = false

  private let provider = WikiContentProvider(configuration: ICubeWiki.configuration, hiddenPaths: WikiHelpViewModel.hiddenPaths())

  /// Pages Help must not list. The App Store build lists the JIT guide only on a re-signed install where JIT is
  /// detected; the filter runs after parsing, so neither the bundled nor the remote `SUMMARY.md` can bring it back.
  nonisolated static func hiddenPaths(isAppStore: Bool = isAppStoreBuild, jitSupported: Bool = JitManager.shared().jitSupported) -> Set<String> {
    isAppStore && !jitSupported ? [ICubeWiki.Paths.jitGuide] : []
  }

  private nonisolated static var isAppStoreBuild: Bool {
    #if APPSTORE
    true
    #else
    false
    #endif
  }

  func loadNavigationTree() async {
    guard navigationTree == nil else { return }
    isLoadingTree = true
    navigationTree = await provider.loadNavigationTree()
    isLoadingTree = false
  }

  func loadPage(path: String, title: String) async {
    isLoadingPage = true
    currentPage = await provider.loadPage(path: path, title: title)
    isLoadingPage = false
  }
}
