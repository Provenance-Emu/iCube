// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
#if canImport(CoreNFC)
import CoreNFC
#endif

/// Writes and scans "tap to play" NFC tags (`GameTagPayload`). iPhone only:
/// CoreNFC is absent on tvOS, and `readingAvailable` is false on iPad and the
/// simulator, where every entry point hides itself (`isAvailable`).
///
/// A tag written here launches the game two ways: iOS background tag reading
/// opens the URI record (`dolphinios://play?id=…`) through the normal
/// open-URL path, and "Scan NFC Tag" in Settings reads it in the foreground
/// and launches directly. A sibling app's tag is announced, never opened.
///
/// Pure Swift on purpose: the CoreNFC delegate is a private NSObject below, so
/// nothing NFC-typed reaches the generated `iCube-Swift.h` that Objective-C++
/// files import without CoreNFC.
@MainActor
final class GameTagCenter: ObservableObject {
    static let shared = GameTagCenter()

    /// A result to show the user (written, launched, sibling tag, error).
    @Published var message: String?

    enum Mode {
        case scan
        case write(GameTagPayload)
    }

    private(set) var mode: Mode = .scan
    #if canImport(CoreNFC)
    private var session: NFCNDEFReaderSession?
    private var delegate: SessionDelegate?
    #endif

    private init() {}

    /// True on hardware that can read NDEF tags (iPhone with NFC, not iPad, not the simulator).
    nonisolated static var isAvailable: Bool {
        #if canImport(CoreNFC)
        return NFCNDEFReaderSession.readingAvailable
        #else
        return false
        #endif
    }

    /// Starts a foreground scan; a tag of ours launches its game.
    func scan() {
        mode = .scan
        begin(alert: L("Hold your iPhone near a game tag."), invalidateAfterFirstRead: true)
    }

    /// Writes the tag for `gameID` on the next tag held to the phone.
    func write(gameID: String, title: String) {
        guard let payload = GameTagPayload(gameID: gameID, title: title) else {
            message = L("This game has no id to write.")
            return
        }
        mode = .write(payload)
        begin(alert: String(format: L("Hold your iPhone near a blank tag to write \u{201C}%@\u{201D}."), title),
              invalidateAfterFirstRead: false)
    }

    /// What a scanned payload means for this app: the message to show and the game to launch.
    nonisolated static func outcome(for payload: GameTagPayload) -> (message: String?, launchGameID: String?) {
        switch GameTagPayload.classify(payload.launchURL) {
        case .own(let gameID):
            return (nil, gameID)
        case .sibling(let sibling):
            return (String(format: L("This tag belongs to %@."), sibling.displayName), nil)
        case .unknown:
            return (L("This isn\u{2019}t a game tag."), nil)
        }
    }

    /// Applies a scanned tag: launches ours, names a sibling's, rejects the rest.
    func handleScanned(uri: URL?, text: String?) {
        guard let payload = GameTagPayload.from(uri: uri, text: text) else {
            message = L("This isn\u{2019}t a game tag.")
            return
        }
        let outcome = Self.outcome(for: payload)
        if let gameID = outcome.launchGameID {
            GameLaunchRequest.launch(gameID: gameID)
        }
        message = outcome.message
    }

    func sessionEnded(error: String?) {
        #if canImport(CoreNFC)
        session = nil
        delegate = nil
        #endif
        if let error { message = error }
    }

    private func begin(alert: String, invalidateAfterFirstRead: Bool) {
        #if canImport(CoreNFC)
        guard Self.isAvailable else {
            message = L("NFC tags need an iPhone.")
            return
        }
        session?.invalidate()
        let delegate = SessionDelegate(center: self)
        let session = NFCNDEFReaderSession(delegate: delegate, queue: nil, invalidateAfterFirstRead: invalidateAfterFirstRead)
        session.alertMessage = alert
        self.delegate = delegate
        self.session = session
        session.begin()
        #else
        message = L("NFC tags need an iPhone.")
        #endif
    }
}

#if canImport(CoreNFC)
/// The CoreNFC side. Private so it stays out of the generated Swift header.
private final class SessionDelegate: NSObject, NFCNDEFReaderSessionDelegate {
    private weak var center: GameTagCenter?
    private let mode: GameTagCenter.Mode

    @MainActor
    init(center: GameTagCenter) {
        self.center = center
        mode = center.mode
    }

    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        let code = (error as? NFCReaderError)?.code
        // The user cancelling, or the first read ending the session, is not an error to report.
        let silent = code == .readerSessionInvalidationErrorUserCanceled
            || code == .readerSessionInvalidationErrorFirstNDEFTagRead
        let text = silent ? nil : error.localizedDescription
        Task { @MainActor in self.center?.sessionEnded(error: text) }
    }

    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        // Only called when `didDetect tags:` is not implemented; kept for protocol completeness.
        guard let first = messages.first else { return }
        let (uri, text) = Self.records(in: first)
        Task { @MainActor in self.center?.handleScanned(uri: uri, text: text) }
    }

    func readerSession(_ session: NFCNDEFReaderSession, didDetect tags: [NFCNDEFTag]) {
        guard let tag = tags.first else { return }
        if tags.count > 1 {
            session.alertMessage = L("More than one tag found. Hold just one near the phone.")
            session.restartPolling()
            return
        }
        session.connect(to: tag) { [self] error in
            if let error {
                session.invalidate(errorMessage: error.localizedDescription)
                return
            }
            switch mode {
            case .scan: read(tag, in: session)
            case .write(let payload): write(payload, to: tag, in: session)
            }
        }
    }

    private static func records(in message: NFCNDEFMessage) -> (URL?, String?) {
        var uri: URL?
        var text: String?
        for record in message.records {
            if uri == nil, let url = record.wellKnownTypeURIPayload() { uri = url }
            if text == nil, let string = record.wellKnownTypeTextPayload().0 { text = string }
        }
        return (uri, text)
    }

    private func read(_ tag: NFCNDEFTag, in session: NFCNDEFReaderSession) {
        tag.readNDEF { message, error in
            if let error {
                session.invalidate(errorMessage: error.localizedDescription)
                return
            }
            session.alertMessage = L("Tag read.")
            session.invalidate()
            let (uri, text) = message.map(Self.records(in:)) ?? (nil, nil)
            Task { @MainActor in
                if message != nil {
                    self.center?.handleScanned(uri: uri, text: text)
                } else {
                    self.center?.message = L("This tag is empty.")
                }
            }
        }
    }

    private func write(_ payload: GameTagPayload, to tag: NFCNDEFTag, in session: NFCNDEFReaderSession) {
        guard let uriRecord = NFCNDEFPayload.wellKnownTypeURIPayload(url: payload.launchURL),
              let textRecord = NFCNDEFPayload.wellKnownTypeTextPayload(
                string: payload.textRecord, locale: Locale(identifier: GameTagPayload.textLanguage)) else {
            session.invalidate(errorMessage: L("Couldn\u{2019}t build the tag."))
            return
        }
        let ndef = NFCNDEFMessage(records: [uriRecord, textRecord])
        tag.queryNDEFStatus { status, capacity, error in
            if let error {
                session.invalidate(errorMessage: error.localizedDescription)
                return
            }
            switch status {
            case .notSupported:
                session.invalidate(errorMessage: L("This tag doesn\u{2019}t support NDEF."))
            case .readOnly:
                session.invalidate(errorMessage: L("This tag is read-only."))
            case .readWrite:
                guard ndef.length <= capacity else {
                    session.invalidate(errorMessage: String(format: L("This tag is too small (%d bytes needed)."), ndef.length))
                    return
                }
                tag.writeNDEF(ndef) { error in
                    if let error {
                        session.invalidate(errorMessage: error.localizedDescription)
                        return
                    }
                    session.alertMessage = L("Tag written. Tap it to play.")
                    session.invalidate()
                    let done = String(format: L("\u{201C}%@\u{201D} is on the tag. Tap it with your iPhone to play."), payload.title)
                    Task { @MainActor in self.center?.message = done }
                }
            @unknown default:
                session.invalidate(errorMessage: L("This tag can\u{2019}t be written."))
            }
        }
    }
}
#endif
