import Foundation
import SwiftUI

#if canImport(TipKit)
import TipKit

@available(iOS 17, tvOS 17, *)
struct ImportGameTip: Tip {
  /// The first-run welcome already offers Import; the tip waits until the welcome is gone.
  @Parameter static var welcomeFinished: Bool = false

  var title: Text { Text(L("Import Game")) }
  var message: Text { Text(L("Add ROMs from Files or other apps.")) }
  var image: Image? { Image(systemName: "square.and.arrow.down") }
  var rules: [Rule] { [#Rule(Self.$welcomeFinished) { $0 == true }] }
  // Show at most once ever; the persistent datastore remembers this across
  // launches even if the popover is dismissed by navigating away (which does
  // not call invalidate()). Without this a ruleless tip stays eligible forever
  // and re-appears on every launch.
  var options: [any Tip.Option] { [Tips.MaxDisplayCount(1)] }
}

#endif

/// Tip state the library sets without importing TipKit at every call site.
enum LibraryTipsState {
  /// The welcome is gone. A user who picked one of its routes has learned where import lives, so the tip is spent.
  static func welcomeFinished(choseAnAction: Bool) {
    #if canImport(TipKit)
    ImportGameTip.welcomeFinished = true
    if choseAnAction {
      ImportGameTip().invalidate(reason: .actionPerformed)
    }
    #endif
  }
}
