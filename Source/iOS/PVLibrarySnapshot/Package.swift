// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PVLibrarySnapshot",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14), .macCatalyst(.v17), .visionOS(.v1)],
    products: [
        .library(name: "PVLibrarySnapshot", targets: ["PVLibrarySnapshot"])
    ],
    targets: [
        // Foundation only. Linked by the app AND by every extension, so it must never
        // depend on the Dolphin core, UIKit, or anything with a Realm/SwiftData store.
        .target(name: "PVLibrarySnapshot"),
        .testTarget(name: "PVLibrarySnapshotTests", dependencies: ["PVLibrarySnapshot"])
    ]
)
