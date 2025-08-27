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
