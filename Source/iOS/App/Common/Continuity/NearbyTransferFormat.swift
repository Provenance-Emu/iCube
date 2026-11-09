// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A fixed unit and precision across the transfer: 9.9 -> 10.0 MB never
/// switches to a differently sized KB/GB string. Reserve the final label width.
enum NearbyTransferFormat {
  static func label(bytes: Int64, total: Int64, locale: Locale = .current) -> String {
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.minimumFractionDigits = 1
    formatter.maximumFractionDigits = 1
    formatter.numberStyle = .decimal
    let amount = formatter.string(from: NSNumber(value: Double(max(0, bytes)) / 1_000_000)) ?? "0.0"
    let maximum = formatter.string(from: NSNumber(value: Double(max(0, total)) / 1_000_000)) ?? "0.0"
    return String(format: L("%@ / %@ MB"), amount, maximum)
  }
}
