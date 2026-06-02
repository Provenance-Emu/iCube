import Foundation

#if os(iOS)
@objc final class NANDImportManager: NSObject {
  @objc static func importNAND(from url: URL) {
    NANDImportManagerObjC.importNAND(from: url)
  }
}
#endif
