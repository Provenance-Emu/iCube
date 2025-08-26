// Copyright 2023 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit

#if os(iOS)

typealias DOLSwitch = DOLUIKitSwitch

#elseif os(tvOS)

@_exported import Foundation
@_exported import UIKit

typealias DOLSwitch = DOLTVSwitch

#else

#error("Unsupported platform")

#endif
