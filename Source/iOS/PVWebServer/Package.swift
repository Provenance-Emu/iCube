// swift-tools-version:6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
    name: "PVWebServer",
    defaultLocalization: .init(stringLiteral: "en"),
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .watchOS(.v9),
        .macOS(.v11),
        .macCatalyst(.v17),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "PVWebServer",
            targets: ["PVWebServer"]
        ),
        .library(
            name: "PVWebServer-Dynamic",
            type: .dynamic,
            targets: ["PVWebServer"]
        ),
        .library(
            name: "PVWebServer-Static",
            type: .static,
            targets: ["PVWebServer"]
        )
    ],

    dependencies: [
    ],

    // MARK: - Targets
    targets: [
        // Pure-Swift target: the NWListener-based ROMUploadServer + the
        // PVWebServer @objc facade. The vendored 2015 GCDWebServer /
        // GCDWebUploader / GCDWebDAVServer ObjC sources (and their bundle +
        // C header search paths) were removed — the server now has zero
        // third-party deps and rides on Network.framework.
        .target(
            name: "PVWebServer",
            dependencies: [
			],
            linkerSettings: [
                .linkedFramework("Network"),
                .linkedFramework("UIKit", .when(platforms: [.iOS, .tvOS, .macCatalyst, .visionOS])),
                .linkedFramework("AppKit", .when(platforms: [.macOS]))
            ]
        ),

        // MARK: SwiftPM tests
        .testTarget(
            name: "PVWebServerTests",
            dependencies: ["PVWebServer"])
    ],
    swiftLanguageModes: [.v5]
)
