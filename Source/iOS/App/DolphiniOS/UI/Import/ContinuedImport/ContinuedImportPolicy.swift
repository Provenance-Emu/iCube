// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

// Pure decision types for keeping a long import alive after the user leaves the app.
// Nothing here imports UIKit or BackgroundTasks, so it compiles (and is tested) everywhere.

/// What the running process is, reduced to the facts that decide whether `BGContinuedProcessingTask` exists.
struct ImportPlatform: Equatable {
  /// False on tvOS (the API is `API_UNAVAILABLE(tvos)`).
  var isIOS: Bool
  var isMacCatalyst: Bool
  /// The iPad app running on a Mac. `#available(iOS 26, *)` is true there, but the API is unavailable on macOS.
  var isiOSAppOnMac: Bool
  /// The iPad app running on visionOS (the API is unavailable there).
  var isiOSAppOnVision: Bool
  var osMajorVersion: Int
  /// The API requires submission from the foreground, as the result of a user action.
  var appIsActive: Bool
}

/// How a user-started import is kept running when the user leaves the app.
enum ImportKeepAliveMechanism: Equatable {
  /// Today's behaviour: a short UIKit background task and nothing else.
  case legacyBackgroundTask
  /// iOS 26+: a system-visible continued-processing task (the UIKit task still covers the gap before it starts).
  case continuedProcessing
}

enum ContinuedImportPolicy {
  static let minimumOSMajorVersion = 26

  /// Below this a copy finishes in a second or two; a system progress UI for it is noise, and
  /// the UIKit background task is plenty.
  static let minimumTotalBytes: Int64 = 64 * 1024 * 1024

  static func mechanism(platform: ImportPlatform,
                        totalBytes: Int64,
                        userInitiated: Bool) -> ImportKeepAliveMechanism {
    guard userInitiated,
          platform.isIOS,
          !platform.isMacCatalyst,
          !platform.isiOSAppOnMac,
          !platform.isiOSAppOnVision,
          platform.osMajorVersion >= minimumOSMajorVersion,
          platform.appIsActive,
          totalBytes >= minimumTotalBytes else {
      return .legacyBackgroundTask
    }
    return .continuedProcessing
  }
}

/// How a batch of import work ended, and what that means for the system task and the staging files.
enum ImportTerminationOutcome: Equatable {
  /// Every file that was started finished and was renamed into place.
  case completed
  /// Stopped early because the system expired the task or the user cancelled it from the system UI.
  /// (The docs say a user cancel arrives through the expiration handler, so the two are one case.)
  case stopped
  /// An error ended the work.
  case failed

  /// The value for `setTaskCompletedWithSuccess:`.
  var reportsTaskSuccess: Bool { self == .completed }

  /// Whether the file being copied when the work ended must be removed. A completed copy was
  /// renamed into place; anything else leaves only a `.importing` file, which is never kept.
  var removesStagedFile: Bool { self != .completed }

  /// Whether the user should be told the import did not run to the end.
  var showsStoppedMessage: Bool { self == .stopped }
}
