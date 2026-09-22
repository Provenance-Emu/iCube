// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PVHelp",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .watchOS(.v9),
        .macOS(.v14),
        .macCatalyst(.v17),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "PVHelp",
            targets: ["PVHelp"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "PVHelp",
            dependencies: [],
            // `.copy` (not `.process`) is load-bearing: `.process` flattens nested folders in
            // the produced resource bundle, which would silently drop the `guide/` and `help/`
            // subdirectories these bundled wiki pages live in.
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "PVHelpTests",
            dependencies: ["PVHelp"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
