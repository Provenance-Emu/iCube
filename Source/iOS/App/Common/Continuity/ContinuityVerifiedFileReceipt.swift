// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import PVContinuity

/// An optimization after verified import, never proof based on a catalog's size.
/// Callers must obtain the current remote manifest before asking whether to skip.
struct ContinuityVerifiedFileReceipt: Sendable {
    private struct File: Sendable {
        let descriptor: FileDescriptor
        let url: URL
        let fingerprint: ContinuityFileDigestCache.Fingerprint
    }
    private let files: [File]

    init(descriptors: [FileDescriptor], urls: [URL]) throws {
        guard !descriptors.isEmpty, descriptors.count == urls.count else { throw CocoaError(.fileReadCorruptFile) }
        files = try zip(descriptors, urls).map { descriptor, url in
            let fingerprint = try ContinuityFileDigestCache.fingerprint(at: url)
            guard fingerprint.size == descriptor.size else { throw CocoaError(.fileReadCorruptFile) }
            return File(descriptor: descriptor, url: url, fingerprint: fingerprint)
        }
    }

    func matches(current descriptors: [FileDescriptor]) -> Bool {
        guard descriptors.count == files.count else { return false }
        let grouped = Dictionary(grouping: descriptors, by: \.relativePath)
        guard grouped.count == descriptors.count else { return false }
        return files.allSatisfy { file in
            guard let current = grouped[file.descriptor.relativePath]?.first,
                  current.kind == file.descriptor.kind,
                  current.sha256 == file.descriptor.sha256,
                  current.size == file.descriptor.size else { return false }
            return (try? ContinuityFileDigestCache.fingerprint(at: file.url)) == file.fingerprint
        }
    }
}
