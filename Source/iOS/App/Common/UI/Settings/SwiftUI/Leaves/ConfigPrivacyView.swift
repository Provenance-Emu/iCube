// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Privacy, on the menu engine. `sync()` reads the stored choice and writes nothing; `apply(_:)` is the only writer, and goes
/// through `SentryTelemetryService.applyConsent` so the SDK starts or stops (and its disk queue is deleted) with the switch.
struct ConfigPrivacyView: View {
  @State private var crashReports = true

  var body: some View {
    SettingsLeafScreen(model: ConfigPrivacyModelBuilder.make(crashReports: crashReports, apply: apply), title: L("Privacy"), sync: sync)
  }

  private func sync() {
    crashReports = TelemetryConsent.isEnabled()
  }

  private func apply(_ on: Bool) {
    crashReports = on
    Task { @MainActor in SentryTelemetryService.applyConsent(on) }
  }
}
