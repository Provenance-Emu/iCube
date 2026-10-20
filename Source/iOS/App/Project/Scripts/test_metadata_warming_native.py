#!/usr/bin/env python3
"""Exercise the actual metadata warming methods with host lifecycle boundaries.

The source fragment is copied verbatim. UIKit, emulation and the asynchronous
identity hasher are controlled boundaries; no UIKit/device acceptance is implied.
"""
from pathlib import Path
import subprocess
import tempfile

app = Path(__file__).resolve().parents[2]
source = (app / "Common/Swift/LibraryMetadataService.swift").read_text()
start = source.index("  @MainActor static func resumeContentIdentityWarming()")
end = source.index("  @objc static func customTitle", start)
methods = source[start:end]
fixture = '''import Foundation
import Darwin
struct TVGameItem { var gameID = "<unknown>"; var fileSize = 3; var filePath = "/fixture.dol" }
@MainActor final class UIApplication {
  enum Status { case active, inactive }
  static let shared = UIApplication()
  var applicationState = Status.active
  static let willResignActiveNotification = Notification.Name("resign")
  static let didBecomeActiveNotification = Notification.Name("active")
}
@MainActor final class EmulationState {
  static let shared = EmulationState()
  var isActive = false
  func addTransitionHandler(_ handler: @escaping @MainActor (Bool) -> Void) {}
}
@MainActor final class SyncLocalIOGate { static let shared = SyncLocalIOGate(); var isEmulating = false }
@MainActor final class Service {
  final class State {
    var latestItems: [TVGameItem] = []
    var warmingGateInstalled = false
    var warmingTask: Task<Void, Never>?
    var warmingObservers: [NSObjectProtocol] = []
    var warmingRetryRequested = false
  }
  static let state = State()
  static var calls = 0
  static var pending: CheckedContinuation<Void, Never>?
  static func discIdentity(for item: TVGameItem) -> String? { nil }
  static func identity(for item: TVGameItem) -> String? { nil }
  static func didChange() {}
  static func resolveIdentity(for item: TVGameItem) async throws -> String {
    calls += 1
    if calls == 1 { await withCheckedContinuation { pending = $0 } }
    try Task.checkCancellation()
    return "verified content identity"
  }
METHODS
}
@main struct Run {
  @MainActor static func main() async {
    Service.warmContentIdentities(for: [TVGameItem()])
    for _ in 0..<1000 { if Service.pending != nil { break }; await Task.yield() }
    guard Service.pending != nil else { print("FAIL: first hash did not start"); exit(1) }
    Service.state.warmingTask?.cancel()
    UIApplication.shared.applicationState = .inactive
    Service.resumeContentIdentityWarming()
    UIApplication.shared.applicationState = .active
    Service.resumeContentIdentityWarming()
    let old = Service.pending; Service.pending = nil; old?.resume()
    for _ in 0..<1000 { if Service.calls >= 2 { break }; await Task.yield() }
    guard Service.calls == 2 else {
      print("FAIL: cancelled warmup dropped accepted foreground retry: \\(Service.calls) calls, expected 2")
      exit(1)
    }
    print("PASS: eligible foreground retry waits for cancelled hash and resumes exactly once")
  }
}
'''.replace("METHODS", methods)
with tempfile.TemporaryDirectory(prefix="icube-metadata-warming-") as directory:
    folder = Path(directory)
    (folder / "Main.swift").write_text(fixture)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(folder / "Main.swift"), "-o", str(folder / "test")], check=True)
    raise SystemExit(subprocess.call([str(folder / "test")]))
