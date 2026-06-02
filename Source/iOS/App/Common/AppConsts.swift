// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

public struct AppConsts {
  static var useSwiftUI: Bool {
    #if os(tvOS)
    return true
    #elseif targetEnvironment(macCatalyst)
    return true
    #elseif os(iOS)
    return true
    #else
    return true
    #endif
  }
}
