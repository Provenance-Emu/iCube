// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
//  PVWebServer.swift
//  PVWebServer
//
//  Swift facade preserving the historical `PVWebServer.shared` ObjC API while
//  swapping the engine from the vendored 2015 GCDWebServer / GCDWebUploader /
//  GCDWebDAVServer stack to the dependency-free NWListener-based
//  `ROMUploadServer` (ported from iFly).
//
//  The class is `@objc(PVWebServer)` and reproduces the exact Swift-visible
//  names the existing call sites use:
//      PVWebServer.shared.startServers()       (TVRootView)
//      PVWebServer.shared.stopServers()
//      PVWebServer.shared.urlString            (SettingsRootView)
//      PVWebServer.shared.webDavURLString      (SettingsRootView)
//      PVWebServer.shared.ipAddress            (SourcesView)
//      PVWebServer.shared.bonjourSeverURL      (SourcesView — note historical
//                                               spelling "Sever")
//  …so none of those call sites need to change.
//
//  IMPORT/RESCAN BRIDGE — historically the GCDWebServer stack uploaded files
//  straight into the documents directory and posted
//  PVWebServerFileUploadCompletedNotification, but nothing in iCube observed
//  that notification, so a web upload did NOT auto-refresh the library; the
//  game only appeared on the next manual reload. This facade closes that gap:
//  it observes its own completion notification, debounces a multi-file burst,
//  then posts DOLImportFileFinishedNotification (the rescan trigger the library
//  already listens for) plus a DOLShowSnackbar toast. This is an ADDED
//  improvement over the old behavior, not a regression.

import Foundation

// MARK: - Notification name constants (string-identical to the old ObjC ones)

/// Posted when a file upload begins. userInfo: ["path": String].
public let PVWebServerFileUploadStartedNotificationName = "PVWebServerFileUploadStartedNotification"
/// Posted when a file upload completes. userInfo: ["filePath": String, "fileSize": UInt64].
public let PVWebServerFileUploadCompletedNotificationName = "PVWebServerFileUploadCompletedNotification"

/// ObjC-visible Notification.Name accessors (kept for any ObjC observers that
/// referenced the old `extern NSString* const` symbols).
@objc public extension NSNotification {
    static var pvWebServerFileUploadStartedName: String { PVWebServerFileUploadStartedNotificationName }
    static var pvWebServerFileUploadCompletedName: String { PVWebServerFileUploadCompletedNotificationName }
}

// MARK: - PVWebServer

@objc(PVWebServer)
public final class PVWebServer: NSObject, @unchecked Sendable {

    // MARK: Singleton

    @objc(sharedInstance)
    public static let shared = PVWebServer()

    // MARK: Engine

    private let server: ROMUploadServer
    private var rescanWorkItem: DispatchWorkItem?
    private var pendingUploadCount = 0
    /// Optional hook for the app target to post-process uploads (e.g. archive extraction).
    private var uploadPostProcessor: ((String) -> Void)?
    /// Optional hook returning custom snackbar text for a debounced upload burst (`nil` → default).
    private var uploadSummaryProvider: ((Int) -> String?)?

    // MARK: Init

    private override init() {
        self.server = ROMUploadServer(romsDirectory: PVWebServer.uploadRootDirectory())
        super.init()

        // Title shown on the upload web page.
        let title = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "iCube"
        self.server.pageTitle = title

        // Bridge upload completion → library rescan + toast.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onUploadCompleted(_:)),
            name: Notification.Name(PVWebServerFileUploadCompletedNotificationName),
            object: nil
        )
    }

    // MARK: Upload root directory

    /// The directory the upload server serves / writes into. Rooted at the
    /// `Software` subfolder — the EXACT directory the library scanner reads
    /// (`UserFolderUtil.getSoftwareFolder` = `<user folder>/Software`, where the
    /// user folder is Documents on iOS / Caches on tvOS, same as computed here).
    /// Previously this returned the user-folder ROOT, so a default drag-and-drop
    /// upload landed one level ABOVE where the scanner looks and never appeared
    /// in the library unless the user manually navigated into `Software` first.
    /// `ROMUploadServer.init` creates this directory if it doesn't exist yet.
    private static func uploadRootDirectory() -> URL {
        #if os(tvOS)
        let base = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0]
        #else
        let base = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        #endif
        return URL(fileURLWithPath: base).appendingPathComponent("Software")
    }

    // MARK: - Public ObjC API (legacy surface)

    @discardableResult
    @objc public func startServers() -> Bool {
        guard !server.isHTTPRunning else { return true }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.server.start()
                NSLog("[PVWebServer] Started web server at \(self.server.serverURL?.absoluteString ?? "?") (WebDAV: \(self.server.webDAVURL?.absoluteString ?? "?"))")
            } catch {
                NSLog("[PVWebServer] Failed to start web server: \(error.localizedDescription)")
            }
        }
        return true
    }

    @objc public func stopServers() {
        server.stop()
    }

    @discardableResult
    @objc public func startWWWUploadServer() -> Bool { return startServers() }

    @objc public func stopWWWUploadServer() { stopServers() }

    @discardableResult
    @objc public func startWebDavServer() -> Bool { return startServers() }

    @objc public func stopWebDavServer() { stopServers() }

    @objc public var isWWWUploadServerRunning: Bool { server.isHTTPRunning }
    @objc public var isWebDavServerRunning: Bool { server.isWebDAVRunning }

    /// Local IPv4 address of the device (en0/en1), or nil.
    @objc(IPAddress)
    public var ipAddress: String? { server.ipAddress }

    /// HTTP upload-UI URL string (e.g. `http://192.168.1.5/`), or nil if down.
    @objc(URLString)
    public var urlString: String? { server.serverURL?.absoluteString }

    /// WebDAV URL string (e.g. `http://192.168.1.5:81/`), or nil if down.
    @objc(WebDavURLString)
    public var webDavURLString: String? { server.webDAVURL?.absoluteString }

    /// HTTP upload-UI URL, or nil if down.
    @objc(URL)
    public var url: URL? { server.serverURL }

    /// Bonjour-advertised server URL once registration completes, or nil.
    /// (Historical property name keeps the original "Sever" misspelling so the
    /// `PVWebServer.shared.bonjourSeverURL` call site in SourcesView still
    /// resolves.)
    @objc public var bonjourSeverURL: URL? { server.bonjourServerURL }

    /// Register a block invoked on a background queue for each completed upload path
    /// before the debounced library rescan runs (used for archive extraction).
    @objc public func setUploadPostProcessor(_ block: @escaping (String) -> Void) {
        uploadPostProcessor = block
    }

    /// Register a block returning custom snackbar text for a debounced upload burst.
    /// Return `nil` to use the default "Upload received" message.
    @objc public func setUploadSummaryProvider(_ block: @escaping (Int) -> String?) {
        uploadSummaryProvider = block
    }

    // MARK: - Import / rescan bridge

    @objc private func onUploadCompleted(_ note: Notification) {
        let path = note.userInfo?["filePath"] as? String
        let processor = uploadPostProcessor

        if let path, let processor {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                processor(path)
                DispatchQueue.main.async {
                    self?.scheduleRescan()
                }
            }
            return
        }

        // NotificationCenter delivers on the poster's thread (the server's
        // background queue). Marshal all debounce state onto main so it isn't
        // raced against the work item, which reads/zeroes it on main.
        DispatchQueue.main.async { [weak self] in
            self?.scheduleRescan()
        }
    }

    private func scheduleRescan() {
        dispatchPrecondition(condition: .onQueue(.main))
        pendingUploadCount += 1

        // Debounce: a multi-file drop fires one notification per file. Coalesce
        // a burst into a single rescan ~1.5s after the last file lands.
        rescanWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let count = self.pendingUploadCount
            self.pendingUploadCount = 0

            // Trigger the library rescan the same way an in-app import does.
            NotificationCenter.default.post(
                name: Notification.Name("DOLImportFileFinishedNotification"),
                object: self, userInfo: nil
            )

            // Surface a toast via iCube's snackbar channel.
            let defaultText = count == 1 ? "Upload received" : "\(count) uploads received"
            let text = self.uploadSummaryProvider?(count) ?? defaultText
            NotificationCenter.default.post(
                name: Notification.Name("DOLShowSnackbar"),
                object: nil, userInfo: ["text": text]
            )
        }
        rescanWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}
