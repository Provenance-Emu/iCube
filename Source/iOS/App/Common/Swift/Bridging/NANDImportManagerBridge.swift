import Foundation

@objc final class NANDImportManager: NSObject {
  @objc static func importNAND(from url: URL) {
    NANDImportManagerObjC.importNAND(from: url)
  }

  /// Imports a BootMii backup on iOS (picked file) and tvOS (Web UI upload). Call on the main thread.
  /// `keysURL` is the keys.bin for a dump without its keys appended. `completion` runs on the main thread when the
  /// import ends, whether or not the progress alert showed; `success` is false when it didn't reach its last step.
  static func importNAND(from url: URL, keysURL: URL? = nil, completion: @escaping (_ success: Bool) -> Void) {
    NANDImportManagerObjC.importNAND(from: url, keysURL: keysURL, completion: completion)
  }
}
