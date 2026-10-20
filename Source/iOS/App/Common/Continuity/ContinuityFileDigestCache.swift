// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin
import PVContinuity

/// SHA-256 cache for served files. Filesystem identity and nanosecond timestamps
/// distinguish replacement and in-place writes, including preserved mtimes.
final class ContinuityFileDigestCache: @unchecked Sendable {
    struct Fingerprint: Equatable, Codable, Sendable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
        var modifiedAt: Date {
            Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1_000_000_000)
        }
    }
    struct Digest: Sendable {
        let sha256: String
        let fingerprint: Fingerprint
    }
    static let shared = ContinuityFileDigestCache()
    private let hash: @Sendable (URL) throws -> String
    private let lock = NSLock()
    private var cached: [String: Digest] = [:]

    init(hash: @escaping @Sendable (URL) throws -> String = { try ContinuityHash.sha256Hex(ofFileAt: $0) }) {
        self.hash = hash
    }

    func digest(at url: URL) throws -> Digest {
        do {
            let before = try Self.fingerprint(at: url)
            lock.lock()
            let previous = cached[url.path]
            if previous?.fingerprint != before { cached[url.path] = nil }
            lock.unlock()
            if let previous, previous.fingerprint == before { return previous }
            // Streaming multi-GB files must never hold the cache lock.
            let sha256 = try hash(url)
            let after = try Self.fingerprint(at: url)
            guard before == after else { throw CocoaError(.fileReadUnknown) }
            let result = Digest(sha256: sha256, fingerprint: after)
            lock.lock(); cached[url.path] = result; lock.unlock()
            return result
        } catch {
            invalidate(url)
            throw error
        }
    }

    func invalidate(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        cached[url.path] = nil
    }

    static func fingerprint(at url: URL) throws -> Fingerprint {
        var info = stat()
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &info)
        }
        guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw CocoaError(.fileReadInvalidFileName) }
        return Fingerprint(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino), size: Int64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }
}
