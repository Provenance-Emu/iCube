import Foundation
import SwiftUI

#if canImport(TipKit)
import TipKit

@available(iOS 17, tvOS 17, *)
struct ImportGameTip: Tip {
  var title: Text { Text(L("Import Game")) }
  var message: Text { Text(L("Add ROMs from Files or other apps.")) }
  var image: Image? { Image(systemName: "square.and.arrow.down") }
  // Show at most once ever; the persistent datastore remembers this across
  // launches even if the popover is dismissed by navigating away (which does
  // not call invalidate()). Without this a ruleless tip stays eligible forever
  // and re-appears on every launch.
  var options: [any Tip.Option] { [Tips.MaxDisplayCount(1)] }
}

#endif
