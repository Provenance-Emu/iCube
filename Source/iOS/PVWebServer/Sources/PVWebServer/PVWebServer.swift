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

/// Posted by any UI whose purpose is the server itself -- the Wi-Fi import sheet,
/// Settings' network page. Asking to see the upload address IS asking for the
/// server, so the lifecycle policy starts it on demand and holds it up for as long
/// as that surface is on screen, outranking the pause-during-emulation rule.
/// Balance every post of these with the Released one.
public let PVWebServerUserAccessRequestedNotificationName = "PVWebServerUserAccessRequestedNotification"
public let PVWebServerUserAccessReleasedNotificationName = "PVWebServerUserAccessReleasedNotification"
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
    /// Uploads that have posted Started but not yet Completed. A WebDAV copy is several
    /// requests (Finder writes the `._` AppleDouble sidecar first, Windows pre-creates a
    /// zero-byte file), so "a completion arrived" is not "the copy is done"; the rescan waits
    /// until nothing is still being written, or the library indexes a half-written ROM.
    private var uploadsInFlight = 0
    private var lastUploadActivity = Date.distantPast
    private static let rescanDebounce: TimeInterval = 1.5
    private static let rescanRecheck: TimeInterval = 2.0
    /// A failed upload deletes its partial file without posting Completed, which would pin
    /// `uploadsInFlight` above zero forever. If nothing has started or finished for this long,
    /// the count is treated as stale and the rescan runs anyway.
    private static let uploadActivityStaleAfter: TimeInterval = 120
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
        // Unique per device so two iCubes on one LAN do not collide on the Bonjour name.
        let host = ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        self.server.bonjourName = host.isEmpty ? title : "\(title) (\(host))"

        // Bridge upload completion → library rescan + toast.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onUploadStarted(_:)),
            name: Notification.Name(PVWebServerFileUploadStartedNotificationName),
            object: nil
        )
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
        guard !server.isRunning else { return true }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.server.start()
                NSLog("[PVWebServer] Started web server at \(self.server.serverURL?.absoluteString ?? "?") (HTTP + WebDAV on one port)")
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

    @objc public var isWWWUploadServerRunning: Bool { server.isRunning }
    @objc public var isWebDavServerRunning: Bool { server.isRunning }

    /// Local IPv4 address of the device (en0/en1), or nil.
    @objc(IPAddress)
    public var ipAddress: String? { server.ipAddress }

    /// HTTP upload-UI URL string (e.g. `http://192.168.1.5/`), or nil if down.
    @objc(URLString)
    public var urlString: String? { server.serverURL?.absoluteString }

    /// WebDAV URL string (e.g. `http://192.168.1.5/`), or nil if down. HTTP and WebDAV
    /// now share one listener/port, so this is the same URL as `urlString`.
    @objc(WebDavURLString)
    public var webDavURLString: String? { server.serverURL?.absoluteString }

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

    // MARK: - Async route registry

    /// Register an async route that owns its full HTTP response — status,
    /// headers, and either an in-memory body or a file streamed from disk at a
    /// byte offset.
    ///
    /// This is the seam features hang their own HTTP API off (continuity
    /// handoff, nearby library sharing) instead of editing the server's private
    /// route switch. Registration is independent of the listener's lifetime:
    /// routes registered while the server is stopped are live as soon as it
    /// starts, and survive the stop/start cycle
    /// `WebServerLifecycleService` drives.
    ///
    /// ⚠️  This server is **plain HTTP on the local network** — no TLS. Read the
    /// transport-security note at the top of `WebRoute.swift` before adding a
    /// route that serves anything a user would mind leaking on a shared Wi-Fi.
    public func addAsyncHandler(forMethod method: String, path: String,
                                handler: @escaping WebRouteHandler) {
        server.addAsyncHandler(forMethod: method, path: path, handler: handler)
    }

    // MARK: - Import / rescan bridge

    @objc private func onUploadStarted(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.uploadsInFlight += 1
            self.lastUploadActivity = Date()
        }
    }

    @objc private func onUploadCompleted(_ note: Notification) {
        let path = note.userInfo?["filePath"] as? String
        let processor = uploadPostProcessor
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.uploadsInFlight = max(0, self.uploadsInFlight - 1)
            self.lastUploadActivity = Date()
        }

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
            if self.uploadsInFlight > 0 {
                if Date().timeIntervalSince(self.lastUploadActivity) < Self.uploadActivityStaleAfter {
                    // Something is still being written: check again shortly instead of
                    // indexing a partial file. `pendingUploadCount` keeps accumulating.
                    self.rearmRescan(after: Self.rescanRecheck)
                    return
                }
                NSLog("[PVWebServer] \(self.uploadsInFlight) upload(s) never completed; rescanning anyway")
                self.uploadsInFlight = 0
            }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rescanDebounce, execute: work)
    }

    private func rearmRescan(after delay: TimeInterval) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let work = rescanWorkItem else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

// MARK: - WebRouteRegistering

/// `PVWebServer` is the app-wide route host. Features take this protocol
/// rather than the concrete singleton so their route registration is testable
/// against a collecting stub.
extension PVWebServer: WebRouteRegistering {}
