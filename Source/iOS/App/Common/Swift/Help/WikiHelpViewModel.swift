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

  private let provider = WikiContentProvider()

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
