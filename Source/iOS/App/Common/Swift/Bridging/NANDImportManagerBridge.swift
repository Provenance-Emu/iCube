import Foundation

@objc final class NANDImportManager: NSObject {
  @objc static func importNAND(from url: URL) {
    NANDImportManagerObjC.importNAND(from: url)
  }

  /// Imports a BootMii backup on iOS (picked file) and tvOS (Web UI upload). Call on the main thread.
  /// `completion` runs on the main thread once the progress alert is gone; `success` is false when the
  /// import didn't reach its last step.
  static func importNAND(from url: URL, completion: @escaping (_ success: Bool) -> Void) {
    NANDImportManagerObjC.importNAND(from: url, completion: completion)
  }
}
