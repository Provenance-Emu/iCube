// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PVSyncRules",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PVSyncRules", targets: ["PVSyncRules"])
    ],
    targets: [
        .target(name: "PVSyncRules"),
        .testTarget(name: "PVSyncRulesTests", dependencies: ["PVSyncRules"])
    ]
)
