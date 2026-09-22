// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PVContinuity",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PVContinuity", targets: ["PVContinuity"]),
        .library(name: "PVContinuityTesting", targets: ["PVContinuityTesting"])
    ],
    dependencies: [
        // The shared "what may leave the device" table, owned jointly with the
        // CloudKit sync work. Continuity classifies every user-data file
        // through it so the two features can never disagree about what is
        // allowed off-device.
        .package(path: "../PVSyncRules"),
        // The route registry lives on the app's existing HTTP server; this
        // package registers against it rather than defining a parallel
        // request/response type family and an adapter to translate between them.
        .package(path: "../PVWebServer")
    ],
    targets: [
        .target(
            name: "PVContinuity",
            dependencies: [
                .product(name: "PVSyncRules", package: "PVSyncRules"),
                .product(name: "PVWebServer", package: "PVWebServer")
            ]
        ),
        .target(
            name: "PVContinuityTesting",
            dependencies: ["PVContinuity"]
        ),
        .testTarget(
            name: "PVContinuityTests",
            dependencies: ["PVContinuity", "PVContinuityTesting"]
        )
    ]
)
