// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Fires a callback when a directory changes, debounced.
///
/// A save state write is a burst of filesystem events, not one; without the
/// debounce every burst would kick a full sync. 500 ms matches iFly.
///
/// Watches the directory itself, not its subtree — `DISPATCH_SOURCE_TYPE_VNODE`
/// has no recursive mode. The coordinator therefore installs one watcher per
/// directory it cares about.
public actor DirectoryWatcher {

    private let url: URL
    private let debounceInterval: TimeInterval
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var debounceTask: Task<Void, Never>?
    private var onChange: (@Sendable () async -> Void)?

    public init(url: URL, debounceInterval: TimeInterval = CloudSyncConstants.watcherDebounceInterval) {
        self.url = url
        self.debounceInterval = debounceInterval
    }

    public func setOnChange(_ callback: @escaping @Sendable () async -> Void) {
        onChange = callback
    }

    /// Begin watching, creating the directory if it does not exist yet.
    public func startWatching() throws {
        guard dispatchSource == nil else { return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        fileDescriptor = descriptor

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { await self?.handleChange() }
        }
        // Captured by value: `fileDescriptor` is reset before the cancel handler
        // runs, so reading it here would close nothing.
        source.setCancelHandler {
            if descriptor >= 0 { close(descriptor) }
        }
        source.resume()
        dispatchSource = source
    }

    public func stopWatching() {
        debounceTask?.cancel()
        debounceTask = nil
        dispatchSource?.cancel()
        dispatchSource = nil
        fileDescriptor = -1
        onChange = nil
    }

    private func handleChange() {
        debounceTask?.cancel()
        let interval = debounceInterval
        let callback = onChange
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await callback?()
        }
    }

    deinit {
        dispatchSource?.cancel()
        if fileDescriptor >= 0 { close(fileDescriptor) }
    }
}
