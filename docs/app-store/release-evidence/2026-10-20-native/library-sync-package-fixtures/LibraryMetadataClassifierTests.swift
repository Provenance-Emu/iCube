import XCTest
@testable import PVSyncRules

final class LibraryMetadataClassifierTests: XCTestCase {
    private let shardFilename = String(repeating: "a1", count: 32) + ".json"
    func testBoundedCanonicalLibraryMetadataShardUsesDocumentBucket() {
        let path = "Profiles/LibraryMetadata/" + shardFilename
        XCTAssertEqual(SyncClassifier.classify(relativePath: path), .gameProfile)
        XCTAssertEqual(SyncClassifier.syncableType(relativePath: path, sizeBytes: 1_048_576), .gameProfile)
        XCTAssertNil(SyncClassifier.syncableType(relativePath: path, sizeBytes: 1_048_577))
        XCTAssertEqual(SyncableFileType.gameProfile.mergeKind, .document)
        XCTAssertFalse(SyncableFileType.gameProfile.propagatesDeletes)
    }
    func testLibraryMetadataRejectsNoncanonicalNamesAndPaths() {
        for path in [
            "Profiles/LibraryMetadata/short.json", "Profiles/LibraryMetadata/" + shardFilename.uppercased(),
            "Profiles/LibraryMetadata/" + String(repeating: "g", count: 64) + ".json",
            "Profiles/LibraryMetadata/nested/" + shardFilename, "Profiles/LibraryMetadata/../" + shardFilename,
            "Profiles/../Profiles/LibraryMetadata/" + shardFilename, "/Profiles/LibraryMetadata/" + shardFilename,
            "profiles/librarymetadata/" + shardFilename, "Profiles/LibraryMetadata/" + shardFilename + "/",
            "Profiles/LibraryMetadata/" + shardFilename + ".part", "Profiles/library_metadata.json",
            "Profiles/LibraryMetadata//" + shardFilename, "Profiles/LibraryMetadata/./" + shardFilename
        ] { XCTAssertNil(SyncClassifier.classify(relativePath: path), path) }
    }
    func testExistingGameProfilesRetainTheirExistingLimit() {
        XCTAssertEqual(SyncClassifier.syncableType(relativePath: "Profiles/game_profiles.json", sizeBytes: 2_097_152), .gameProfile)
    }
}
