import Foundation

enum DolphinPaths {
  static func stateSavesURL() -> URL? {
    // Prefer core-provided path if bridge is available
    if let url = bridgedStateSavesURL() { return url }
    // Fallback: construct sandbox path mirroring Dolphin's User/StateSaves
    let fm = FileManager.default
    #if os(tvOS)
    let base = try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    #else
    let base = try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    #endif
    guard let base else { return nil }
    let user = base.appendingPathComponent("User", isDirectory: true)
    let root = user.appendingPathComponent("StateSaves", isDirectory: true)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    #if !os(tvOS)
    var rv = URLResourceValues()
    rv.isExcludedFromBackup = true
    var mutable = root
    try? mutable.setResourceValues(rv)
    #endif
    return root
  }

  /// Root of Dolphin's `User/` directory. Every CloudKit sync record name is a
  /// path relative to this, so it comes from Dolphin's own path system rather
  /// than being derived by walking up from `StateSaves`.
  static func userDirectoryURL() -> URL? {
    if let path = DolphinGetUserPathC().map({ String(cString: $0) }), !path.isEmpty {
      let url = URL(fileURLWithPath: path, isDirectory: true)
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return url
    }
    // Fallback mirrors stateSavesURL()'s: the sandbox layout Dolphin would have
    // produced. Sync stays inert rather than syncing the wrong tree if both the
    // bridge and this are unavailable.
    let fm = FileManager.default
    #if os(tvOS)
    let base = try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    #else
    let base = try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    #endif
    guard let base else { return nil }
    let user = base.appendingPathComponent("User", isDirectory: true)
    guard fm.fileExists(atPath: user.path) else { return nil }
    return user
  }

  private static func bridgedStateSavesURL() -> URL? {
    // Function is provided by DolphinPathsBridge.mm via bridging header
    guard let pathCString = DolphinGetStateSavesPathC() else { return nil }
    let path = String(cString: pathCString)
    if path.isEmpty { return nil }
    let url = URL(fileURLWithPath: path, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
