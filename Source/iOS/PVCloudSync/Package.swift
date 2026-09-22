// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PVCloudSync",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PVCloudSync", targets: ["PVCloudSync"])
    ],
    dependencies: [
        .package(path: "../PVSyncRules")
    ],
    targets: [
        .target(name: "PVCloudSync", dependencies: ["PVSyncRules"]),
        .testTarget(name: "PVCloudSyncTests", dependencies: ["PVCloudSync", "PVSyncRules"])
    ]
)
