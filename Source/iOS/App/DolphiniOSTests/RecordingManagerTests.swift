// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

private final class FakeRecorder: ScreenRecording {
  var isAvailable = true
  var startError: Error?
  var stopError: Error?
  var started = 0
  var stoppedTo: [URL] = []
  /// A slow ReplayKit answer, to race a second start against the first.
  var startDelayNanoseconds: UInt64 = 0

  func startRecording() async throws {
    if let startError { throw startError }
    if startDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: startDelayNanoseconds) }
    started += 1
  }

  func stopRecording(to url: URL) async throws {
    if let stopError { throw stopError }
    stoppedTo.append(url)
  }
}

private struct Boom: Error {}

@MainActor
final class RecordingManagerTests: XCTestCase {
  private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingManagerTests", isDirectory: true)
  private var toasts: [String] = []
  private var photoSaves: [URL] = []

  override func tearDown() {
    try? FileManager.default.removeItem(at: directory)
    super.tearDown()
  }

  private func manager(_ recorder: FakeRecorder, photos: Bool = false) -> RecordingManager {
    toasts = []
    photoSaves = []
    return RecordingManager(recorder: recorder, gameID: { "GALE01" }, userDirectory: { self.directory },
                            now: { Date(timeIntervalSince1970: 0) }, savesToPhotos: { photos },
                            saveToPhotos: { self.photoSaves.append($0) }, toast: { self.toasts.append($0) })
  }

  func test_startThenStop_togglesState_andWritesToRecordingsFolder() async throws {
    let recorder = FakeRecorder()
    let m = manager(recorder)
    XCTAssertFalse(m.isRecording)
    try await m.start()
    XCTAssertTrue(m.isRecording)
    XCTAssertEqual(recorder.started, 1)
    let url = try await m.stop()
    XCTAssertFalse(m.isRecording)
    XCTAssertEqual(url, recorder.stoppedTo.first)
    XCTAssertEqual(url?.deletingLastPathComponent().lastPathComponent, RecordingManager.folderName)
    XCTAssertEqual(url?.pathExtension, "mp4")
    XCTAssertEqual(toasts, [L("Recording saved to Recordings")])
  }

  func test_startError_leavesNotRecording() async {
    let recorder = FakeRecorder()
    recorder.startError = Boom()
    let m = manager(recorder)
    do { try await m.start(); XCTFail("expected throw") } catch {}
    XCTAssertFalse(m.isRecording)
  }

  func test_stopError_leavesNotRecording_andDoesNotToast() async {
    let recorder = FakeRecorder()
    let m = manager(recorder)
    try? await m.start()
    recorder.stopError = Boom()
    do { _ = try await m.stop(); XCTFail("expected throw") } catch {}
    XCTAssertFalse(m.isRecording)
    XCTAssertTrue(toasts.isEmpty)
  }

  func test_unavailableRecorder_throws() async {
    let recorder = FakeRecorder()
    recorder.isAvailable = false
    let m = manager(recorder)
    do { try await m.start(); XCTFail("expected throw") } catch { XCTAssertEqual(error as? RecordingError, .unavailable) }
    XCTAssertFalse(m.isRecording)
  }

  func test_secondStart_throwsAlreadyRecording() async throws {
    let m = manager(FakeRecorder())
    try await m.start()
    do { try await m.start(); XCTFail("expected throw") } catch { XCTAssertEqual(error as? RecordingError, .alreadyRecording) }
  }

  func test_secondStartWhileTheFirstIsInFlight_throwsAlreadyRecording() async throws {
    let recorder = FakeRecorder()
    recorder.startDelayNanoseconds = 50_000_000
    let m = manager(recorder)
    async let first: Void = m.start()
    try await Task.sleep(nanoseconds: 5_000_000)
    do {
      try await m.start()
      XCTFail("the second start must throw")
    } catch {
      XCTAssertEqual(error as? RecordingError, .alreadyRecording)
    }
    try await first
    XCTAssertEqual(recorder.started, 1)
    XCTAssertTrue(m.isRecording)
  }

  func test_emulationEnd_stopsTheRecording() async throws {
    let recorder = FakeRecorder()
    let m = manager(recorder)
    m.installLifecycleObservers()
    try await m.start()
    NotificationCenter.default.post(name: .DOLEmulationDidEnd, object: nil)
    for _ in 0 ..< 50 where m.isRecording { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertFalse(m.isRecording)
    XCTAssertEqual(recorder.stoppedTo.count, 1)
  }

  func test_stopWhenIdle_returnsNil() async throws {
    let url = try await manager(FakeRecorder()).stop()
    XCTAssertNil(url)
  }

  func test_photosCopy_onlyWhenSettingOn() async throws {
    let on = manager(FakeRecorder(), photos: true)
    try await on.start()
    let url = try await on.stop()
    XCTAssertEqual(photoSaves, [url].compactMap { $0 })
    let off = manager(FakeRecorder(), photos: false)
    try await off.start()
    _ = try await off.stop()
    XCTAssertTrue(photoSaves.isEmpty)
  }

  func test_fileName_format() {
    let utc = TimeZone(identifier: "UTC")!
    let date = Date(timeIntervalSince1970: 86_400 + 3_661)
    XCTAssertEqual(RecordingManager.fileName(gameID: "GALE01", date: date, timeZone: utc), "GALE01-1970-01-02_01-01-01.mp4")
    let url = RecordingManager.outputURL(gameID: "GALE01", date: date, userDirectory: directory, timeZone: utc)
    XCTAssertEqual(url, directory.appendingPathComponent("Recordings").appendingPathComponent("GALE01-1970-01-02_01-01-01.mp4"))
  }

  func test_watermarkDefault_isOn_storedWins() {
    XCTAssertTrue(RecordingManager.storedWatermarkEnabled(nil))
    XCTAssertTrue(RecordingManager.storedWatermarkEnabled(true))
    XCTAssertFalse(RecordingManager.storedWatermarkEnabled(false))
  }
}
