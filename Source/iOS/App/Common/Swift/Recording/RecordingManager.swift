// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import ReplayKit
#if canImport(Photos)
import Photos
#endif
#if canImport(UIKit)
import UIKit
#endif

/// The slice of `RPScreenRecorder` the manager uses, so tests can substitute a fake.
protocol ScreenRecording {
  var isAvailable: Bool { get }
  func startRecording() async throws
  /// Stops and writes the movie to `url`.
  func stopRecording(to url: URL) async throws
}

enum RecordingError: Error, Equatable {
  case unavailable
  case alreadyRecording
  case notRecording
  case noDestination
}

/// `RPScreenRecorder` behind `ScreenRecording`. Microphone off: the game audio is captured with the app.
struct ReplayKitScreenRecorder: ScreenRecording {
  var isAvailable: Bool { RPScreenRecorder.shared().isAvailable }

  func startRecording() async throws {
    let recorder = RPScreenRecorder.shared()
    #if !os(tvOS)
    recorder.isMicrophoneEnabled = false
    #endif
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      recorder.startRecording { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }

  func stopRecording(to url: URL) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      RPScreenRecorder.shared().stopRecording(withOutput: url) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }
}

/// Screen recording for both platforms. Output: `<directory>/Recordings/<GameID>-<yyyy-MM-dd_HH-mm-ss>.mp4`
/// (tvOS exposes that folder through the web UI and WebDAV); on iOS the file is also copied to Photos when
/// the clip setting "Save to Photos" is on.
@MainActor
final class RecordingManager: ObservableObject {
  static let shared: RecordingManager = {
    let manager = RecordingManager()
    manager.installLifecycleObservers()
    return manager
  }()

  static let folderName = "Recordings"
  static let timestampFormat = "yyyy-MM-dd_HH-mm-ss"
  static let fileExtension = "mp4"

  @Published private(set) var isRecording = false
  /// True between a start or stop being asked for and ReplayKit answering; the toggle waits it out.
  private(set) var isTransitioning = false
  private var observers: [NSObjectProtocol] = []

  /// Reads the Interface leaf's setting; on unless the owner turned it off.
  var watermarkEnabled: Bool {
    Self.storedWatermarkEnabled(UserDefaults.standard.object(forKey: ConfigInterfaceDefaultsKey.recordingWatermark) as? Bool)
  }

  static func storedWatermarkEnabled(_ stored: Bool?) -> Bool { stored ?? true }

  private let recorder: ScreenRecording
  private let gameID: () -> String?
  private let userDirectory: () -> URL?
  private let now: () -> Date
  private let savesToPhotos: () -> Bool
  private let saveToPhotos: (URL) async -> Void
  private let toast: (String) -> Void
  private var pendingURL: URL?

  init(recorder: ScreenRecording = ReplayKitScreenRecorder(),
       gameID: @escaping () -> String? = { SaveStateService.currentGameID },
       userDirectory: @escaping () -> URL? = { DolphinPaths.userDirectoryURL() },
       now: @escaping () -> Date = { Date() },
       savesToPhotos: @escaping () -> Bool = { RecordingManager.photosEnabled },
       saveToPhotos: @escaping (URL) async -> Void = { await RecordingManager.addToPhotos($0) },
       toast: @escaping (String) -> Void = { EmulationToast.post($0) }) {
    self.recorder = recorder
    self.gameID = gameID
    self.userDirectory = userDirectory
    self.now = now
    self.savesToPhotos = savesToPhotos
    self.saveToPhotos = saveToPhotos
    self.toast = toast
  }

  // MARK: Naming

  static func fileName(gameID: String, date: Date, timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = timestampFormat
    return "\(gameID)-\(formatter.string(from: date)).\(fileExtension)"
  }

  /// `<userDirectory>/Recordings/<GameID>-<timestamp>.mp4`. Pure: the folder is created at `start()`.
  static func outputURL(gameID: String, date: Date, userDirectory: URL, timeZone: TimeZone = .current) -> URL {
    userDirectory
      .appendingPathComponent(folderName, isDirectory: true)
      .appendingPathComponent(fileName(gameID: gameID, date: date, timeZone: timeZone))
  }

  // MARK: Lifecycle

  /// A recording ends with the game or when the app leaves the foreground: ReplayKit would otherwise keep
  /// capturing the library (or nothing) with `isRecording` stuck on, and the next game would open with the
  /// REC badge and watermark showing. Called once for `shared`; tests call it on their own instances.
  func installLifecycleObservers() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: Notification.Name(DOLEmulationDidEndNotification), object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.stopForLifecycle() }
    })
    #if canImport(UIKit)
    observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.stopForLifecycle() }
    })
    #endif
  }

  private func stopForLifecycle() {
    guard isRecording, !isTransitioning else { return }
    Task { @MainActor in
      do { try await stop() } catch { NSLog("[Recording] lifecycle stop failed: %@", error.localizedDescription) }
    }
  }

  // MARK: Start / stop

  func start() async throws {
    guard !isRecording, !isTransitioning else { throw RecordingError.alreadyRecording }
    guard recorder.isAvailable else { throw RecordingError.unavailable }
    guard let directory = userDirectory() else { throw RecordingError.noDestination }
    let url = Self.outputURL(gameID: gameID() ?? "UNKNOWN", date: now(), userDirectory: directory)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    isTransitioning = true
    defer { isTransitioning = false }
    try await recorder.startRecording()
    pendingURL = url
    isRecording = true
  }

  /// Returns the saved file, or nil when nothing was recording. On error the manager is left not recording.
  @discardableResult
  func stop() async throws -> URL? {
    guard isRecording, let url = pendingURL else { return nil }
    isRecording = false
    pendingURL = nil
    isTransitioning = true
    defer { isTransitioning = false }
    try await recorder.stopRecording(to: url)
    if savesToPhotos() { await saveToPhotos(url) }
    toast(L("Recording saved to Recordings"))
    return url
  }

  // MARK: Photos (iOS only; tvOS has no Photos framework)

  nonisolated static var photosEnabled: Bool {
    #if canImport(Photos)
    UserDefaults.standard.bool(forKey: GraphicsGeneralDefaultsKey.saveToPhotos)
    #else
    false
    #endif
  }

  nonisolated static func addToPhotos(_ url: URL) async {
    #if canImport(Photos)
    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard status == .authorized || status == .limited else { return }
    do {
      try await PHPhotoLibrary.shared().performChanges {
        PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
      }
    } catch {
      NSLog("[Recording] Photos save error: %@", error.localizedDescription)
    }
    #endif
  }
}
