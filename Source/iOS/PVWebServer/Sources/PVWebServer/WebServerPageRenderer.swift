// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
//  WebServerPageRenderer.swift
//  PVWebServer
//
//  Loads the bundled upload-page templates and renders `{{TOKEN}}` placeholders
//  at serve time. Templates are cached after the first load.

import Foundation

enum WebServerPageRenderer {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    static func uploadPage(appName: String, ipAddress: String, portSuffix: String,
                           fileRows: String, currentPath: String) -> String {
        guard let html = loadResource(name: "upload-page", ext: "html"),
              let css = loadResource(name: "upload-page", ext: "css"),
              let js = loadResource(name: "upload-page", ext: "js"),
              let nav = loadResource(name: "nav-fragment", ext: "html") else {
            return errorPage(missing: "upload-page.html/css/js or nav-fragment.html")
        }
        let locationLabel = currentPath.isEmpty ? "base folder" : currentPath.htmlEscaped
        let clientScript = render(js, variables: [
            "CURRENT_PATH": currentPath.jsEscaped
        ])
        return render(html, variables: [
            "APP_NAME": appName.htmlEscaped,
            "STYLESHEET": css,
            "CLIENT_SCRIPT": clientScript,
            "IP_ADDRESS": ipAddress.htmlEscaped,
            "PORT_SUFFIX": portSuffix.htmlEscaped,
            "LOCATION_LABEL": locationLabel,
            "FILE_ROWS": fileRows,
            "NAV": render(nav, variables: ["ACTIVE_FILES": " is-active"])
        ])
    }

    /// Shown instead of crashing when a template is missing from the bundle.
    static func errorPage(missing: String) -> String {
        "<!DOCTYPE html><html><body><h1>Upload page unavailable</h1><p>Missing resource: \(missing.htmlEscaped)</p></body></html>"
    }

    static func render(_ template: String, variables: [String: String]) -> String {
        var result = template
        for (key, value) in variables {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }

    static func loadResource(name: String, ext: String) -> String? {
        let key = "\(name).\(ext)"
        lock.lock()
        if let cached = cache[key] { lock.unlock(); return cached }
        lock.unlock()
        guard let url = Bundle.module.url(forResource: name, withExtension: ext),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            NSLog("[ROMUploadServer] missing web resource \(key)")
            return nil
        }
        lock.lock()
        cache[key] = text
        lock.unlock()
        return text
    }
}
