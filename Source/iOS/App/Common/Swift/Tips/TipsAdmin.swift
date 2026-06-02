import Foundation
#if canImport(TipKit)
import TipKit
#endif

@objcMembers
final class TipsAdmin: NSObject {
  static func resetAll() {
    #if canImport(TipKit)
    if #available(iOS 17, tvOS 17, *) {
      try? Tips.resetDatastore()
    }
    #endif
  }
}
