// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Stand-in for the Riivolution installer and the disc-patch flow, which land on other branches.
/// Delete this file and pass the real `ModInstallHandling` at the one place that builds
/// `ModBrowserRoot` (`ModBrowserSheet.swift`) when they merge.
struct PendingModInstallHandler: ModInstallHandling {
  struct NotAvailableError: LocalizedError {
    var errorDescription: String? { L("Not available in this build") }
  }

  func installRiivolutionPack(at root: URL) async throws -> String {
    throw NotAvailableError()
  }

  func presentDiscPatch(_ patches: [URL], suggestedGameID: String?) {
    Task { @MainActor in
      ModBrowserPresenter.shared.notice = NotAvailableError().localizedDescription
    }
  }
}
