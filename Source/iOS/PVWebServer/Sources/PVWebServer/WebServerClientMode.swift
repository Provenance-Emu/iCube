// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
//  WebServerClientMode.swift
//  PVWebServer
//
//  One port serves both the browser upload UI and WebDAV. This decides, per request,
//  which one a client is. The result is stored per connection so a keep-alive socket
//  (Finder pipelines many requests) never flips mode mid-session.

import Foundation

enum WebServerClientMode: Equatable {
    case unknown
    case browser
    case webDAV

    /// Order of precedence matches the spec, section 4.1. Never returns `.unknown`.
    static func resolve(_ request: HTTPRequest, stored: WebServerClientMode) -> WebServerClientMode {
        if isDefinitelyBrowserRequest(request) { return .browser }
        if isDefinitelyWebDAVMethod(request.method) { return .webDAV }
        if stored != .unknown { return stored }
        if hasWebDAVSignalHeaders(request) { return .webDAV }
        if let ua = request.headers["user-agent"] {
            if isWebDAVUserAgent(ua) { return .webDAV }
            if isBrowserUserAgent(ua) { return .browser }
        }
        return methodHeuristicSaysWebDAV(request) ? .webDAV : .browser
    }

    /// Upload UI endpoints always route to the browser handler, whatever the User-Agent.
    private static func isDefinitelyBrowserRequest(_ request: HTTPRequest) -> Bool {
        switch request.method {
        case "POST":
            return ["/upload", "/move", "/mkdir"].contains { request.path.hasPrefix($0) }
        case "GET", "HEAD":
            return request.path.hasPrefix("/files/") || request.path.hasPrefix("/api/")
        case "PUT", "DELETE":
            return request.path.hasPrefix("/files/")
        default:
            return false
        }
    }

    private static func isDefinitelyWebDAVMethod(_ method: String) -> Bool {
        switch method {
        case "PROPFIND", "PROPPATCH", "MKCOL", "MOVE", "COPY", "LOCK", "UNLOCK", "PUT":
            return true
        default:
            return false
        }
    }

    private static func hasWebDAVSignalHeaders(_ request: HTTPRequest) -> Bool {
        let h = request.headers
        if h["depth"] != nil || h["destination"] != nil || h["lock-token"] != nil || h["overwrite"] != nil {
            return true
        }
        if let translate = h["translate"], !translate.isEmpty { return true } // Windows WebClient
        if let ifHeader = h["if"]?.lowercased(), ifHeader.contains("locktoken") { return true }
        return false
    }

    private static let webDAVUserAgentMarkers = [
        "webdavfs/", "webdavlib/", "microsoft-webdav-miniredir",
        "microsoft data access internet publishing provider",
        "cyberduck/", "davfs2/", "rclone/", "cadaver/", "netdrive/", "sardine/", "transmit/",
        "forklift/", "gvfs/", "litmus/", "mountain duck/", "mountainduck/", "bitkinex/",
        "owncloud-client", "nextcloud-android", "winscp/"
    ]

    private static func isWebDAVUserAgent(_ userAgent: String) -> Bool {
        let ua = userAgent.lowercased()
        return webDAVUserAgentMarkers.contains { ua.hasPrefix($0) || ua.contains($0) }
    }

    private static func isBrowserUserAgent(_ userAgent: String) -> Bool {
        let ua = userAgent.lowercased()
        return ua.hasPrefix("mozilla/") || ua.hasPrefix("opera/") || ua.contains("applewebkit/")
    }

    /// curl and scripts send no useful headers. Anything that is not the page or a
    /// browser download looks like a WebDAV filesystem walk.
    private static func methodHeuristicSaysWebDAV(_ request: HTTPRequest) -> Bool {
        switch request.method {
        case "OPTIONS":
            return true
        case "GET", "HEAD":
            if request.path == "/" { return false }
            if request.path.hasPrefix("/files/") { return false }
            return true
        case "DELETE":
            return !request.path.hasPrefix("/files/")
        default:
            return false
        }
    }
}
