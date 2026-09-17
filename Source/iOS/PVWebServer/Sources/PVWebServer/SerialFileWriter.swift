// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
//  SerialFileWriter.swift
//  PVWebServer
//
//  Offloads `FileHandle` writes to a per-file serial queue so `NWConnection.receive`
//  can schedule the next socket read without waiting on flash I/O. Records write and
//  close failures: a disk-full upload used to truncate the file while the client got
//  a 2xx, so callers MUST consult `failed` before reporting success.

import Foundation

final class SerialFileWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let queue: DispatchQueue

    /// A write or close threw. Read only after `finalize`'s completion has run.
    private(set) var failed = false
    /// The failure was ENOSPC, so the caller can answer 507.
    private(set) var diskFull = false
    private(set) var bytesWritten = 0

    init?(at url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else { return nil }
        self.handle = handle
        self.queue = Self.makeQueue()
    }

    init(handle: FileHandle) {
        self.handle = handle
        self.queue = Self.makeQueue()
    }

    private static func makeQueue() -> DispatchQueue {
        DispatchQueue(label: "org.dolphin.iCube.uploadserver.disk.\(UUID().uuidString)", qos: .utility)
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async {
            guard !self.failed else { return }
            do {
                try self.handle.write(contentsOf: data)
                self.bytesWritten += data.count
            } catch {
                self.recordFailure(error, context: "write after \(self.bytesWritten) bytes")
            }
        }
    }

    func finalize(completion: @escaping @Sendable () -> Void) {
        queue.async {
            do {
                try self.handle.close()
            } catch {
                if !self.failed { self.recordFailure(error, context: "close") }
            }
            DispatchQueue.global(qos: .userInitiated).async(execute: completion)
        }
    }

    private func recordFailure(_ error: Error, context: String) {
        failed = true
        let ns = error as NSError
        let underlying = (ns.userInfo[NSUnderlyingErrorKey] as? NSError)?.code
        if ns.code == Int(ENOSPC) || underlying == Int(ENOSPC) { diskFull = true }
        NSLog("%@", "[ROMUploadServer] upload \(context) failed\(diskFull ? " (disk full)" : ""): \(error)")
    }
}
