// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
//  UploadFailure.swift
//  PVWebServer
//
//  Why a finished upload must not be reported as success. Pure so it is testable
//  without a socket.

import Foundation

enum UploadFailure: Equatable {
    case diskFull
    case writeError
    /// The socket closed before `Content-Length` bytes arrived.
    case truncated

    var httpStatus: Int {
        switch self {
        case .diskFull: return 507
        case .writeError, .truncated: return 500
        }
    }

    var statusText: String {
        switch self {
        case .diskFull: return "Insufficient Storage"
        case .writeError, .truncated: return "Internal Server Error"
        }
    }

    var logReason: String {
        switch self {
        case .diskFull: return "disk full"
        case .writeError: return "write error"
        case .truncated: return "connection closed before Content-Length"
        }
    }

    /// Call only after `writer.finalize`'s completion has run.
    static func classify(writer: SerialFileWriter, truncated: Bool) -> UploadFailure? {
        if writer.failed { return writer.diskFull ? .diskFull : .writeError }
        if truncated { return .truncated }
        return nil
    }
}
