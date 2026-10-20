import Foundation
@main enum RecoveryRaceProof {
  static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RecoveryRace-\(UUID())")
    let folder = root.appendingPathComponent("LibraryMetadata")
    defer { try? FileManager.default.removeItem(at: root) }
    let id = LibraryMetadataStore.Identity.game(gameID: "RACE", discNumber: 0, revision: 0)!
    let other = LibraryMetadataStore.Identity.game(gameID: "OTHER", discNumber: 0, revision: 0)!
    let lock = NSRecursiveLock()
    let gate: LibraryMetadataStore.FileAccess = { body in lock.lock(); defer { lock.unlock() }; try body() }
    let old = try LibraryMetadataStore(directoryURL: folder, withFileAccess: gate, cacheCountLimit: 1)
    let before = try old.commit(.init(title: "Old", coverData: Data([1])), baseline: .init(), for: id, at: Date(timeIntervalSinceReferenceDate: 1))
    let fresh = try LibraryMetadataStore(directoryURL: folder, withFileAccess: gate, cacheCountLimit: 1)
    _ = try fresh.commit(.init(title: "New"), baseline: before, for: id, at: Date(timeIntervalSinceReferenceDate: 2))
    _ = try fresh.draft(for: other)
    try FileManager.default.removeItem(at: folder.appendingPathComponent(id.fileName))
    _ = try old.draft(for: other)
    let recovered = try LibraryMetadataStore(directoryURL: folder).draft(for: id)
    let success = recovered.title == "New" && recovered.coverData == nil
    print("Recovered title=\(recovered.title ?? "nil") coverBytes=\(recovered.coverData?.count ?? 0); expected title=New coverBytes=0; passed=\(success)")
    if !success { exit(1) }
  }
}
