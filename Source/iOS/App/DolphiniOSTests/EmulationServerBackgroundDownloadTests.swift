// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import Foundation
import PVContinuity
import RomMClient
import XCTest

@testable import iCube

/// The Emulation Server copy on a background fetcher: every file asked for at once, the plan kept
/// so a relaunch can finish the game without browsing, and failures kept or dropped as they should.
final class EmulationServerBackgroundDownloadTests: XCTestCase {
  private func makeLibrary(fetcher: RecordingFetcher, transport: TwoDiscTransport = TwoDiscTransport())
    throws -> (EmulationServerLibrary, EmulationServer) {
    let server = try EmulationServer(address: "http://bg-\(UUID().uuidString).invalid")
    return (EmulationServerLibrary(server: server, token: "bg-token", transport: transport, fetcher: fetcher), server)
  }

  func testEveryFileIsAskedForAtOnceWithItsCredentialAndPlan() async throws {
    let fetcher = RecordingFetcher()
    let (library, server) = try makeLibrary(fetcher: fetcher)
    let page = try await library.catalog()
    let entry = try XCTUnwrap(page.entries.first)
    let folder = try server.folder(for: entry)
    defer { try? FileManager.default.removeItem(at: folder) }

    let urls = try await library.copy(entry) { _ in }
    XCTAssertEqual(urls.map(\.lastPathComponent), ["Disc 1.iso", "Disc 2.iso"])

    let calls = await fetcher.calls
    XCTAssertEqual(calls.count, 1, "Both discs are queued before either is waited on")
    let call = try XCTUnwrap(calls.first)
    XCTAssertEqual(call.files.map(\.url.path), ["/api/v1/files/disc1/content", "/api/v1/files/disc2/content"])
    XCTAssertEqual(call.files.map(\.expectedSize), [0x8000, 0x8000])
    XCTAssertTrue(call.files.allSatisfy { $0.headers["Authorization"] == "Bearer bg-token" })
    let expectedJob = await library.downloadJob(for: entry)
    XCTAssertEqual(call.job, expectedJob)
    let plan = try XCTUnwrap(EmulationServerLibrary.savedPlan(call.plan))
    XCTAssertEqual(plan.server, server)
    XCTAssertEqual(plan.entry.key, entry.key)
    XCTAssertEqual(plan.downloads.map(\.path), ["discs/Disc 1.iso", "discs/Disc 2.iso"])
    let released = await fetcher.released
    XCTAssertEqual(released, [call.job], "A finished game leaves nothing in the journal")
  }

  func testRelaunchFinishesFromTheSavedPlanWithoutBrowsing() async throws {
    let first = RecordingFetcher()
    let (browsed, server) = try makeLibrary(fetcher: first)
    let page = try await browsed.catalog()
    let entry = try XCTUnwrap(page.entries.first)
    let folder = try server.folder(for: entry)
    defer { try? FileManager.default.removeItem(at: folder) }
    _ = try await browsed.copy(entry) { _ in }
    try FileManager.default.removeItem(at: folder)
    let firstCalls = await first.calls
    let saved = try XCTUnwrap(firstCalls.first?.plan)

    // A new launch: the catalog was never read, only the journal's plan is there.
    let relaunched = RecordingFetcher(savedPlan: saved)
    let transport = TwoDiscTransport()
    let library = EmulationServerLibrary(server: server, token: "new-token", transport: transport, fetcher: relaunched)
    let urls = try await library.copy(entry) { _ in }
    XCTAssertEqual(urls.map(\.lastPathComponent), ["Disc 1.iso", "Disc 2.iso"])
    let browses = await transport.requestedPaths
    XCTAssertTrue(browses.isEmpty, "Finishing needs no browse or manifest read")
    let headers = await relaunched.calls.first?.files.map { $0.headers["Authorization"] }
    XCTAssertEqual(headers, ["Bearer new-token", "Bearer new-token"], "A restarted file carries the current token")
  }

  func testAPlanForAnotherServerIsNotUsed() async throws {
    let first = RecordingFetcher()
    let (browsed, server) = try makeLibrary(fetcher: first)
    let page = try await browsed.catalog()
    let entry = try XCTUnwrap(page.entries.first)
    defer { if let folder = try? server.folder(for: entry) { try? FileManager.default.removeItem(at: folder) } }
    _ = try await browsed.copy(entry) { _ in }
    let saved = await first.calls.first?.plan

    let other = try EmulationServer(address: "http://other-\(UUID().uuidString).invalid")
    let library = EmulationServerLibrary(server: other, token: nil, transport: TwoDiscTransport(),
                                         fetcher: RecordingFetcher(savedPlan: saved))
    do {
      _ = try await library.copy(entry) { _ in }
      XCTFail("Another server's plan must not be followed")
    } catch EmulationServerLibrary.ServerError.invalidContent {}
  }

  func testRevokedTokenIsAccessDeniedAndDropsTheJob() async throws {
    let fetcher = RecordingFetcher(failure: .accessDenied)
    let (library, server) = try makeLibrary(fetcher: fetcher)
    let page = try await library.catalog()
    let entry = try XCTUnwrap(page.entries.first)
    do {
      _ = try await library.copy(entry) { _ in }
      XCTFail("Expected access denied")
    } catch {
      XCTAssertTrue(library.isAccessDenied(error), "The existing reconnect prompt takes over")
    }
    let released = await fetcher.released
    let expectedJob = await library.downloadJob(for: entry)
    XCTAssertEqual(released, [expectedJob])
    XCTAssertFalse(FileManager.default.fileExists(atPath: try server.folder(for: entry).path))
  }

  func testLostConnectionAndCancelKeepTheJobForResuming() async throws {
    for failure in [BackgroundDownloadFailure.network, .cancelled] {
      let fetcher = RecordingFetcher(failure: failure)
      let (library, _) = try makeLibrary(fetcher: fetcher)
      let page = try await library.catalog()
    let entry = try XCTUnwrap(page.entries.first)
      do {
        _ = try await library.copy(entry) { _ in }
        XCTFail("Expected \(failure)")
      } catch {
        if failure == .cancelled { XCTAssertTrue(error is CancellationError) }
      }
      let released = await fetcher.released
      XCTAssertTrue(released.isEmpty, "\(failure) keeps the journal's resume data")
    }
  }

  func testProgressCoversTheWholeGame() async throws {
    let fetcher = RecordingFetcher(progressSteps: [0, 0x4000, 0x8000, 0xC000, 0x10000])
    let (library, server) = try makeLibrary(fetcher: fetcher)
    let page = try await library.catalog()
    let entry = try XCTUnwrap(page.entries.first)
    defer { if let folder = try? server.folder(for: entry) { try? FileManager.default.removeItem(at: folder) } }
    let seen = ProgressLog()
    _ = try await library.copy(entry) { seen.append($0) }
    let updates = seen.values
    XCTAssertEqual(updates.map(\.bytesTransferred), [0, 0x4000, 0x8000, 0xC000, 0x10000])
    XCTAssertEqual(updates.map(\.completedFiles), [0, 0, 1, 1, 1])
    XCTAssertTrue(updates.allSatisfy { $0.totalBytes == 0x10000 && $0.totalFiles == 2 })
  }
}

/// RomM's client hands each file request to its transport; inside a job it goes to the downloader.
final class RomMBackgroundTransportTests: XCTestCase {
  private let job = BackgroundDownloadJob(kind: .romm, sourceID: "romm:https://romm.example", gameKey: "romm:7", title: "Game")

  private var request: URLRequest {
    var request = URLRequest(url: URL(string: "https://romm.example/api/roms/7/content/disc2.iso?file_ids=3")!)
    request.setValue("Bearer romm-token", forHTTPHeaderField: "Authorization")
    return request
  }

  func testFileDownloadsInsideAJobGoToTheDownloader() async throws {
    let fetcher = RecordingFetcher()
    let transport = RomMBackgroundTransport(downloader: fetcher)
    let request = request
    let (file, response) = try await RomMBackgroundTransport.$job.withValue(job) {
      try await transport.download(for: request)
    }
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertEqual(try Data(contentsOf: file), TwoDiscTransport.disc(2))
    let calls = await fetcher.calls
    XCTAssertEqual(calls.map(\.job), [job])
    XCTAssertEqual(calls.first?.files.first?.headers["Authorization"], "Bearer romm-token")
    XCTAssertEqual(calls.first?.files.first?.url, request.url)
  }

  func testDownloaderFailuresBecomeRomMErrors() async throws {
    let cases: [(BackgroundDownloadFailure, (any Error) -> Bool)] = [
      (.accessDenied, { ($0 as? RomMError) == .accessDenied }),
      (.unavailable, { ($0 as? RomMError) == .unavailable }),
      (.cancelled, { $0 is CancellationError }),
      (.network, { ($0 as? BackgroundDownloadError)?.failure == .network }),
    ]
    for (failure, matches) in cases {
      let transport = RomMBackgroundTransport(downloader: RecordingFetcher(failure: failure))
      let request = request
      do {
        _ = try await RomMBackgroundTransport.$job.withValue(job) { try await transport.download(for: request) }
        XCTFail("Expected \(failure)")
      } catch {
        XCTAssertTrue(matches(error), "\(failure) became \(error)")
      }
    }
  }
}

private final class ProgressLog: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [PullProgress] = []
  var values: [PullProgress] { lock.withLock { items } }
  func append(_ value: PullProgress) { lock.withLock { items.append(value) } }
}

/// Stands in for the background downloader: writes each disc to a file the way an arrived
/// transfer would be, and remembers what it was asked.
private actor RecordingFetcher: GameFileFetching {
  struct Call {
    let files: [GameFileRequest]
    let job: BackgroundDownloadJob
    let plan: Data?
  }

  private(set) var calls: [Call] = []
  private(set) var released: [BackgroundDownloadJob] = []
  private let savedPlan: Data?
  private let failure: BackgroundDownloadFailure?
  private let progressSteps: [Int64]

  init(savedPlan: Data? = nil, failure: BackgroundDownloadFailure? = nil, progressSteps: [Int64] = []) {
    self.savedPlan = savedPlan
    self.failure = failure
    self.progressSteps = progressSteps
  }

  func savedPlan(for job: BackgroundDownloadJob) -> Data? { savedPlan }

  func fetch(_ files: [GameFileRequest], for job: BackgroundDownloadJob, plan: Data?,
             progress: @escaping @Sendable (Int64) -> Void) async throws -> [URL] {
    calls.append(Call(files: files, job: job, plan: plan))
    if let failure { throw BackgroundDownloadError(failure: failure) }
    progressSteps.forEach(progress)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("arrived-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return try files.enumerated().map { index, file in
      let disc = file.url.path.contains("disc2") ? 2 : 1
      let url = folder.appendingPathComponent("\(index).download")
      try TwoDiscTransport.disc(disc).write(to: url)
      return url
    }
  }

  func release(_ job: BackgroundDownloadJob) { released.append(job) }
}

/// A server with one GameCube item of two discs, listed by manifest.
private actor TwoDiscTransport: ContinuityTransport {
  private(set) var requestedPaths: [String] = []

  func request(_ request: ContinuityRequest) async throws -> ContinuityResponse {
    requestedPaths.append(request.url.path)
    let body: String
    switch request.url.path {
    case "/api/v1/capabilities":
      body = #"{"protocol":{"major":1}}"#
    case "/api/v1/browse-libraries":
      body = #"{"items":[{"id":"lib1"}],"nextCursor":null}"#
    case "/api/v1/browse":
      body = """
      {"items":[{"entityType":"item","item":{"id":"set","title":"Game","systemIdentifier":"com.provenance.gamecube"}}],
      "nextCursor":null}
      """
    case "/api/v1/items/set/manifest":
      let files = (1 ... 2).map { disc in
        let hash = SHA256.hash(data: Self.disc(disc)).map { String(format: "%02x", $0) }.joined()
        return """
        {"id":"disc\(disc)","kind":"rom","relativePath":"discs/Disc \(disc).iso","size":32768,
        "sha256":"\(hash)","required":true}
        """
      }
      body = #"{"itemId":"set","version":1,"files":["# + files.joined(separator: ",") + "]}"
    default:
      throw URLError(.unsupportedURL)
    }
    return ContinuityResponse(status: 200, body: Data(body.utf8))
  }

  func download(_ request: ContinuityRequest, to destination: URL, resumeOffset: Int64,
                progress: (@Sendable (Int64, Int64?) -> Void)?) async throws -> Int64 {
    throw URLError(.unsupportedURL)
  }

  static func disc(_ number: Int) -> Data {
    var bytes = Data(repeating: 0, count: 0x8000)
    bytes.replaceSubrange(0 ..< 6, with: Data("TEST01".utf8))
    bytes[6] = UInt8(number - 1)
    bytes.replaceSubrange(0x1C ..< 0x20, with: [0xC2, 0x33, 0x9F, 0x3D])
    return bytes
  }
}
